use semver::Version;
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

#[derive(Clone, Copy)]
pub enum CheckMode {
    Stable,
    Beta,
    ReturnToStable,
}

impl CheckMode {
    const fn endpoint(self) -> &'static str {
        match self {
            Self::Stable | Self::ReturnToStable => "v1/companion/latest",
            Self::Beta => "v1/companion/beta",
        }
    }
}

#[derive(Deserialize)]
struct Latest {
    version: String,
    assets: HashMap<String, String>,
}

pub fn is_prerelease_build() -> bool {
    Version::parse(env!("CARGO_PKG_VERSION")).is_ok_and(|version| !version.pre.is_empty())
}

pub fn check(agent: &Agent, worker_url: &str, mode: CheckMode) -> Result<Check, String> {
    let mut response = match agent
        .get(sign_in::endpoint(worker_url, mode.endpoint()))
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
    Ok(decide(latest, env!("CARGO_PKG_VERSION"), mode))
}

fn decide(mut latest: Latest, current: &str, mode: CheckMode) -> Check {
    let (Ok(offered), Ok(installed)) = (Version::parse(&latest.version), Version::parse(current))
    else {
        return Check::UpToDate;
    };
    let newer = offered.cmp_precedence(&installed).is_gt();
    let eligible = match mode {
        CheckMode::Stable => offered.pre.is_empty() && newer,
        CheckMode::Beta => newer,
        CheckMode::ReturnToStable => offered.pre.is_empty() && !installed.pre.is_empty(),
    };
    match latest.assets.remove(PLATFORM) {
        Some(url) if eligible => Check::Available(Release {
            version: latest.version,
            url,
        }),
        _ => Check::UpToDate,
    }
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
        .args([
            "/SILENT",
            "/SUPPRESSMSGBOXES",
            "/NORESTART",
            "/NOREDIRECTIONGUARD",
        ])
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
    fn the_same_or_an_older_release_is_up_to_date() {
        for version in ["0.4.0", "0.3.9"] {
            assert_eq!(
                decide(latest(version, PLATFORM), "0.4.0", CheckMode::Stable),
                Check::UpToDate
            );
        }
    }

    #[test]
    fn a_newer_release_without_this_platform_is_up_to_date() {
        assert_eq!(
            decide(latest("0.4.0", "linux-x86_64"), "0.3.9", CheckMode::Stable),
            Check::UpToDate
        );
    }

    #[test]
    fn an_unparseable_release_version_is_up_to_date() {
        for version in ["latest", "0.4", "0.4.0.1", "v0.4.0"] {
            assert_eq!(
                decide(latest(version, PLATFORM), "0.3.9", CheckMode::Beta),
                Check::UpToDate
            );
        }
    }

    #[test]
    fn beta_updates_are_opt_in() {
        assert_eq!(
            decide(latest("0.9.0-beta.1", PLATFORM), "0.8.7", CheckMode::Stable),
            Check::UpToDate
        );
        assert!(matches!(
            decide(latest("0.9.0-beta.1", PLATFORM), "0.8.7", CheckMode::Beta),
            Check::Available(_)
        ));
    }

    #[test]
    fn beta_numbers_sort_numerically_and_the_final_release_wins() {
        for (version, current) in [
            ("0.10.0", "0.9.9"),
            ("0.9.0-beta.10", "0.9.0-beta.2"),
            ("0.9.0", "0.9.0-beta.10"),
        ] {
            assert_eq!(
                decide(latest(version, PLATFORM), current, CheckMode::Beta),
                Check::Available(Release {
                    version: version.to_owned(),
                    url: format!("https://example.com/{version}/{PLATFORM}"),
                })
            );
        }
    }

    #[test]
    fn going_back_to_an_older_stable_release_requires_an_explicit_request() {
        let current = "0.9.0-beta.1";
        assert_eq!(
            decide(latest("0.8.7", PLATFORM), current, CheckMode::Stable),
            Check::UpToDate
        );
        assert!(matches!(
            decide(
                latest("0.8.7", PLATFORM),
                current,
                CheckMode::ReturnToStable
            ),
            Check::Available(_)
        ));
        assert_eq!(
            decide(
                latest("0.9.0-beta.2", PLATFORM),
                current,
                CheckMode::ReturnToStable,
            ),
            Check::UpToDate
        );
    }
}
