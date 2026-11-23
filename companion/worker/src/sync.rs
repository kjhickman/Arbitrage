use std::collections::{BTreeMap, BTreeSet};

use arbitrage_shared::{
    Copper, Faction, ItemId, MarketSyncResponse, OwnScanSummary, PayloadError, RegionSales,
    ScanUploadRequest, SyncRequest, SyncResponse, Timestamp, VendorPrices,
};
use futures_util::future::{try_join, try_join_all};
use serde::{Serialize, de::DeserializeOwned};
use worker::{
    DurableObject, Env, Method, ObjectNamespace, Request, RequestInit, Response, State, Stub,
    durable_object,
};

use crate::{
    market::{MARKET_DATABASES, MarketSync, MarketSyncResult, MarketUploadScan},
    region::{REGION_DATABASES, SalesRequest},
};

pub const ACCOUNT_DATABASES: &str = "ACCOUNT_DATABASES";
pub(crate) const BODY_LIMIT: usize = 8 * 1024 * 1024;

const RESPONSE_SCAN_BUDGET: usize = 2 * 1024 * 1024;
const RECENT_PLAY_SECONDS: u64 = 7 * 86_400;
const MAX_REQUESTED_MARKETS: usize = 12;
const MAX_REALM_BYTES: usize = 64;
const MAX_FACTION_BYTES: usize = 16;
const VENDOR_PRICES_KEY: &str = "vendorPrices";

#[must_use]
pub(crate) const fn rejection(error: &PayloadError) -> (&'static str, u16) {
    match error {
        PayloadError::UnsupportedSchema(_) => ("Unprocessable Entity", 422),
        PayloadError::Syntax | PayloadError::Malformed => ("Bad Request", 400),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountKey(String);

impl AccountKey {
    /// Returns `None` when `raw` is empty, longer than 128 bytes, or contains a
    /// character outside ASCII alphanumerics, `-`, and `_`.
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        let safe = raw
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_');
        ((1..=128).contains(&raw.len()) && safe).then(|| Self(raw.to_owned()))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct MarketKey {
    pub region: u32,
    pub realm: String,
    pub market: Faction,
}

impl MarketKey {
    /// The Durable Object name; validation keeps `/` out of the realm so the name is unambiguous.
    #[must_use]
    pub fn object_name(&self) -> String {
        format!("{}/{}/{}", self.region, self.realm, self.market.name())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MarketSyncState {
    pub last_played: Option<Timestamp>,
    pub own_scans: Vec<OwnScanSummary>,
    pub have_scans: Vec<String>,
    pub have_item_buyouts_at: Option<Timestamp>,
    pub have_variant_buyouts_at: Option<Timestamp>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedSyncRequest {
    pub markets: BTreeMap<MarketKey, MarketSyncState>,
    pub vendor_prices: Vec<VendorPrices>,
    /// The sales snapshot the companion holds for each region it named.
    pub regions: BTreeMap<u32, Option<Timestamp>>,
}

/// Reads an incremental sync request, keeping only faction markets whose location can name a
/// market. The addon no longer scans neutral Auction Houses, so neutral entries are dropped.
///
/// # Errors
///
/// Returns the [`PayloadError`] from reading the payload.
pub fn parse_sync_request(text: &str) -> Result<ParsedSyncRequest, PayloadError> {
    let payload = SyncRequest::from_json(text)?;
    let mut parsed = ParsedSyncRequest::default();

    for entry in payload.markets {
        if !matches!(entry.market, Faction::Alliance | Faction::Horde)
            || !valid_location(entry.region, &entry.realm)
        {
            continue;
        }
        let key = MarketKey {
            region: entry.region,
            realm: entry.realm,
            market: entry.market,
        };
        let market = parsed.markets.entry(key).or_default();
        market.last_played = market.last_played.max(entry.last_played);
        market.own_scans.extend(entry.own_scans);
        market.have_scans.extend(entry.have_scans);
        market.have_item_buyouts_at = market.have_item_buyouts_at.max(entry.have_item_buyouts_at);
        market.have_variant_buyouts_at = market
            .have_variant_buyouts_at
            .max(entry.have_variant_buyouts_at);
    }

    for entry in payload.regions {
        if valid_region(entry.region) {
            let have = parsed.regions.entry(entry.region).or_default();
            *have = (*have).max(entry.have_sales_at);
        }
    }

    parsed.vendor_prices = payload
        .vendor_prices
        .into_iter()
        .filter(|entry| {
            valid_location(entry.region, &entry.realm)
                && (1..=MAX_FACTION_BYTES).contains(&entry.faction.len())
        })
        .collect();

    Ok(parsed)
}

const fn valid_region(region: u32) -> bool {
    matches!(region, 1..=255)
}

fn valid_location(region: u32, realm: &str) -> bool {
    valid_region(region)
        && (1..=MAX_REALM_BYTES).contains(&realm.len())
        && !realm
            .chars()
            .any(|character| character == '/' || character.is_control())
}

/// Picks the markets played within the recent window, newest first, up to the cap.
#[must_use]
pub fn requested_markets(
    markets: &BTreeMap<MarketKey, MarketSyncState>,
    now: u64,
) -> BTreeSet<MarketKey> {
    let cutoff = now.saturating_sub(RECENT_PLAY_SECONDS);
    let mut recent: Vec<(&MarketKey, Timestamp)> = markets
        .iter()
        .filter_map(|(key, market)| {
            market
                .last_played
                .filter(|played| played.get() >= cutoff)
                .map(|played| (key, played))
        })
        .collect();
    recent.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(right.0)));

    recent
        .into_iter()
        .take(MAX_REQUESTED_MARKETS)
        .map(|(key, _)| key.clone())
        .collect()
}

/// Lists one call per market that has local scans to check or a view to read.
#[must_use]
pub fn market_calls(
    markets: BTreeMap<MarketKey, MarketSyncState>,
    requested: &BTreeSet<MarketKey>,
) -> BTreeMap<MarketKey, MarketSyncState> {
    let mut calls: BTreeMap<_, _> = requested
        .iter()
        .map(|key| (key.clone(), MarketSyncState::default()))
        .collect();
    calls.extend(
        markets
            .into_iter()
            .filter(|(key, market)| requested.contains(key) || !market.own_scans.is_empty()),
    );
    calls
}

/// Joins stored and incoming vendor prices per location, keeping the lowest price per item.
#[must_use]
pub fn merge_vendor_prices(
    stored: Vec<VendorPrices>,
    incoming: Vec<VendorPrices>,
) -> Vec<VendorPrices> {
    let mut merged: BTreeMap<(u32, String, String), BTreeMap<ItemId, Copper>> = BTreeMap::new();

    for entry in stored.into_iter().chain(incoming) {
        let prices = merged
            .entry((entry.region, entry.realm, entry.faction))
            .or_default();
        for (item, price) in entry.prices {
            if price.get() > 0 {
                let lowest = prices.get(&item).map_or(price, |&known| known.min(price));
                prices.insert(item, lowest);
            }
        }
    }

    merged
        .into_iter()
        .filter(|(_, prices)| !prices.is_empty())
        .map(|((region, realm, faction), prices)| VendorPrices {
            region,
            realm,
            faction,
            prices,
        })
        .collect()
}

/// Checks which local scans still need uploading and answers with an incremental delta of recent
/// markets bounded by [`RESPONSE_SCAN_BUDGET`].
///
/// # Errors
///
/// Returns an error when a Durable Object cannot be reached or answers with a failure.
pub async fn sync(env: &Env, account: &AccountKey, body: String) -> worker::Result<Response> {
    let parsed = match parse_sync_request(&body) {
        Ok(parsed) => parsed,
        Err(error) => {
            let (message, status) = rejection(&error);
            return Response::error(message, status);
        }
    };
    drop(body);

    let now = worker::Date::now().as_millis() / 1_000;
    let requested = requested_markets(&parsed.markets, now);
    let max_scan_bytes = RESPONSE_SCAN_BUDGET / requested.len().max(1);
    let namespace = env.durable_object(MARKET_DATABASES)?;
    let region_namespace = env.durable_object(REGION_DATABASES)?;
    let sales = try_join_all(requested_regions(&requested).into_iter().map(|region| {
        let request = SalesRequest {
            region,
            have_at: parsed.regions.get(&region).copied().flatten(),
        };
        region_sales(&region_namespace, request)
    }));
    let markets = try_join_all(market_calls(parsed.markets, &requested).into_iter().map(
        |(key, state)| {
            let sync = MarketSync {
                account: account.as_str().to_owned(),
                contributors: vec![account.as_str().to_owned()],
                own_scans: state.own_scans,
                have_scans: state.have_scans,
                have_item_buyouts_at: state.have_item_buyouts_at,
                have_variant_buyouts_at: state.have_variant_buyouts_at,
                read: requested.contains(&key),
                max_scan_bytes,
                now,
            };
            sync_market(&namespace, key, sync)
        },
    ));
    let (sales, results) = try_join(sales, markets).await?;

    let account_database = env
        .durable_object(ACCOUNT_DATABASES)?
        .id_from_name(account.as_str())?
        .get_stub()?;
    let vendor_prices = post_json(
        &account_database,
        "https://account-database.internal/internal/vendor-prices",
        &parsed.vendor_prices,
    )
    .await?;

    let payload = SyncResponse {
        markets: results
            .into_iter()
            .filter(|(key, result)| requested.contains(key) || !result.upload.is_empty())
            .map(|(key, result)| MarketSyncResponse {
                region: key.region,
                realm: key.realm,
                market: key.market,
                upload: result.upload,
                active_scans: result.active_scans,
                scans: result.scans,
                more_scans: result.more_scans,
                item_buyouts: result.item_buyouts,
                variant_buyouts: result.variant_buyouts,
                excluded_random_suffix: result.excluded_random_suffix,
            })
            .collect(),
        vendor_prices,
        regions: sales.into_iter().flatten().collect(),
    };

    json_response(serde_json::to_string(&payload)?)
}

/// The regions of the markets read this sync, whose sales the companion keeps.
#[must_use]
pub fn requested_regions(requested: &BTreeSet<MarketKey>) -> BTreeSet<u32> {
    requested.iter().map(|key| key.region).collect()
}

async fn region_sales(
    namespace: &ObjectNamespace,
    request: SalesRequest,
) -> worker::Result<Option<RegionSales>> {
    let stub = namespace
        .id_from_name(&request.region.to_string())?
        .get_stub()?;
    post_json(
        &stub,
        "https://region-database.internal/internal/sales",
        &request,
    )
    .await
}

/// Stores one scan for one market. The companion names the scan itself with `scan_id`, so the
/// answer has no body.
///
/// # Errors
///
/// Returns an error when the market Durable Object cannot be reached or answers with a failure.
pub async fn upload_scan(
    env: &Env,
    account: &AccountKey,
    body: String,
) -> worker::Result<Response> {
    let Ok(request) = serde_json::from_str::<ScanUploadRequest>(&body) else {
        return Response::error("Bad Request", 400);
    };
    drop(body);

    if matches!(request.market, Faction::Alliance | Faction::Horde)
        && valid_location(request.region, &request.realm)
    {
        let key = MarketKey {
            region: request.region,
            realm: request.realm,
            market: request.market,
        };
        let stub = env
            .durable_object(MARKET_DATABASES)?
            .id_from_name(&key.object_name())?
            .get_stub()?;
        let upload = MarketUploadScan {
            account: account.as_str().to_owned(),
            scan: request.scan,
            now: worker::Date::now().as_millis() / 1_000,
        };
        let url = "https://market-database.internal/internal/upload-scan";
        send(&stub, json_post_request(url, &upload)?, url).await?;
    }

    Ok(Response::empty()?.with_status(204))
}

async fn sync_market(
    namespace: &ObjectNamespace,
    key: MarketKey,
    sync: MarketSync,
) -> worker::Result<(MarketKey, MarketSyncResult)> {
    let stub = namespace.id_from_name(&key.object_name())?.get_stub()?;
    let url = "https://market-database.internal/internal/sync";
    let request = json_post_request(url, &sync)?;
    drop(sync);
    let result = send(&stub, request, url).await?.json().await?;
    Ok((key, result))
}

async fn post_json<T: DeserializeOwned>(
    stub: &Stub,
    url: &str,
    body: &impl Serialize,
) -> worker::Result<T> {
    send(stub, json_post_request(url, body)?, url)
        .await?
        .json()
        .await
}

fn json_post_request(url: &str, body: &impl Serialize) -> worker::Result<Request> {
    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_redirect(worker::RequestRedirect::Manual)
        .with_body(Some(serde_json::to_string(body)?.into()));
    let mut request = Request::new_with_init(url, &init)?;
    request
        .headers_mut()?
        .set("Content-Type", "application/json")?;
    Ok(request)
}

async fn send(stub: &Stub, request: Request, url: &str) -> worker::Result<Response> {
    let response = stub.fetch_with_request(request).await?;
    if response.status_code() != 200 {
        return Err(worker::Error::RustError(format!(
            "{url} returned {}",
            response.status_code()
        )));
    }
    Ok(response)
}

fn json_response(body: String) -> worker::Result<Response> {
    let mut response = Response::ok(body)?;
    response
        .headers_mut()
        .set("Content-Type", "application/json")?;
    response.headers_mut().set("Cache-Control", "no-store")?;
    Ok(response)
}

/// Holds what stays private to one Battle.net account: its vendor prices.
#[durable_object]
pub struct AccountDatabase {
    state: State,
}

impl DurableObject for AccountDatabase {
    fn new(state: State, _env: Env) -> Self {
        Self { state }
    }

    async fn fetch(&self, mut req: Request) -> worker::Result<Response> {
        let path = req.url()?.path().to_owned();
        if req.method() != Method::Post || path != "/internal/vendor-prices" {
            return Response::error("Not Found", 404);
        }
        // Request::json parses through serde-wasm-bindgen, which does not present these
        // exact integers as u64. The JSON text is the same document serde_json already accepts.
        let text = req.text().await?;
        let Ok(incoming) = serde_json::from_str::<Vec<VendorPrices>>(&text) else {
            return Response::error("Bad Request", 400);
        };

        let storage = self.state.storage();
        let stored = match storage.get::<String>(VENDOR_PRICES_KEY).await? {
            Some(text) => serde_json::from_str(&text)?,
            None => Vec::new(),
        };
        let merged = serde_json::to_string(&merge_vendor_prices(stored, incoming))?;
        storage.put(VENDOR_PRICES_KEY, merged.clone()).await?;
        json_response(merged)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        AccountKey, MarketKey, MarketSyncState, market_calls, merge_vendor_prices,
        parse_sync_request, rejection, requested_markets, requested_regions,
    };
    use arbitrage_shared::{
        Copper, Faction, ItemId, MarketSyncRequest, OwnScanSummary, PayloadError,
        RegionSyncRequest, ScanKind, SyncRequest, Timestamp, VendorPrices,
    };
    use std::collections::{BTreeMap, BTreeSet};

    const DAY: u64 = 86_400;
    const NOW: u64 = 1_700_000_000;

    fn key(realm: &str, market: Faction) -> MarketKey {
        MarketKey {
            region: 1,
            realm: realm.to_owned(),
            market,
        }
    }

    fn summary(at: u64, has_buyouts: bool) -> OwnScanSummary {
        OwnScanSummary {
            at: Timestamp::new(at).unwrap(),
            kind: ScanKind::Full,
            has_buyouts,
        }
    }

    fn played(at: u64) -> MarketSyncState {
        MarketSyncState {
            last_played: Timestamp::new(at),
            ..MarketSyncState::default()
        }
    }

    fn market_entry(
        realm: &str,
        market: Faction,
        last_played: Option<u64>,
        own_scans: Vec<OwnScanSummary>,
    ) -> MarketSyncRequest {
        MarketSyncRequest {
            region: 1,
            realm: realm.to_owned(),
            market,
            last_played: last_played.and_then(Timestamp::new),
            own_scans,
            have_scans: vec![],
            have_item_buyouts_at: None,
            have_variant_buyouts_at: None,
        }
    }

    fn vendor(realm: &str, faction: &str, prices: &[(u64, u64)]) -> VendorPrices {
        VendorPrices {
            region: 1,
            realm: realm.to_owned(),
            faction: faction.to_owned(),
            prices: prices
                .iter()
                .map(|&(item, price)| (ItemId::new(item).unwrap(), Copper::new(price).unwrap()))
                .collect(),
        }
    }

    #[test]
    fn unknown_neutral_and_unnameable_markets_are_dropped_and_repeats_join() {
        let payload = SyncRequest {
            markets: vec![
                market_entry(
                    "Whitemane",
                    Faction::Alliance,
                    Some(NOW - 10),
                    vec![summary(NOW - 20, false)],
                ),
                market_entry(
                    "Whitemane",
                    Faction::Alliance,
                    Some(NOW),
                    vec![summary(NOW - 5, true)],
                ),
                market_entry(
                    "Whitemane",
                    Faction::Unknown,
                    Some(NOW),
                    vec![summary(NOW, false)],
                ),
                market_entry(
                    "Whitemane",
                    Faction::Neutral,
                    Some(NOW),
                    vec![summary(NOW, false)],
                ),
                market_entry("A/B", Faction::Horde, Some(NOW), vec![]),
                market_entry("", Faction::Horde, Some(NOW), vec![]),
                MarketSyncRequest {
                    region: 0,
                    ..market_entry("Faerlina", Faction::Horde, Some(NOW), vec![])
                },
            ],
            vendor_prices: vec![
                vendor("Whitemane", "Alliance", &[(1, 1)]),
                vendor("A/B", "Alliance", &[(1, 1)]),
                vendor("Whitemane", "", &[(1, 1)]),
            ],
            regions: vec![],
        };

        let parsed = parse_sync_request(&payload.to_json()).expect("the request should parse");

        assert_eq!(
            parsed.markets,
            BTreeMap::from([(
                key("Whitemane", Faction::Alliance),
                MarketSyncState {
                    last_played: Timestamp::new(NOW),
                    own_scans: vec![summary(NOW - 20, false), summary(NOW - 5, true)],
                    ..MarketSyncState::default()
                },
            )])
        );
        assert_eq!(
            parsed.vendor_prices,
            vec![vendor("Whitemane", "Alliance", &[(1, 1)])]
        );
    }

    #[test]
    fn region_sales_requests_keep_valid_regions_and_the_newest_snapshot_held() {
        let region = |region: u32, have: Option<u64>| RegionSyncRequest {
            region,
            have_sales_at: have.and_then(Timestamp::new),
        };
        let payload = SyncRequest {
            regions: vec![
                region(1, Some(NOW - DAY)),
                region(1, Some(NOW)),
                region(3, None),
                region(0, Some(NOW)),
                region(256, Some(NOW)),
            ],
            ..SyncRequest::default()
        };

        let parsed = parse_sync_request(&payload.to_json()).expect("the request should parse");

        assert_eq!(
            parsed.regions,
            BTreeMap::from([(1, Timestamp::new(NOW)), (3, None)])
        );
        assert_eq!(
            requested_regions(&BTreeSet::from([
                key("Whitemane", Faction::Alliance),
                key("Whitemane", Faction::Horde),
                MarketKey {
                    region: 3,
                    ..key("Whitemane", Faction::Horde)
                },
            ])),
            BTreeSet::from([1, 3])
        );
    }

    #[test]
    fn a_rejected_payload_keeps_its_kind() {
        assert_eq!(
            parse_sync_request(r#"{"schema":3,"markets":[]}"#),
            Err(PayloadError::UnsupportedSchema(Some(3)))
        );
        assert_eq!(parse_sync_request("not json"), Err(PayloadError::Syntax));
    }

    #[test]
    fn markets_played_within_the_week_are_requested() {
        let markets = BTreeMap::from([
            (key("Whitemane", Faction::Alliance), played(NOW - DAY)),
            (key("Whitemane", Faction::Horde), played(NOW - 7 * DAY)),
            (key("Faerlina", Faction::Horde), played(NOW - 7 * DAY - 1)),
            (
                key("Grobbulus", Faction::Alliance),
                MarketSyncState::default(),
            ),
        ]);

        assert_eq!(
            requested_markets(&markets, NOW),
            BTreeSet::from([
                key("Whitemane", Faction::Alliance),
                key("Whitemane", Faction::Horde),
            ])
        );
    }

    #[test]
    fn the_request_cap_keeps_the_most_recently_played() {
        let markets: BTreeMap<_, _> = (0..15_u64)
            .map(|index| {
                (
                    key(&format!("Realm{index}"), Faction::Horde),
                    played(NOW - index),
                )
            })
            .collect();

        let requested = requested_markets(&markets, NOW);

        assert_eq!(requested.len(), 12);
        for index in 0..12 {
            assert!(requested.contains(&key(&format!("Realm{index}"), Faction::Horde)));
        }
    }

    #[test]
    fn calls_cover_markets_with_scans_and_every_requested_market() {
        let whitemane = MarketSyncState {
            last_played: Timestamp::new(NOW),
            own_scans: vec![summary(NOW, true)],
            ..MarketSyncState::default()
        };
        let faerlina = MarketSyncState {
            own_scans: vec![summary(NOW, false)],
            ..MarketSyncState::default()
        };
        let markets = BTreeMap::from([
            (key("Whitemane", Faction::Alliance), whitemane.clone()),
            (key("Faerlina", Faction::Horde), faerlina.clone()),
            (key("Grobbulus", Faction::Horde), MarketSyncState::default()),
        ]);
        let requested = BTreeSet::from([
            key("Whitemane", Faction::Alliance),
            key("Whitemane", Faction::Horde),
        ]);

        assert_eq!(
            market_calls(markets, &requested),
            BTreeMap::from([
                (key("Faerlina", Faction::Horde), faerlina),
                (key("Whitemane", Faction::Alliance), whitemane),
                (key("Whitemane", Faction::Horde), MarketSyncState::default()),
            ])
        );
    }

    #[test]
    fn vendor_prices_keep_the_lowest_per_location_and_drop_zero() {
        let merged = merge_vendor_prices(
            vec![vendor("Whitemane", "Alliance", &[(1, 10), (2, 5)])],
            vec![
                vendor("Whitemane", "Alliance", &[(1, 8), (2, 6), (3, 0)]),
                vendor("Whitemane", "Horde", &[(1, 12)]),
                vendor("Faerlina", "Horde", &[(4, 0)]),
            ],
        );

        assert_eq!(
            merged,
            vec![
                vendor("Whitemane", "Alliance", &[(1, 8), (2, 5)]),
                vendor("Whitemane", "Horde", &[(1, 12)]),
            ]
        );
    }

    #[test]
    fn object_names_separate_region_realm_and_market() {
        assert_eq!(
            MarketKey {
                region: 3,
                realm: "Living Flame".to_owned(),
                market: Faction::Horde,
            }
            .object_name(),
            "3/Living Flame/Horde"
        );
    }

    #[test]
    fn rejection_maps_each_kind() {
        assert_eq!(rejection(&PayloadError::Syntax), ("Bad Request", 400));
        assert_eq!(rejection(&PayloadError::Malformed), ("Bad Request", 400));
        assert_eq!(
            rejection(&PayloadError::UnsupportedSchema(Some(2))),
            ("Unprocessable Entity", 422)
        );
    }

    #[test]
    fn account_key_accepts_safe_names_only() {
        assert_eq!(AccountKey::parse("42").unwrap().as_str(), "42");
        assert!(AccountKey::parse("").is_none());
        assert!(AccountKey::parse("a/b").is_none());
        assert!(AccountKey::parse(&"a".repeat(129)).is_none());
    }
}
