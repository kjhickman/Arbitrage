use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

use arbitrage_shared::{
    CachedScan, Faction, Import, LocalDatabase, MarketScans, MarketSyncRequest, MarketSyncResponse,
    OwnScanSummary, Scan, ScanUploadRequest, SyncRequest, SyncResponse, Timestamp, pivot, scan_id,
};
use chrono::{DateTime, Utc};
use ureq::Agent;

use crate::{
    cache::{Cache, MarketCache},
    saved_variables, sign_in,
};

const SYNC_RESPONSE_LIMIT: u64 = 32 * 1024 * 1024;
const MAX_SYNC_ROUNDS: usize = 256;

type MarketId = (u32, String, Faction);

/// Why a sync failed, and whether trying again later could help.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncError {
    pub message: String,
    /// Only a lost connection or a worker fault can pass on its own. Anything else waits for new
    /// data, signing in, or an update, each of which starts a sync anyway.
    pub retry: bool,
}

impl From<String> for SyncError {
    fn from(message: String) -> Self {
        Self {
            message,
            retry: false,
        }
    }
}

/// Returns when the import was published, for the tray's last sync time.
pub fn run(
    agent: &Agent,
    worker_url: &str,
    session: &sign_in::Session,
    account_id: &str,
    path: &Path,
    roots: &[PathBuf],
) -> Result<DateTime<Utc>, SyncError> {
    let cache = Cache::for_account(account_id);
    run_with_cache(agent, worker_url, session, &cache, path, roots)
}

fn run_with_cache(
    agent: &Agent,
    worker_url: &str,
    session: &sign_in::Session,
    cache: &Cache,
    path: &Path,
    roots: &[PathBuf],
) -> Result<DateTime<Utc>, SyncError> {
    let own = saved_variables::load(path).map_err(|error| error.to_string())?;
    let local = pivot::to_local(&own);
    drop(own);

    let mut markets_cache: BTreeMap<MarketId, MarketCache> = BTreeMap::new();
    let mut healed_cache = false;

    for _ in 0..MAX_SYNC_ROUNDS {
        let request = build_sync_request(&local, cache, &mut markets_cache);
        let text = post_json(
            agent,
            worker_url,
            session,
            &session.sync_path(),
            request.to_json(),
        )?;
        let response = serde_json::from_str::<SyncResponse>(&text)
            .map_err(|_| "The worker returned a database the addon cannot store.".to_owned())?;

        match apply_sync_round(
            agent,
            worker_url,
            session,
            &local.markets,
            cache,
            &mut markets_cache,
            &response,
        )? {
            RoundOutcome::Continue => continue,
            RoundOutcome::Stalled => {
                return Err("The worker did not finish syncing.".to_owned().into());
            }
            RoundOutcome::Done => {}
        }

        let Some(import) = build_import(&response, &mut markets_cache) else {
            if !healed_cache {
                healed_cache = true;
                continue;
            }
            return Err("Could not read the local sync cache.".to_owned().into());
        };

        saved_variables::publish_import(path, &import, roots).map_err(|error| error.to_string())?;
        return Ok(Utc::now());
    }

    Err("The worker did not finish syncing.".to_owned().into())
}

fn build_sync_request(
    local: &LocalDatabase,
    cache: &Cache,
    markets_cache: &mut BTreeMap<MarketId, MarketCache>,
) -> SyncRequest {
    let markets = local
        .markets
        .iter()
        .map(|market| {
            let key = (market.region, market.realm.clone(), market.market);
            let cached = markets_cache
                .entry(key)
                .or_insert_with(|| cache.market(market.region, &market.realm, market.market));
            MarketSyncRequest {
                region: market.region,
                realm: market.realm.clone(),
                market: market.market,
                last_played: market.last_played,
                own_scans: market
                    .scans
                    .iter()
                    .map(|scan| OwnScanSummary {
                        at: scan.at,
                        has_buyouts: scan.buyouts.is_some(),
                    })
                    .collect(),
                have_scans: cached.have_scans(),
                have_item_buyouts_at: cached.have_item_buyouts_at(),
                have_variant_buyouts_at: cached.have_variant_buyouts_at(),
            }
        })
        .collect();

    // The worker keeps the lowest price per item, so sending them again each round changes nothing.
    SyncRequest {
        markets,
        vendor_prices: local.vendor_prices.clone(),
    }
}

enum RoundOutcome {
    Done,
    Continue,
    Stalled,
}

fn apply_sync_round(
    agent: &Agent,
    worker_url: &str,
    session: &sign_in::Session,
    local_markets: &[MarketScans],
    cache: &Cache,
    markets_cache: &mut BTreeMap<MarketId, MarketCache>,
    response: &SyncResponse,
) -> Result<RoundOutcome, SyncError> {
    let mut needs_another_round = false;
    let mut made_progress = false;

    for delta in &response.markets {
        let key = (delta.region, delta.realm.clone(), delta.market);
        let cached = markets_cache
            .entry(key)
            .or_insert_with(|| cache.market(delta.region, &delta.realm, delta.market));

        if !delta.upload.is_empty() {
            needs_another_round = true;
            made_progress |=
                upload_market_scans(agent, worker_url, session, local_markets, delta, cached)?;
            continue;
        }

        if !delta.scans.is_empty() {
            made_progress = true;
        }
        needs_another_round |= delta.more_scans;
        cached
            .apply_delta(delta)
            .map_err(|_| "Could not update the local sync cache.".to_owned())?;
    }

    Ok(if !needs_another_round {
        RoundOutcome::Done
    } else if made_progress {
        RoundOutcome::Continue
    } else {
        RoundOutcome::Stalled
    })
}

fn upload_market_scans(
    agent: &Agent,
    worker_url: &str,
    session: &sign_in::Session,
    local_markets: &[MarketScans],
    delta: &MarketSyncResponse,
    cached: &mut MarketCache,
) -> Result<bool, SyncError> {
    let mut uploaded_any = false;
    for &at in &delta.upload {
        let Some(scan) =
            find_local_scan(local_markets, delta.region, &delta.realm, delta.market, at)
        else {
            continue;
        };
        let upload_request = ScanUploadRequest {
            region: delta.region,
            realm: delta.realm.clone(),
            market: delta.market,
            scan: scan.clone(),
        };
        let body =
            serde_json::to_string(&upload_request).unwrap_or_else(|error| unreachable!("{error}"));
        post_json(agent, worker_url, session, &session.sync_scan_path(), body)?;
        uploaded_any = true;
        // The worker names it the same way, so the next round does not send it back.
        let _ = cached.put_scan(&CachedScan {
            id: format!("own:{}", scan_id(scan)),
            at: scan.at,
            values: scan.values.clone(),
        });
    }
    Ok(uploaded_any)
}

fn build_import(
    response: &SyncResponse,
    markets_cache: &mut BTreeMap<MarketId, MarketCache>,
) -> Option<Import> {
    let mut import = Import::default();
    for delta in &response.markets {
        let key = (delta.region, delta.realm.clone(), delta.market);
        let Some(cached) = markets_cache.get_mut(&key) else {
            continue;
        };
        if let Some(target) = import.market_mut(delta.region, &delta.realm, delta.market)
            && cached.stream_into_import(target).is_err()
        {
            return None;
        }
    }
    import.add_vendor_prices(&response.vendor_prices);
    Some(import)
}

fn find_local_scan<'a>(
    markets: &'a [MarketScans],
    region: u32,
    realm: &str,
    market: Faction,
    at: Timestamp,
) -> Option<&'a Scan> {
    markets
        .iter()
        .filter(|entry| entry.region == region && entry.realm == realm && entry.market == market)
        .flat_map(|entry| entry.scans.iter())
        .find(|scan| scan.at == at)
}

fn post_json(
    agent: &Agent,
    worker_url: &str,
    session: &sign_in::Session,
    path: &str,
    body: String,
) -> Result<String, SyncError> {
    let mut response = match agent
        .post(sign_in::endpoint(worker_url, path))
        .header("authorization", &session.authorization())
        .header("content-type", "application/json")
        .send(body)
    {
        Ok(response) => response,
        Err(error) => return Err(transport_error(&error)),
    };

    if !response.status().is_success() {
        return Err(http_error(response.status().as_u16()));
    }

    // A body cut off mid-download is a lost connection like any other.
    response
        .body_mut()
        .with_config()
        .limit(SYNC_RESPONSE_LIMIT)
        .read_to_string()
        .map_err(|_| SyncError {
            message: "The worker returned a database the addon cannot store.".to_owned(),
            retry: true,
        })
}

fn http_error(status: u16) -> SyncError {
    let message = match status {
        401 => "Sign in again.".to_owned(),
        409 => "Sign in before syncing.".to_owned(),
        413 => "A scan was too large to upload.".to_owned(),
        422 => "This database version is not supported.".to_owned(),
        400 => "The database could not be read.".to_owned(),
        other => format!("The worker returned HTTP {other}."),
    };
    SyncError {
        message,
        retry: status == 429 || status >= 500,
    }
}

/// ureq reports 4xx and 5xx as errors, so those must stay distinct from a failed connection.
fn transport_error(error: &ureq::Error) -> SyncError {
    match error {
        ureq::Error::StatusCode(status) => http_error(*status),
        _ => SyncError {
            message: "Could not reach the worker.".to_owned(),
            retry: true,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{SyncError, http_error, run_with_cache, transport_error};
    use crate::{cache::Cache, saved_variables::temp, sign_in};
    use arbitrage_shared::{
        BuyoutList, BuyoutUpdate, CachedScan, Copper, DbKey, MarketSyncResponse, ScanUploadRequest,
        SyncRequest, SyncResponse, Timestamp, scan_id,
    };
    use std::{
        collections::BTreeMap,
        fs,
        io::{BufRead, BufReader, Read, Write},
        net::{TcpListener, TcpStream},
        sync::{Arc, Mutex},
        thread,
        time::Duration,
    };
    use ureq::Agent;

    #[test]
    fn only_failures_that_can_pass_on_their_own_are_retried() {
        for (status, message, retry) in [
            (400, "The database could not be read.", false),
            (401, "Sign in again.", false),
            (409, "Sign in before syncing.", false),
            (413, "A scan was too large to upload.", false),
            (422, "This database version is not supported.", false),
            (429, "The worker returned HTTP 429.", true),
            (500, "The worker returned HTTP 500.", true),
            (503, "The worker returned HTTP 503.", true),
        ] {
            let expected = SyncError {
                message: message.to_owned(),
                retry,
            };
            assert_eq!(http_error(status), expected, "HTTP {status}");
            // ureq reports these statuses as errors; they must not read as a lost connection.
            assert_eq!(
                transport_error(&ureq::Error::StatusCode(status)),
                expected,
                "HTTP {status}"
            );
        }

        assert_eq!(
            transport_error(&ureq::Error::ConnectionFailed),
            SyncError {
                message: "Could not reach the worker.".to_owned(),
                retry: true,
            }
        );
    }

    fn read_http_post(stream: &TcpStream) -> (String, String) {
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut request_line = String::new();
        reader.read_line(&mut request_line).unwrap();
        let path = request_line.split_whitespace().nth(1).unwrap().to_owned();
        let mut content_length = 0_usize;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if line == "\r\n" || line.is_empty() {
                break;
            }
            if let Some((name, value)) = line.split_once(':')
                && name.eq_ignore_ascii_case("content-length")
            {
                content_length = value.trim().parse().unwrap();
            }
        }
        let mut body = vec![0_u8; content_length];
        reader.read_exact(&mut body).unwrap();
        (path, String::from_utf8(body).unwrap())
    }

    fn handle_mock_sync(
        body: &str,
        uploaded_set: &BTreeMap<Timestamp, String>,
        tsm_scans: &[CachedScan],
    ) -> String {
        let req = SyncRequest::from_json(body).unwrap();
        let market = &req.markets[0];
        let missing_uploads: Vec<Timestamp> = market
            .own_scans
            .iter()
            .map(|s| s.at)
            .filter(|at| !uploaded_set.contains_key(at))
            .collect();

        let response_market = if missing_uploads.is_empty() {
            let mut active: Vec<String> = uploaded_set.values().cloned().collect();
            active.extend(tsm_scans.iter().map(|scan| scan.id.clone()));

            let missing: Vec<CachedScan> = tsm_scans
                .iter()
                .filter(|scan| !market.have_scans.contains(&scan.id))
                .cloned()
                .collect();
            let batch: Vec<CachedScan> = missing.iter().take(1).cloned().collect();
            let more_scans = missing.len() > batch.len();
            let newest_tsm = tsm_scans.last().unwrap().at;
            let item_buyouts = if market.have_item_buyouts_at == Some(newest_tsm) {
                BuyoutUpdate::Unchanged
            } else {
                BuyoutUpdate::Replace(BuyoutList {
                    at: newest_tsm,
                    prices: BTreeMap::from([(DbKey::new("2589"), Copper::new(1_350).unwrap())]),
                })
            };

            MarketSyncResponse {
                region: market.region,
                realm: market.realm.clone(),
                market: market.market,
                upload: vec![],
                active_scans: active,
                scans: batch,
                more_scans,
                item_buyouts,
                variant_buyouts: BuyoutUpdate::Unchanged,
                excluded_random_suffix: vec![],
            }
        } else {
            MarketSyncResponse {
                region: market.region,
                realm: market.realm.clone(),
                market: market.market,
                upload: missing_uploads,
                active_scans: vec![],
                scans: vec![],
                more_scans: false,
                item_buyouts: BuyoutUpdate::Unchanged,
                variant_buyouts: BuyoutUpdate::Unchanged,
                excluded_random_suffix: vec![],
            }
        };

        serde_json::to_string(&SyncResponse {
            markets: vec![response_market],
            vendor_prices: req.vendor_prices,
        })
        .unwrap()
    }

    fn start_mock_worker(
        listener: TcpListener,
        recorded_paths: Arc<Mutex<Vec<String>>>,
        recorded_uploads: Arc<Mutex<Vec<Timestamp>>>,
    ) -> thread::JoinHandle<()> {
        thread::spawn(move || {
            let mut uploaded_set = BTreeMap::new();
            let tsm_scans = [
                CachedScan {
                    id: "tsm:1700003600".to_owned(),
                    at: Timestamp::new(1_700_003_600).unwrap(),
                    values: BTreeMap::from([(DbKey::new("2589"), Copper::new(1_300).unwrap())]),
                },
                CachedScan {
                    id: "tsm:1700007200".to_owned(),
                    at: Timestamp::new(1_700_007_200).unwrap(),
                    values: BTreeMap::from([(DbKey::new("2589"), Copper::new(1_400).unwrap())]),
                },
            ];

            for _ in 0..6 {
                let (mut stream, _) = listener.accept().unwrap();
                let (path, body) = read_http_post(&stream);
                recorded_paths.lock().unwrap().push(path.clone());

                let (status, reply_body) = if path.ends_with("/sync/scan") {
                    let req: ScanUploadRequest = serde_json::from_str(&body).unwrap();
                    recorded_uploads.lock().unwrap().push(req.scan.at);
                    uploaded_set.insert(req.scan.at, format!("own:{}", scan_id(&req.scan)));
                    ("204 No Content", String::new())
                } else {
                    ("200 OK", handle_mock_sync(&body, &uploaded_set, &tsm_scans))
                };

                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    reply_body.len(),
                    reply_body
                );
                stream.write_all(response.as_bytes()).unwrap();
            }
        })
    }

    #[test]
    fn incremental_sync_uploads_one_scan_at_a_time_paginates_downloads_and_then_noops() {
        let root = temp::Dir::new("sync-e2e");
        let saved_variables = root
            .path()
            .join("WTF/Account/ACCT/SavedVariables/Arbitrage.lua");
        fs::create_dir_all(saved_variables.parent().unwrap()).unwrap();
        fs::write(
            &saved_variables,
            include_bytes!("../tests/fixtures/Arbitrage.lua"),
        )
        .unwrap();

        let addon = root.path().join("Interface/AddOns/Arbitrage");
        fs::create_dir_all(&addon).unwrap();
        fs::write(addon.join("Arbitrage.toc"), b"## Interface: 16001\n").unwrap();

        let cache = Cache::in_directory(root.path().join("cache"));
        let session =
            sign_in::decode_session(r#"{"attempt_id":"attempt-1","tray_secret":"secret-1"}"#)
                .unwrap();

        let recorded_paths: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let recorded_uploads: Arc<Mutex<Vec<Timestamp>>> = Arc::new(Mutex::new(Vec::new()));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let worker_url = format!("http://{}", listener.local_addr().unwrap());
        let server = start_mock_worker(
            listener,
            Arc::clone(&recorded_paths),
            Arc::clone(&recorded_uploads),
        );

        let agent = Agent::new_with_config(
            Agent::config_builder()
                .timeout_global(Some(Duration::from_secs(5)))
                .build(),
        );
        run_with_cache(&agent, &worker_url, &session, &cache, &saved_variables, &[])
            .expect("first sync should succeed");
        run_with_cache(&agent, &worker_url, &session, &cache, &saved_variables, &[])
            .expect("second sync should succeed in one request");
        server.join().unwrap();

        assert_eq!(
            recorded_paths.lock().unwrap().as_slice(),
            &[
                "/v1/auth/battlenet/attempts/attempt-1/sync",
                "/v1/auth/battlenet/attempts/attempt-1/sync/scan",
                "/v1/auth/battlenet/attempts/attempt-1/sync/scan",
                "/v1/auth/battlenet/attempts/attempt-1/sync",
                "/v1/auth/battlenet/attempts/attempt-1/sync",
                "/v1/auth/battlenet/attempts/attempt-1/sync",
            ]
        );
        assert_eq!(recorded_uploads.lock().unwrap().len(), 2);

        let import_lua =
            fs::read_to_string(addon.parent().unwrap().join("Arbitrage_Data/Database.lua"))
                .unwrap();
        // The uploaded scan survives because the companion and worker name it the same way.
        assert!(import_lua.contains("1700000100"));
        assert!(import_lua.contains("1700003600"));
        assert!(import_lua.contains("1700007200"));
        assert!(import_lua.contains("1350"));
    }
}
