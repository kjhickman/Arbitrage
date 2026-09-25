use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};
use worker::{
    CfProperties, Error, Fetch, Method, Request, RequestInit, Response, Result, RouteContext,
};

const RELEASES_URL: &str = "https://api.github.com/repos/kjhickman/Arbitrage/releases?per_page=20";
const RELEASES_CACHE_SECONDS: i32 = 300;
const ASSETS: [(&str, &str); 2] = [
    ("macos-aarch64", "Arbitrage-Companion-macos-aarch64.dmg"),
    (
        "windows-x86_64",
        "Arbitrage-Companion-windows-x86_64-setup.exe",
    ),
];

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
    browser_download_url: String,
}

pub async fn latest(_req: Request, _ctx: RouteContext<()>) -> Result<Response> {
    let Ok(releases) = fetch_releases().await else {
        return Response::error("Service Unavailable", 503);
    };
    let Some(latest) = latest_release(releases) else {
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
    latest_release(releases)
        .and_then(|mut latest| latest.assets.remove(platform))
        .and_then(|url| worker::Url::parse(&url).ok())
        .map_or_else(|| Response::error("Not Found", 404), Response::redirect)
}

async fn fetch_releases() -> Result<Vec<Release>> {
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
    let request = Request::new_with_init(RELEASES_URL, &init)?;
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

/// Picks the newest published release that carries at least one companion asset.
fn latest_release(releases: Vec<Release>) -> Option<Latest> {
    releases
        .into_iter()
        .filter(|release| !release.draft && !release.prerelease)
        .find_map(|release| {
            let assets: BTreeMap<_, _> = ASSETS
                .iter()
                .filter_map(|&(platform, name)| {
                    release
                        .assets
                        .iter()
                        .find(|asset| asset.name == name)
                        .map(|asset| (platform, asset.browser_download_url.clone()))
                })
                .collect();
            (!assets.is_empty()).then(|| Latest {
                version: release.tag_name.trim_start_matches('v').to_owned(),
                assets,
            })
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
                    r#"{{"name":"{name}","browser_download_url":"https://example.com/{tag}/{name}","size":1}}"#
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
            latest_release(releases(&json)),
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
        assert_eq!(latest_release(releases(&json)), None);
        assert_eq!(latest_release(releases("[]")), None);
    }
}
