use std::cell::Cell;

use serde::Serialize;
use worker::{
    Date, DurableObject, Env, Fetch, Method, ObjectNamespace, Request, RequestInit, Response,
    Result, State, Storage, Stub, durable_object,
};

use super::{
    ParseError, REALM_FEEDS, REGION_FEEDS, parse_realm_csv, parse_region_csv, schedule_plan,
};
use crate::{market::MARKET_DATABASES, region::REGION_DATABASES};

const BINDING: &str = "TSM_INGEST";
const RETRY_AT: &str = "retry_at";
const FALLBACK_RETRY_SECONDS: u64 = 3_600;

pub async fn run_scheduled(cron: &str, env: &Env) -> Result<()> {
    let stub = env
        .durable_object(BINDING)?
        .id_from_name("tsm")?
        .get_stub()?;
    let mut init = RequestInit::new();
    init.with_method(Method::Post).with_body(Some(cron.into()));
    let request = Request::new_with_init("https://tsm-ingest.internal/internal/poll", &init)?;
    let response = stub.fetch_with_request(request).await?;
    if response.status_code() != 200 {
        return Err(worker::Error::RustError(format!(
            "TSM ingestion returned HTTP {}",
            response.status_code()
        )));
    }
    Ok(())
}

/// One poller per environment. `ETag` values and the shared TSM cooldown survive Worker restarts.
#[durable_object]
pub struct TsmIngest {
    state: State,
    env: Env,
    running: Cell<bool>,
}

impl DurableObject for TsmIngest {
    fn new(state: State, env: Env) -> Self {
        Self {
            state,
            env,
            running: Cell::new(false),
        }
    }

    async fn fetch(&self, mut request: Request) -> Result<Response> {
        if request.method() != Method::Post || request.url()?.path() != "/internal/poll" {
            return Response::error("Not Found", 404);
        }

        let cron = request.text().await?;
        if self.running.replace(true) {
            worker::console_log!("TSM poll skipped: another poll is running");
            return Response::ok("already running");
        }
        let outcome = self.poll(&cron).await;
        self.running.set(false);
        outcome?;
        Response::ok("ok")
    }
}

impl TsmIngest {
    async fn poll(&self, cron: &str) -> Result<()> {
        let storage = self.state.storage();
        if let Some(retry_at) = storage.get::<u64>(RETRY_AT).await?
            && retry_at > now()
        {
            worker::console_log!("TSM poll skipped: rate limited until Unix time {retry_at}");
            return Ok(());
        }

        let plan = schedule_plan(cron);
        if plan.realms
            && !poll_feeds(
                &storage,
                &self.env.durable_object(MARKET_DATABASES)?,
                "https://market-database.internal/internal/tsm",
                "realm",
                REALM_FEEDS.map(|feed| (feed.url(), feed.market_key().object_name())),
                parse_realm_csv,
            )
            .await?
        {
            return Ok(());
        }
        if plan.regions {
            poll_feeds(
                &storage,
                &self.env.durable_object(REGION_DATABASES)?,
                "https://region-database.internal/internal/tsm",
                "region",
                REGION_FEEDS.map(|feed| (feed.url(), feed.object_name())),
                parse_region_csv,
            )
            .await?;
        }
        Ok(())
    }
}

/// Returns false when TSM rate limits the batch, so no other TSM feeds are polled this run.
async fn poll_feeds<T: Serialize>(
    storage: &Storage,
    namespace: &ObjectNamespace,
    store_url: &str,
    kind: &str,
    feeds: impl IntoIterator<Item = (String, String)>,
    parse: fn(&str) -> std::result::Result<Option<T>, ParseError>,
) -> Result<bool> {
    let (mut stored, mut unchanged) = (0, 0);
    for (url, object_name) in feeds {
        let key = format!("etag:{url}");
        let etag: Option<String> = storage.get(&key).await?;
        match fetch_csv(&url, etag.as_deref()).await {
            Ok(FetchOutcome::Unchanged) => unchanged += 1,
            Ok(FetchOutcome::RateLimited(retry_at)) => {
                storage.put(RETRY_AT, retry_at).await?;
                worker::console_error!(
                    "TSM {kind} poll rate limited at {url} after {stored} stored and {unchanged} unchanged; pausing until Unix time {retry_at}"
                );
                return Ok(false);
            }
            Ok(FetchOutcome::Body {
                csv,
                etag: new_etag,
            }) => match parse(&csv) {
                Ok(Some(snapshot)) => {
                    if let Err(error) =
                        post_snapshot(namespace, &object_name, store_url, &snapshot).await
                    {
                        worker::console_error!("TSM {kind} store failed for {url}: {error}");
                        continue;
                    }
                    // Failures must leave the old validator intact so the same CSV is retried.
                    if new_etag != etag {
                        if let Some(tag) = new_etag {
                            storage.put(&key, tag).await?;
                        } else {
                            storage.delete(&key).await?;
                        }
                    }
                    stored += 1;
                }
                Ok(None) => {}
                Err(error) => {
                    worker::console_error!("TSM {kind} CSV parse failed for {url}: {error:?}");
                }
            },
            Err(error) => {
                worker::console_error!("TSM {kind} fetch failed for {url}: {error}");
            }
        }
    }
    worker::console_log!("TSM {kind} poll: {stored} stored, {unchanged} unchanged");
    Ok(true)
}

enum FetchOutcome {
    Body { csv: String, etag: Option<String> },
    Unchanged,
    RateLimited(u64),
}

async fn fetch_csv(url: &str, etag: Option<&str>) -> Result<FetchOutcome> {
    let mut request = Request::new(url, Method::Get)?;
    let headers = request.headers_mut()?;
    headers.set("User-Agent", "arbitrage-worker")?;
    if let Some(etag) = etag {
        headers.set("If-None-Match", etag)?;
    }

    let mut response = Fetch::Request(request).send().await?;
    match response.status_code() {
        200 => Ok(FetchOutcome::Body {
            etag: response.headers().get("ETag")?,
            csv: response.text().await?,
        }),
        304 if etag.is_some() => Ok(FetchOutcome::Unchanged),
        429 => Ok(FetchOutcome::RateLimited(retry_time(
            response.headers().get("Retry-After")?.as_deref(),
            now(),
        ))),
        status => Err(worker::Error::RustError(format!("HTTP {status}"))),
    }
}

fn now() -> u64 {
    Date::now().as_millis() / 1_000
}

fn retry_time(header: Option<&str>, now: u64) -> u64 {
    if let Some(value) = header.map(str::trim) {
        if let Ok(seconds) = value.parse::<u64>() {
            return now.saturating_add(seconds);
        }
        if let Ok(date) = chrono::DateTime::parse_from_rfc2822(value)
            && let Ok(timestamp) = u64::try_from(date.timestamp())
            && timestamp >= now
        {
            return timestamp;
        }
    }
    now.saturating_add(FALLBACK_RETRY_SECONDS)
}

async fn post_snapshot(
    namespace: &ObjectNamespace,
    object_name: &str,
    url: &str,
    snapshot: &impl Serialize,
) -> Result<()> {
    let stub: Stub = namespace.id_from_name(object_name)?.get_stub()?;
    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_redirect(worker::RequestRedirect::Manual)
        .with_body(Some(serde_json::to_string(snapshot)?.into()));
    let mut request = Request::new_with_init(url, &init)?;
    request
        .headers_mut()?
        .set("Content-Type", "application/json")?;

    let response = stub.fetch_with_request(request).await?;
    if response.status_code() != 200 {
        return Err(worker::Error::RustError(format!(
            "{url} returned {}",
            response.status_code()
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::retry_time;

    #[test]
    fn respects_retry_after_seconds_and_http_dates() {
        let now = 784_111_000;
        assert_eq!(retry_time(Some(" 1200 "), now), now + 1_200);
        assert_eq!(
            retry_time(Some("Sun, 06 Nov 1994 08:49:37 GMT"), now),
            784_111_777
        );
    }

    #[test]
    fn backs_off_for_an_hour_without_a_valid_future_retry_after() {
        let now = 784_112_000;
        for header in [None, Some("bad"), Some("Sun, 06 Nov 1994 08:49:37 GMT")] {
            assert_eq!(retry_time(header, now), now + 3_600);
        }
    }
}
