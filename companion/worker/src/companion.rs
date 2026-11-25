use std::collections::{BTreeMap, HashMap};

use semver::Version;
use serde::{Deserialize, Serialize};
use worker::{
    CfProperties, Error, Fetch, Method, Request, RequestInit, Response, Result, RouteContext,
};

const RELEASES_URL: &str = "https://api.github.com/repos/kjhickman/Arbitrage/releases";
const PAGE_SIZE: usize = 100;
const RELEASES_CACHE_SECONDS: i32 = 300;
const ASSETS: [(&str, &str); 2] = [
    ("macos-aarch64", "Arbitrage-Companion-macos-aarch64.dmg"),
    (
        "windows-x86_64",
        "Arbitrage-Companion-windows-x86_64-setup.exe",
    ),
];

#[derive(Clone, Copy, PartialEq, Eq)]
enum Channel {
    Stable,
    Beta,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
struct Latest {
    version: String,
    assets: BTreeMap<&'static str, String>,
}

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    draft: bool,
    prerelease: bool,
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    state: String,
    browser_download_url: String,
}

pub async fn latest(_req: Request, _ctx: RouteContext<()>) -> Result<Response> {
    feed(Channel::Stable).await
}

pub async fn beta(_req: Request, _ctx: RouteContext<()>) -> Result<Response> {
    feed(Channel::Beta).await
}

async fn feed(channel: Channel) -> Result<Response> {
    let Ok(releases) = fetch_releases().await else {
        return Response::error("Service Unavailable", 503);
    };
    let Some(latest) = latest_release(releases, channel) else {
        return Response::error("Not Found", 404);
    };
    let mut response = Response::from_json(&latest)?;
    response.headers_mut().set(
        "Cache-Control",
        &format!("public, max-age={RELEASES_CACHE_SECONDS}"),
    )?;
    Ok(response)
}

pub async fn download(_req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let platform = ctx.param("platform").map_or("", String::as_str);
    let Ok(releases) = fetch_releases().await else {
        return Response::error("Service Unavailable", 503);
    };
    latest_release(releases, Channel::Stable)
        .and_then(|mut latest| latest.assets.remove(platform))
        .and_then(|url| worker::Url::parse(&url).ok())
        .map_or_else(|| Response::error("Not Found", 404), Response::redirect)
}

async fn fetch_releases() -> Result<Vec<Release>> {
    let mut releases = Vec::new();
    let mut page = 1;
    // Addon-only tags and prereleases can push the last stable installer off the first page.
    loop {
        let batch = fetch_release_page(page).await?;
        let last_page = batch.len() < PAGE_SIZE;
        releases.extend(batch);
        if last_page {
            return Ok(releases);
        }
        page += 1;
    }
}

async fn fetch_release_page(page: usize) -> Result<Vec<Release>> {
    let mut init = RequestInit::new();
    init.with_method(Method::Get)
        .with_cf_properties(CfProperties {
            cache_everything: Some(true),
            cache_ttl_by_status: Some(HashMap::from([(
                "200-299".to_owned(),
                RELEASES_CACHE_SECONDS,
            )])),
            ..CfProperties::default()
        });
    let url = format!("{RELEASES_URL}?per_page={PAGE_SIZE}&page={page}");
    let request = Request::new_with_init(&url, &init)?;
    let headers = request.headers();
    headers.set("Accept", "application/vnd.github+json")?;
    headers.set("User-Agent", "arbitrage-worker")?;
    headers.set("X-GitHub-Api-Version", "2022-11-28")?;

    let mut response = Fetch::Request(request).send().await?;
    if response.status_code() != 200 {
        return Err(Error::RustError(format!(
            "GitHub releases returned {}",
            response.status_code()
        )));
    }
    let body = response.text().await?;
    serde_json::from_str(&body).map_err(|error| Error::RustError(error.to_string()))
}

fn latest_release(releases: Vec<Release>, channel: Channel) -> Option<Latest> {
    releases
        .into_iter()
        .filter(|release| !release.draft)
        .filter_map(|release| {
            let version = Version::parse(release.tag_name.strip_prefix('v')?).ok()?;
            if !version.build.is_empty() {
                return None;
            }
            match (release.prerelease, version.pre.as_str()) {
                (false, "") => {}
                (true, pre) if channel == Channel::Beta && is_beta(pre) => {}
                _ => return None,
            }
            let assets: BTreeMap<_, _> = release
                .assets
                .into_iter()
                .filter(|asset| asset.state == "uploaded")
                .filter_map(|asset| {
                    ASSETS
                        .iter()
                        .find(|&&(_, name)| asset.name == name)
                        .map(|&(platform, _)| (platform, asset.browser_download_url))
                })
                .collect();
            // A prerelease can be public while the release job is still uploading.
            if assets.is_empty() || (release.prerelease && assets.len() != ASSETS.len()) {
                return None;
            }
            Some((version, assets))
        })
        .max_by(|(left, _), (right, _)| left.cmp(right))
        .map(|(version, assets)| Latest {
            version: version.to_string(),
            assets,
        })
}

fn is_beta(pre: &str) -> bool {
    pre.strip_prefix("beta.").is_some_and(|n| {
        !n.is_empty() && !n.starts_with('0') && n.bytes().all(|c| c.is_ascii_digit())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn releases(json: &str) -> Vec<Release> {
        serde_json::from_str(json).unwrap()
    }

    fn release(tag: &str, draft: bool, prerelease: bool, assets: &[&str]) -> String {
        let assets: Vec<_> = assets
            .iter()
            .map(|name| {
                format!(
                    r#"{{"name":"{name}","state":"uploaded","browser_download_url":"https://example.com/{tag}/{name}"}}"#
                )
            })
            .collect();
        format!(
            r#"{{"tag_name":"{tag}","draft":{draft},"prerelease":{prerelease},"body":"notes","assets":[{}]}}"#,
            assets.join(",")
        )
    }

    #[test]
    fn skips_addon_only_draft_and_prerelease_releases() {
        let json = format!(
            "[{},{},{},{},{}]",
            release("v0.3.7", false, false, &["Arbitrage-v0.3.7.zip"]),
            release(
                "v0.3.6",
                true,
                false,
                &["Arbitrage-Companion-macos-aarch64.dmg"]
            ),
            release(
                "v0.3.5-beta",
                false,
                true,
                &["Arbitrage-Companion-macos-aarch64.dmg"]
            ),
            release(
                "v0.3.4",
                false,
                false,
                &[
                    "Arbitrage-v0.3.4.zip",
                    "Arbitrage-Companion-macos-aarch64.dmg",
                    "Arbitrage-Companion-windows-x86_64-setup.exe",
                ],
            ),
            release(
                "v0.3.3",
                false,
                false,
                &["Arbitrage-Companion-macos-aarch64.dmg"]
            ),
        );

        assert_eq!(
            latest_release(releases(&json), Channel::Stable),
            Some(Latest {
                version: "0.3.4".to_owned(),
                assets: BTreeMap::from([
                    (
                        "macos-aarch64",
                        "https://example.com/v0.3.4/Arbitrage-Companion-macos-aarch64.dmg"
                            .to_owned()
                    ),
                    (
                        "windows-x86_64",
                        "https://example.com/v0.3.4/Arbitrage-Companion-windows-x86_64-setup.exe"
                            .to_owned()
                    ),
                ]),
            })
        );
    }

    #[test]
    fn has_no_latest_without_a_companion_release() {
        let json = format!(
            "[{}]",
            release("v0.3.3", false, false, &["Arbitrage-v0.3.3.zip"])
        );
        for channel in [Channel::Stable, Channel::Beta] {
            assert_eq!(latest_release(releases(&json), channel), None);
            assert_eq!(latest_release(releases("[]"), channel), None);
        }
    }

    #[test]
    fn beta_feed_offers_only_complete_beta_builds_and_stable_releases() {
        let installers: Vec<_> = ASSETS.iter().map(|&(_, name)| name).collect();
        let json = format!(
            "[{},{},{},{},{},{},{},{},{}]",
            release("v0.9.2-alpha.1", false, true, &installers),
            release("v0.9.2-rc.1", false, true, &installers),
            release("v0.9.2-beta.1", true, true, &installers),
            release("v0.9.1-beta.1", false, false, &installers),
            release("v0.9.0-beta.12", false, true, &installers[..1]),
            release("v0.9.0-beta.11", false, true, &["Arbitrage.zip"]),
            release("v0.9.0-beta.2", false, true, &installers),
            release("v0.9.0-beta.10", false, true, &installers),
            release("v0.8.7", false, false, &installers),
        );
        let beta = latest_release(releases(&json), Channel::Beta).unwrap();
        assert_eq!(beta.version, "0.9.0-beta.10");
        assert_eq!(beta.assets.len(), ASSETS.len());
        assert_eq!(
            latest_release(releases(&json), Channel::Stable)
                .unwrap()
                .version,
            "0.8.7"
        );

        let json = format!(
            "[{},{}]",
            release("v0.9.0-beta.10", false, true, &installers),
            release("v0.9.0", false, false, &installers),
        );
        assert_eq!(
            latest_release(releases(&json), Channel::Beta)
                .unwrap()
                .version,
            "0.9.0"
        );
    }

    #[test]
    fn beta_feed_ignores_a_release_with_an_incomplete_upload() {
        let installers: Vec<_> = ASSETS.iter().map(|&(_, name)| name).collect();
        let json = format!(
            "[{},{}]",
            release("v0.9.0-beta.1", false, true, &installers).replacen("uploaded", "starter", 1),
            release("v0.8.7", false, false, &installers),
        );
        assert_eq!(
            latest_release(releases(&json), Channel::Beta)
                .unwrap()
                .version,
            "0.8.7"
        );
    }
}
