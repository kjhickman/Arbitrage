use serde::Deserialize;
use std::{
    collections::HashMap,
    env,
    fs::{self, File},
    io,
    path::Path,
    process::Command,
};
#[cfg(target_os = "macos")]
use std::{path::PathBuf, process};
use ureq::Agent;

use crate::sign_in;

#[cfg(target_os = "macos")]
const PLATFORM: &str = "macos-aarch64";
#[cfg(target_os = "windows")]
const PLATFORM: &str = "windows-x86_64";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    pub version: String,
    pub(crate) url: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Check {
    UpToDate,
    Available(Release),
}

#[derive(Deserialize)]
struct Latest {
    version: String,
    assets: HashMap<String, String>,
}

pub fn check(agent: &Agent, worker_url: &str) -> Result<Check, String> {
    let mut response = match agent
        .get(sign_in::endpoint(worker_url, "v1/companion/latest"))
        .call()
    {
        Ok(response) => response,
        Err(ureq::Error::StatusCode(404)) => return Ok(Check::UpToDate),
        Err(ureq::Error::StatusCode(status)) => {
            return Err(format!("The update server returned HTTP {status}."));
        }
        Err(_) => return Err("Could not reach the update server.".to_owned()),
    };
    let latest = response
        .body_mut()
        .read_json::<Latest>()
        .map_err(|_| "The update server returned an unexpected response.".to_owned())?;
    Ok(decide(latest, env!("CARGO_PKG_VERSION")))
}

fn decide(mut latest: Latest, current: &str) -> Check {
    let newer = parse_version(&latest.version)
        .zip(parse_version(current))
        .is_some_and(|(latest, current)| latest > current);
    match latest.assets.remove(PLATFORM) {
        Some(url) if newer => Check::Available(Release {
            version: latest.version,
            url,
        }),
        _ => Check::UpToDate,
    }
}

fn parse_version(version: &str) -> Option<[u64; 3]> {
    let mut parts = version.split('.').map(|part| part.parse().ok());
    let parsed = [parts.next()??, parts.next()??, parts.next()??];
    parts.next().is_none().then_some(parsed)
}

#[cfg(target_os = "macos")]
pub fn install(agent: &Agent, release: &Release) -> Result<(), String> {
    let bundle =
        running_bundle().ok_or_else(|| "Updates install only into the packaged app.".to_owned())?;
    let folder = bundle.parent().expect("an app bundle is inside a folder");
    let directory = env::temp_dir().join("arbitrage-companion-update");
    let volume = directory.join("volume");
    detach(&volume);
    reset(&directory)?;
    let dmg = directory.join("update.dmg");
    download(agent, &release.url, &dmg)?;

    fs::create_dir(&volume).map_err(|_| "Could not prepare the update download.".to_owned())?;
    let attached = Command::new("/usr/bin/hdiutil")
        .args(["attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint"])
        .arg(&volume)
        .arg(&dmg)
        .status()
        .is_ok_and(|status| status.success());
    if !attached {
        return Err("Could not open the downloaded update.".to_owned());
    }
    let staged = folder.join(".arbitrage-companion-update.app");
    let _ = fs::remove_dir_all(&staged);
    let copied = Command::new("/usr/bin/ditto")
        .arg(volume.join("Arbitrage Companion.app"))
        .arg(&staged)
        .status()
        .is_ok_and(|status| status.success());
    detach(&volume);
    if !copied {
        return Err(format!(
            "Could not copy the update into {}.",
            folder.display()
        ));
    }

    let previous = folder.join(".arbitrage-companion-previous.app");
    let replace_failed = || format!("Could not replace the app in {}.", folder.display());
    let _ = fs::remove_dir_all(&previous);
    fs::rename(&bundle, &previous).map_err(|_| replace_failed())?;
    if fs::rename(&staged, &bundle).is_err() {
        let _ = fs::rename(&previous, &bundle);
        return Err(replace_failed());
    }
    let _ = fs::remove_dir_all(&previous);

    // `open` on a still-running app only activates it, so wait for this process to exit first.
    Command::new("/bin/sh")
        .args([
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\"",
            "sh",
        ])
        .arg(process::id().to_string())
        .arg(&bundle)
        .spawn()
        .map_err(|_| {
            "The update is installed. Quit and reopen Arbitrage Companion to finish.".to_owned()
        })?;
    Ok(())
}

#[cfg(target_os = "windows")]
pub fn install(agent: &Agent, release: &Release) -> Result<(), String> {
    let directory = env::temp_dir().join("arbitrage-companion-update");
    reset(&directory)?;
    let setup = directory.join("Arbitrage-Companion-setup.exe");
    download(agent, &release.url, &setup)?;
    Command::new(&setup)
        .args(["/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART"])
        .spawn()
        .map_err(|_| "Could not start the installer.".to_owned())?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn running_bundle() -> Option<PathBuf> {
    let executable = env::current_exe().ok()?;
    let bundle = executable.ancestors().nth(3)?;
    (bundle.extension()? == "app").then(|| bundle.to_path_buf())
}

#[cfg(target_os = "macos")]
fn detach(volume: &Path) {
    let _ = Command::new("/usr/bin/hdiutil")
        .args(["detach", "-quiet"])
        .arg(volume)
        .status();
}

fn reset(directory: &Path) -> Result<(), String> {
    let _ = fs::remove_dir_all(directory);
    fs::create_dir(directory).map_err(|_| "Could not prepare the update download.".to_owned())
}

fn download(agent: &Agent, url: &str, path: &Path) -> Result<(), String> {
    let response = agent.get(url).call().map_err(|error| match error {
        ureq::Error::StatusCode(status) => format!("The download server returned HTTP {status}."),
        _ => "Could not download the update.".to_owned(),
    })?;
    let mut file = File::create(path).map_err(|_| "Could not save the update.".to_owned())?;
    io::copy(&mut response.into_body().into_reader(), &mut file)
        .map_err(|_| "Could not download the update.".to_owned())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn latest(version: &str, platform: &str) -> Latest {
        serde_json::from_str(&format!(
            r#"{{"version":"{version}","assets":{{"{platform}":"https://example.com/{version}/{platform}"}}}}"#
        ))
        .unwrap()
    }

    #[test]
    fn a_newer_release_for_this_platform_is_available() {
        assert_eq!(
            decide(latest("0.4.0", PLATFORM), "0.3.9"),
            Check::Available(Release {
                version: "0.4.0".to_owned(),
                url: format!("https://example.com/0.4.0/{PLATFORM}"),
            })
        );
    }

    #[test]
    fn the_same_or_an_older_release_is_up_to_date() {
        assert_eq!(decide(latest("0.4.0", PLATFORM), "0.4.0"), Check::UpToDate);
        assert_eq!(decide(latest("0.3.9", PLATFORM), "0.4.0"), Check::UpToDate);
    }

    #[test]
    fn a_newer_release_without_this_platform_is_up_to_date() {
        assert_eq!(
            decide(latest("0.4.0", "linux-x86_64"), "0.3.9"),
            Check::UpToDate
        );
    }

    #[test]
    fn an_unparseable_release_version_is_up_to_date() {
        for version in ["latest", "0.4", "0.4.0.1", "0.4.0-beta", "v0.4.0"] {
            assert_eq!(decide(latest(version, PLATFORM), "0.3.9"), Check::UpToDate);
        }
    }

    #[test]
    fn versions_compare_by_number_not_text() {
        assert_eq!(
            decide(latest("0.10.0", PLATFORM), "0.9.9"),
            Check::Available(Release {
                version: "0.10.0".to_owned(),
                url: format!("https://example.com/0.10.0/{PLATFORM}"),
            })
        );
    }
}
