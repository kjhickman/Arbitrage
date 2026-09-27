use std::{
    collections::{BTreeMap, BTreeSet},
    num::NonZeroU8,
};

use arbitrage_shared::{
    Copper, Faction, ItemId, MarketScans, PayloadError, Scan, SyncPayload, Timestamp, VendorPrices,
};
use futures_util::future::try_join_all;
use serde::{Serialize, de::DeserializeOwned};
use worker::{
    DurableObject, Env, Method, ObjectNamespace, Request, RequestInit, Response, State, Stub,
    durable_object,
};

use crate::internal_url;
use crate::market::{MARKET_DATABASES, MarketSync, SYNC_PATH};

pub const ACCOUNT_DATABASES: &str = "ACCOUNT_DATABASES";
pub(crate) const BODY_LIMIT: usize = 8 * 1024 * 1024;

const RECENT_PLAY_SECONDS: u64 = 7 * 86_400;
const MAX_REQUESTED_MARKETS: usize = 12;
const MAX_REALM_BYTES: usize = 64;
const VENDOR_PRICES_KEY: &str = "vendorPrices";
const VENDOR_PRICES_PATH: &str = "/internal/vendor-prices";

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
pub struct Location {
    pub region: NonZeroU8,
    pub realm: String,
}

impl Location {
    /// Returns `None` unless the region fits in one byte and the realm is 1 to 64 bytes without
    /// `/` or a control character, so it can sit between separators in a Durable Object name.
    #[must_use]
    pub fn parse(region: u32, realm: &str) -> Option<Self> {
        let safe = !realm
            .chars()
            .any(|character| character == '/' || character.is_control());
        if !(1..=MAX_REALM_BYTES).contains(&realm.len()) || !safe {
            return None;
        }
        Some(Self {
            region: u8::try_from(region).ok().and_then(NonZeroU8::new)?,
            realm: realm.to_owned(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct MarketKey {
    pub location: Location,
    pub market: Faction,
}

impl MarketKey {
    #[must_use]
    pub fn object_name(&self) -> String {
        format!(
            "{}/{}/{}",
            self.location.region, self.location.realm, self.market
        )
    }

    fn neutral(&self) -> Self {
        Self {
            market: Faction::Neutral,
            ..self.clone()
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MarketUpload {
    pub last_played: Option<Timestamp>,
    pub scans: Vec<Scan>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Upload {
    pub markets: BTreeMap<MarketKey, MarketUpload>,
    pub vendor_prices: Vec<VendorPrices>,
}

/// Reads an upload, dropping `Unknown` markets and any entry whose location cannot name a market.
///
/// # Errors
///
/// Returns the [`PayloadError`] from reading the payload.
pub fn parse_upload(text: &str) -> Result<Upload, PayloadError> {
    let payload = SyncPayload::from_json(text)?;
    let mut upload = Upload::default();

    for entry in payload.markets {
        if entry.market == Faction::Unknown {
            continue;
        }
        let Some(location) = Location::parse(entry.region, &entry.realm) else {
            continue;
        };
        let key = MarketKey {
            location,
            market: entry.market,
        };
        let market = upload.markets.entry(key).or_default();
        market.last_played = market.last_played.max(entry.last_played);
        market.scans.extend(entry.scans);
    }

    upload.vendor_prices = payload
        .vendor_prices
        .into_iter()
        .filter(|entry| Location::parse(entry.region, &entry.realm).is_some())
        .collect();

    Ok(upload)
}

/// Picks the markets played within the recent window, newest first, each with its realm's
/// Neutral market, stopping before the cap would be exceeded.
#[must_use]
pub fn requested_markets(
    markets: &BTreeMap<MarketKey, MarketUpload>,
    now: u64,
) -> BTreeSet<MarketKey> {
    let cutoff = now.saturating_sub(RECENT_PLAY_SECONDS);
    let mut recent: Vec<(&MarketKey, Timestamp)> = markets
        .iter()
        .filter(|(key, _)| matches!(key.market, Faction::Alliance | Faction::Horde))
        .filter_map(|(key, market)| {
            market
                .last_played
                .filter(|played| played.get() >= cutoff)
                .map(|played| (key, played))
        })
        .collect();
    recent.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(right.0)));

    let mut requested = BTreeSet::new();
    for (key, _) in recent {
        let neutral = key.neutral();
        let added =
            usize::from(!requested.contains(key)) + usize::from(!requested.contains(&neutral));
        if requested.len() + added > MAX_REQUESTED_MARKETS {
            break;
        }
        requested.insert(key.clone());
        requested.insert(neutral);
    }
    requested
}

/// Lists one call per market that has scans to store or a view to return.
#[must_use]
pub fn market_calls(
    upload: BTreeMap<MarketKey, MarketUpload>,
    requested: &BTreeSet<MarketKey>,
) -> BTreeMap<MarketKey, Vec<Scan>> {
    let mut calls: BTreeMap<_, _> = requested
        .iter()
        .map(|key| (key.clone(), Vec::new()))
        .collect();
    calls.extend(
        upload
            .into_iter()
            .filter(|(_, market)| !market.scans.is_empty())
            .map(|(key, market)| (key, market.scans)),
    );
    calls
}

/// Joins stored and incoming vendor prices per location, keeping the lowest price per item.
#[must_use]
pub fn merge_vendor_prices(
    stored: Vec<VendorPrices>,
    incoming: Vec<VendorPrices>,
) -> Vec<VendorPrices> {
    let mut merged: BTreeMap<(u32, String, Faction), BTreeMap<ItemId, Copper>> = BTreeMap::new();

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

/// Stores the account's upload and answers with the combined view of its recent markets.
///
/// # Errors
///
/// Returns an error when a Durable Object cannot be reached or answers with a failure.
pub async fn sync(env: &Env, account: &AccountKey, body: &str) -> worker::Result<Response> {
    let upload = match parse_upload(body) {
        Ok(upload) => upload,
        Err(error) => {
            let (message, status) = rejection(&error);
            return Response::error(message, status);
        }
    };

    let now = worker::Date::now().as_millis() / 1_000;
    let requested = requested_markets(&upload.markets, now);
    let namespace = env.durable_object(MARKET_DATABASES)?;
    let views = try_join_all(market_calls(upload.markets, &requested).into_iter().map(
        |(key, scans)| {
            let sync = MarketSync {
                account: account.as_str().to_owned(),
                contributors: vec![account.as_str().to_owned()],
                scans,
                read: requested.contains(&key),
                now,
            };
            sync_market(&namespace, key, sync)
        },
    ))
    .await?;

    let account_database = env
        .durable_object(ACCOUNT_DATABASES)?
        .id_from_name(account.as_str())?
        .get_stub()?;
    let vendor_prices =
        post_json(&account_database, VENDOR_PRICES_PATH, &upload.vendor_prices).await?;
    let payload = SyncPayload {
        markets: views
            .into_iter()
            .filter(|(key, _)| requested.contains(key))
            .map(|(key, scans)| MarketScans {
                region: u32::from(key.location.region.get()),
                realm: key.location.realm,
                market: key.market,
                last_played: None,
                scans,
            })
            .collect(),
        vendor_prices,
    };

    json_response(payload.to_json())
}

async fn sync_market(
    namespace: &ObjectNamespace,
    key: MarketKey,
    sync: MarketSync,
) -> worker::Result<(MarketKey, Vec<Scan>)> {
    let stub = namespace.id_from_name(&key.object_name())?.get_stub()?;
    let scans = post_json(&stub, SYNC_PATH, &sync).await?;
    Ok((key, scans))
}

async fn post_json<T: DeserializeOwned>(
    stub: &Stub,
    path: &str,
    body: &impl Serialize,
) -> worker::Result<T> {
    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_redirect(worker::RequestRedirect::Manual)
        .with_body(Some(serde_json::to_string(body)?.into()));
    let mut request = Request::new_with_init(&internal_url(path), &init)?;
    request
        .headers_mut()?
        .set("Content-Type", "application/json")?;

    let mut response = stub.fetch_with_request(request).await?;
    if response.status_code() != 200 {
        return Err(worker::Error::RustError(format!(
            "{path} returned {}",
            response.status_code()
        )));
    }
    response.json().await
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
        if req.method() != Method::Post || path != VENDOR_PRICES_PATH {
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
        AccountKey, Location, MarketKey, MarketUpload, market_calls, merge_vendor_prices,
        parse_upload, rejection, requested_markets,
    };
    use arbitrage_shared::{
        Copper, DbKey, Faction, ItemId, MarketScans, PayloadError, Scan, SyncPayload, Timestamp,
        VendorPrices,
    };
    use std::collections::{BTreeMap, BTreeSet};

    const DAY: u64 = 86_400;
    const NOW: u64 = 1_700_000_000;

    fn key(realm: &str, market: Faction) -> MarketKey {
        MarketKey {
            location: Location::parse(1, realm).unwrap(),
            market,
        }
    }

    fn scan(at: u64) -> Scan {
        Scan {
            at: Timestamp::new(at).unwrap(),
            values: BTreeMap::from([(DbKey::new("2589"), Copper::new(10).unwrap())]),
            buyouts: None,
        }
    }

    fn played(at: u64) -> MarketUpload {
        MarketUpload {
            last_played: Timestamp::new(at),
            scans: vec![],
        }
    }

    fn market_entry(
        realm: &str,
        market: Faction,
        last_played: Option<u64>,
        scans: Vec<Scan>,
    ) -> MarketScans {
        MarketScans {
            region: 1,
            realm: realm.to_owned(),
            market,
            last_played: last_played.and_then(Timestamp::new),
            scans,
        }
    }

    fn vendor(realm: &str, faction: Faction, prices: &[(u64, u64)]) -> VendorPrices {
        VendorPrices {
            region: 1,
            realm: realm.to_owned(),
            faction,
            prices: prices
                .iter()
                .map(|&(item, price)| (ItemId::new(item).unwrap(), Copper::new(price).unwrap()))
                .collect(),
        }
    }

    #[test]
    fn unknown_and_unnameable_markets_are_dropped_and_repeats_join() {
        let payload = SyncPayload {
            markets: vec![
                market_entry(
                    "Whitemane",
                    Faction::Alliance,
                    Some(NOW - 10),
                    vec![scan(NOW - 20)],
                ),
                market_entry(
                    "Whitemane",
                    Faction::Alliance,
                    Some(NOW),
                    vec![scan(NOW - 5)],
                ),
                market_entry("Whitemane", Faction::Unknown, Some(NOW), vec![scan(NOW)]),
                market_entry("A/B", Faction::Horde, Some(NOW), vec![]),
                market_entry("", Faction::Horde, Some(NOW), vec![]),
                MarketScans {
                    region: 0,
                    ..market_entry("Faerlina", Faction::Horde, Some(NOW), vec![])
                },
                MarketScans {
                    region: 256,
                    ..market_entry("Faerlina", Faction::Horde, Some(NOW), vec![])
                },
            ],
            vendor_prices: vec![
                vendor("Whitemane", Faction::Alliance, &[(1, 1)]),
                vendor("A/B", Faction::Alliance, &[(1, 1)]),
                VendorPrices {
                    region: 256,
                    ..vendor("Whitemane", Faction::Alliance, &[(1, 1)])
                },
            ],
        };

        let upload = parse_upload(&payload.to_json()).expect("the upload should parse");

        assert_eq!(
            upload.markets,
            BTreeMap::from([(
                key("Whitemane", Faction::Alliance),
                MarketUpload {
                    last_played: Timestamp::new(NOW),
                    scans: vec![scan(NOW - 20), scan(NOW - 5)],
                },
            )])
        );
        assert_eq!(
            upload.vendor_prices,
            vec![vendor("Whitemane", Faction::Alliance, &[(1, 1)])]
        );
    }

    #[test]
    fn a_rejected_payload_keeps_its_kind() {
        assert_eq!(
            parse_upload(r#"{"schema":1,"database":{}}"#),
            Err(PayloadError::UnsupportedSchema(Some(1)))
        );
        assert_eq!(parse_upload("not json"), Err(PayloadError::Syntax));
    }

    #[test]
    fn recently_played_markets_come_back_with_their_neutral_market() {
        let markets = BTreeMap::from([
            (key("Whitemane", Faction::Alliance), played(NOW - DAY)),
            (key("Whitemane", Faction::Horde), played(NOW - 7 * DAY)),
            (key("Faerlina", Faction::Horde), played(NOW - 7 * DAY - 1)),
            (key("Grobbulus", Faction::Alliance), MarketUpload::default()),
            (key("Grobbulus", Faction::Neutral), played(NOW)),
        ]);

        assert_eq!(
            requested_markets(&markets, NOW),
            BTreeSet::from([
                key("Whitemane", Faction::Alliance),
                key("Whitemane", Faction::Horde),
                key("Whitemane", Faction::Neutral),
            ])
        );
    }

    #[test]
    fn the_request_cap_keeps_the_most_recently_played() {
        let markets: BTreeMap<_, _> = (0..10_u64)
            .map(|index| {
                (
                    key(&format!("Realm{index}"), Faction::Horde),
                    played(NOW - index),
                )
            })
            .collect();

        let requested = requested_markets(&markets, NOW);

        assert_eq!(requested.len(), 12);
        for index in 0..6 {
            let realm = format!("Realm{index}");
            assert!(requested.contains(&key(&realm, Faction::Horde)));
            assert!(requested.contains(&key(&realm, Faction::Neutral)));
        }
    }

    #[test]
    fn calls_cover_markets_with_scans_and_every_requested_market() {
        let upload = BTreeMap::from([
            (
                key("Whitemane", Faction::Alliance),
                MarketUpload {
                    last_played: Timestamp::new(NOW),
                    scans: vec![scan(NOW)],
                },
            ),
            (
                key("Faerlina", Faction::Horde),
                MarketUpload {
                    last_played: None,
                    scans: vec![scan(NOW)],
                },
            ),
            (key("Grobbulus", Faction::Horde), MarketUpload::default()),
        ]);
        let requested = BTreeSet::from([
            key("Whitemane", Faction::Alliance),
            key("Whitemane", Faction::Neutral),
        ]);

        assert_eq!(
            market_calls(upload, &requested),
            BTreeMap::from([
                (key("Faerlina", Faction::Horde), vec![scan(NOW)]),
                (key("Whitemane", Faction::Alliance), vec![scan(NOW)]),
                (key("Whitemane", Faction::Neutral), vec![]),
            ])
        );
    }

    #[test]
    fn vendor_prices_keep_the_lowest_per_location_and_drop_zero() {
        let merged = merge_vendor_prices(
            vec![vendor("Whitemane", Faction::Alliance, &[(1, 10), (2, 5)])],
            vec![
                vendor("Whitemane", Faction::Alliance, &[(1, 8), (2, 6), (3, 0)]),
                vendor("Whitemane", Faction::Horde, &[(1, 12)]),
                vendor("Faerlina", Faction::Horde, &[(4, 0)]),
            ],
        );

        assert_eq!(
            merged,
            vec![
                vendor("Whitemane", Faction::Alliance, &[(1, 8), (2, 5)]),
                vendor("Whitemane", Faction::Horde, &[(1, 12)]),
            ]
        );
    }

    #[test]
    fn object_names_separate_region_realm_and_market() {
        assert_eq!(
            MarketKey {
                location: Location::parse(3, "Living Flame").unwrap(),
                market: Faction::Neutral,
            }
            .object_name(),
            "3/Living Flame/Neutral"
        );
    }

    #[test]
    fn rejection_maps_each_kind() {
        assert_eq!(rejection(&PayloadError::Syntax), ("Bad Request", 400));
        assert_eq!(rejection(&PayloadError::Malformed), ("Bad Request", 400));
        assert_eq!(
            rejection(&PayloadError::UnsupportedSchema(Some(1))),
            ("Unprocessable Entity", 422)
        );
    }

    #[test]
    fn locations_need_a_one_byte_region_and_a_separator_free_realm() {
        assert!(Location::parse(1, "Whitemane").is_some());
        assert!(Location::parse(255, &"a".repeat(64)).is_some());
        assert!(Location::parse(0, "Whitemane").is_none());
        assert!(Location::parse(256, "Whitemane").is_none());
        assert!(Location::parse(1, "").is_none());
        assert!(Location::parse(1, &"a".repeat(65)).is_none());
        assert!(Location::parse(1, "A/B").is_none());
        assert!(Location::parse(1, "A\nB").is_none());
    }

    #[test]
    fn account_key_accepts_safe_names_only() {
        assert_eq!(AccountKey::parse("42").unwrap().as_str(), "42");
        assert!(AccountKey::parse("").is_none());
        assert!(AccountKey::parse("a/b").is_none());
        assert!(AccountKey::parse(&"a".repeat(129)).is_none());
    }
}
