mod random_suffix;

use std::collections::BTreeMap;

use arbitrage_shared::{Copper, Faction, ItemId, Timestamp};
use serde::{Deserialize, Serialize};
use worker::{Env, Fetch, Method, ObjectNamespace, Request, RequestInit, Stub};

use crate::{
    market::MARKET_DATABASES,
    region::{REGION_DATABASES, TsmRegionItem, TsmRegionSnapshot},
    sync::MarketKey,
};

pub use random_suffix::is_random_suffix;

const BASE_URL: &str = "https://public-data.tradeskillmaster.com/forever";
const REALM_HEADER: [&str; 7] = [
    "itemId",
    "name",
    "marketValue",
    "minBuyout",
    "recent",
    "historical",
    "updatedAt",
];
const REGION_HEADER: [&str; 8] = [
    "itemId",
    "name",
    "marketValue",
    "historical",
    "avgSalePrice",
    "saleRate",
    "soldPerDay",
    "updatedAt",
];

pub const PROD_REALM_CRON: &str = "10 */3 * * *";
pub const PROD_REGION_CRON: &str = "30 1,13 * * *";
pub const STAGING_REALM_CRON: &str = "40 4,10,16,22 * * *";
pub const STAGING_REGION_CRON: &str = "30 7 * * *";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RealmFeed {
    pub region: u32,
    pub region_slug: &'static str,
    pub realm: &'static str,
    pub realm_slug: &'static str,
    pub market: Faction,
}

impl RealmFeed {
    #[must_use]
    pub fn url(self) -> String {
        let faction_slug = match self.market {
            Faction::Alliance => "alliance",
            Faction::Horde => "horde",
            Faction::Neutral | Faction::Unknown => {
                unreachable!("TSM only publishes faction houses")
            }
        };
        format!(
            "{BASE_URL}/{}/realm/{}-{faction_slug}/items.csv",
            self.region_slug, self.realm_slug
        )
    }

    #[must_use]
    pub fn market_key(self) -> MarketKey {
        MarketKey {
            region: self.region,
            realm: self.realm.to_owned(),
            market: self.market,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RegionFeed {
    pub region: u32,
    pub region_slug: &'static str,
}

impl RegionFeed {
    #[must_use]
    pub fn url(self) -> String {
        format!("{BASE_URL}/{}/region/items.csv", self.region_slug)
    }

    #[must_use]
    pub fn object_name(self) -> String {
        self.region.to_string()
    }
}

pub const REGION_FEEDS: [RegionFeed; 4] = [
    RegionFeed {
        region: 1,
        region_slug: "us",
    },
    RegionFeed {
        region: 3,
        region_slug: "eu",
    },
    RegionFeed {
        region: 4,
        region_slug: "tw",
    },
    RegionFeed {
        region: 2,
        region_slug: "kr",
    },
];

const fn realm_feed(
    region: u32,
    region_slug: &'static str,
    realm: &'static str,
    realm_slug: &'static str,
    market: Faction,
) -> RealmFeed {
    RealmFeed {
        region,
        region_slug,
        realm,
        realm_slug,
        market,
    }
}

pub const REALM_FEEDS: [RealmFeed; 24] = [
    realm_feed(1, "us", "Normal", "normal", Faction::Alliance),
    realm_feed(1, "us", "Normal", "normal", Faction::Horde),
    realm_feed(1, "us", "PvP", "pvp", Faction::Alliance),
    realm_feed(1, "us", "PvP", "pvp", Faction::Horde),
    realm_feed(1, "us", "Roleplay", "roleplay", Faction::Alliance),
    realm_feed(1, "us", "Roleplay", "roleplay", Faction::Horde),
    realm_feed(1, "us", "Roleplay PvP", "roleplay-pvp", Faction::Alliance),
    realm_feed(1, "us", "Roleplay PvP", "roleplay-pvp", Faction::Horde),
    realm_feed(3, "eu", "Normal", "normal", Faction::Alliance),
    realm_feed(3, "eu", "Normal", "normal", Faction::Horde),
    realm_feed(3, "eu", "PvP", "pvp", Faction::Alliance),
    realm_feed(3, "eu", "PvP", "pvp", Faction::Horde),
    realm_feed(3, "eu", "Roleplay", "roleplay", Faction::Alliance),
    realm_feed(3, "eu", "Roleplay", "roleplay", Faction::Horde),
    realm_feed(3, "eu", "Roleplay PvP", "roleplay-pvp", Faction::Alliance),
    realm_feed(3, "eu", "Roleplay PvP", "roleplay-pvp", Faction::Horde),
    realm_feed(4, "tw", "Normal", "normal", Faction::Alliance),
    realm_feed(4, "tw", "Normal", "normal", Faction::Horde),
    realm_feed(4, "tw", "PvP", "pvp", Faction::Alliance),
    realm_feed(4, "tw", "PvP", "pvp", Faction::Horde),
    realm_feed(2, "kr", "Normal", "normal", Faction::Alliance),
    realm_feed(2, "kr", "Normal", "normal", Faction::Horde),
    realm_feed(2, "kr", "PvP", "pvp", Faction::Alliance),
    realm_feed(2, "kr", "PvP", "pvp", Faction::Horde),
];

/// Compact `(market_value, min_buyout, recent, historical)` tuple per item.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TsmRealmItem(pub Copper, pub Copper, pub Copper, pub Copper);

impl TsmRealmItem {
    #[must_use]
    pub const fn new(
        market_value: Copper,
        min_buyout: Copper,
        recent: Copper,
        historical: Copper,
    ) -> Self {
        Self(market_value, min_buyout, recent, historical)
    }

    #[must_use]
    pub const fn min_buyout(self) -> Copper {
        self.1
    }

    #[must_use]
    pub const fn recent(self) -> Copper {
        self.2
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TsmRealmSnapshot {
    pub scanned_at: Timestamp,
    pub items: BTreeMap<ItemId, TsmRealmItem>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseError {
    Header,
    Row,
    Timestamp,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SchedulePlan {
    pub realms: bool,
    pub regions: bool,
}

#[must_use]
pub fn schedule_plan(cron: &str) -> SchedulePlan {
    match cron {
        PROD_REALM_CRON | STAGING_REALM_CRON => SchedulePlan {
            realms: true,
            regions: false,
        },
        PROD_REGION_CRON | STAGING_REGION_CRON => SchedulePlan {
            realms: false,
            regions: true,
        },
        _ => SchedulePlan {
            realms: true,
            regions: true,
        },
    }
}

pub async fn run_scheduled(cron: &str, env: &Env) {
    let plan = schedule_plan(cron);
    if plan.realms
        && let Err(error) = ingest_realms(env).await
    {
        worker::console_error!("TSM realm ingestion failed: {error}");
    }
    if plan.regions
        && let Err(error) = ingest_regions(env).await
    {
        worker::console_error!("TSM region ingestion failed: {error}");
    }
}

async fn ingest_realms(env: &Env) -> worker::Result<()> {
    let namespace = env.durable_object(MARKET_DATABASES)?;
    for feed in REALM_FEEDS {
        let url = feed.url();
        let csv = match fetch_csv(&url).await {
            Ok(FetchOutcome::Body(csv)) => csv,
            Ok(FetchOutcome::RateLimited) => {
                worker::console_error!("TSM rate limited at {url}; stopping realm batch");
                break;
            }
            Err(error) => {
                worker::console_error!("TSM realm fetch failed for {url}: {error}");
                continue;
            }
        };

        let snapshot = match parse_realm_csv(&csv) {
            Ok(Some(snapshot)) => snapshot,
            Ok(None) => continue,
            Err(error) => {
                worker::console_error!("TSM realm CSV parse failed for {url}: {error:?}");
                continue;
            }
        };

        let object_name = feed.market_key().object_name();
        if let Err(error) = post_snapshot(
            &namespace,
            &object_name,
            "https://market-database.internal/internal/tsm",
            &snapshot,
        )
        .await
        {
            worker::console_error!("TSM realm store failed for {object_name}: {error}");
        }
    }
    Ok(())
}

async fn ingest_regions(env: &Env) -> worker::Result<()> {
    let namespace = env.durable_object(REGION_DATABASES)?;
    for feed in REGION_FEEDS {
        let url = feed.url();
        let csv = match fetch_csv(&url).await {
            Ok(FetchOutcome::Body(csv)) => csv,
            Ok(FetchOutcome::RateLimited) => {
                worker::console_error!("TSM rate limited at {url}; stopping region batch");
                break;
            }
            Err(error) => {
                worker::console_error!("TSM region fetch failed for {url}: {error}");
                continue;
            }
        };

        let snapshot = match parse_region_csv(&csv) {
            Ok(Some(snapshot)) => snapshot,
            Ok(None) => continue,
            Err(error) => {
                worker::console_error!("TSM region CSV parse failed for {url}: {error:?}");
                continue;
            }
        };

        let object_name = feed.object_name();
        if let Err(error) = post_snapshot(
            &namespace,
            &object_name,
            "https://region-database.internal/internal/tsm",
            &snapshot,
        )
        .await
        {
            worker::console_error!("TSM region store failed for region {object_name}: {error}");
        }
    }
    Ok(())
}

enum FetchOutcome {
    Body(String),
    RateLimited,
}

async fn fetch_csv(url: &str) -> worker::Result<FetchOutcome> {
    let mut init = RequestInit::new();
    init.with_method(Method::Get);
    let request = Request::new_with_init(url, &init)?;
    request.headers().set("User-Agent", "arbitrage-worker")?;

    let mut response = Fetch::Request(request).send().await?;
    match response.status_code() {
        200 => Ok(FetchOutcome::Body(response.text().await?)),
        429 => Ok(FetchOutcome::RateLimited),
        status => Err(worker::Error::RustError(format!("HTTP {status}"))),
    }
}

async fn post_snapshot(
    namespace: &ObjectNamespace,
    object_name: &str,
    url: &str,
    snapshot: &impl Serialize,
) -> worker::Result<()> {
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

/// Parses a TSM realm `items.csv` document.
///
/// # Errors
///
/// Returns [`ParseError`] when the header is unrecognized, a row is malformed or truncated, or
/// timestamps within the file are invalid or inconsistent.
pub fn parse_realm_csv(csv: &str) -> Result<Option<TsmRealmSnapshot>, ParseError> {
    let mut lines = non_empty_lines(csv);
    let header_line = lines.next().ok_or(ParseError::Header)?;
    if parse_csv_row(header_line)?.as_slice() != REALM_HEADER {
        return Err(ParseError::Header);
    }

    let mut scanned_at: Option<Timestamp> = None;
    let mut items = BTreeMap::new();
    for line in lines {
        let fields = parse_csv_row(line)?;
        let [
            item_id,
            _name,
            market_value,
            min_buyout,
            recent,
            historical,
            updated_at,
        ] = fields.as_slice()
        else {
            return Err(ParseError::Row);
        };

        let item_id = parse_item_id(item_id).ok_or(ParseError::Row)?;
        let market_value = parse_copper(market_value).ok_or(ParseError::Row)?;
        let min_buyout = parse_copper(min_buyout).ok_or(ParseError::Row)?;
        let recent = parse_copper(recent).ok_or(ParseError::Row)?;
        let historical = parse_copper(historical).ok_or(ParseError::Row)?;
        let row_time = parse_timestamp(updated_at).ok_or(ParseError::Timestamp)?;
        if let Some(expected) = scanned_at {
            if row_time != expected {
                return Err(ParseError::Timestamp);
            }
        } else {
            scanned_at = Some(row_time);
        }

        items.insert(
            item_id,
            TsmRealmItem::new(market_value, min_buyout, recent, historical),
        );
    }

    Ok(scanned_at.map(|scanned_at| TsmRealmSnapshot { scanned_at, items }))
}

/// Parses a TSM region `items.csv` document.
///
/// # Errors
///
/// Returns [`ParseError`] when the header is unrecognized, a row is malformed or truncated, or
/// timestamps within the file are invalid or inconsistent.
pub fn parse_region_csv(csv: &str) -> Result<Option<TsmRegionSnapshot>, ParseError> {
    let mut lines = non_empty_lines(csv);
    let header_line = lines.next().ok_or(ParseError::Header)?;
    if parse_csv_row(header_line)?.as_slice() != REGION_HEADER {
        return Err(ParseError::Header);
    }

    let mut scanned_at: Option<Timestamp> = None;
    let mut items = BTreeMap::new();
    for line in lines {
        let fields = parse_csv_row(line)?;
        let [
            item_id,
            _name,
            market_value,
            historical,
            avg_sale_price,
            sale_rate,
            sold_per_day,
            updated_at,
        ] = fields.as_slice()
        else {
            return Err(ParseError::Row);
        };

        let item_id = parse_item_id(item_id).ok_or(ParseError::Row)?;
        let market_value = parse_copper(market_value).ok_or(ParseError::Row)?;
        let historical = parse_copper(historical).ok_or(ParseError::Row)?;
        let avg_sale_price = parse_copper(avg_sale_price).ok_or(ParseError::Row)?;
        let sale_rate = parse_non_negative_f64(sale_rate).ok_or(ParseError::Row)?;
        let sold_per_day = parse_non_negative_f64(sold_per_day).ok_or(ParseError::Row)?;
        let row_time = parse_timestamp(updated_at).ok_or(ParseError::Timestamp)?;
        if let Some(expected) = scanned_at {
            if row_time != expected {
                return Err(ParseError::Timestamp);
            }
        } else {
            scanned_at = Some(row_time);
        }

        items.insert(
            item_id,
            TsmRegionItem::new(
                market_value,
                historical,
                avg_sale_price,
                sale_rate,
                sold_per_day,
            ),
        );
    }

    Ok(scanned_at.map(|scanned_at| TsmRegionSnapshot { scanned_at, items }))
}

fn non_empty_lines(text: &str) -> impl Iterator<Item = &str> {
    text.split('\n')
        .map(|line| line.strip_suffix('\r').unwrap_or(line))
        .filter(|line| !line.is_empty())
}

fn parse_csv_row(line: &str) -> Result<Vec<String>, ParseError> {
    let mut fields = Vec::with_capacity(8);
    let mut current = String::new();
    let mut chars = line.chars().peekable();
    let mut in_quotes = false;
    let mut field_started = false;

    while let Some(ch) = chars.next() {
        if in_quotes {
            if ch == '"' {
                if chars.peek() == Some(&'"') {
                    let _ = chars.next();
                    current.push('"');
                } else {
                    in_quotes = false;
                    if !matches!(chars.peek(), None | Some(',')) {
                        return Err(ParseError::Row);
                    }
                }
            } else {
                current.push(ch);
            }
        } else if ch == ',' {
            fields.push(std::mem::take(&mut current));
            field_started = false;
        } else if ch == '"' && !field_started {
            in_quotes = true;
            field_started = true;
        } else if ch == '"' {
            return Err(ParseError::Row);
        } else {
            current.push(ch);
            field_started = true;
        }
    }

    if in_quotes {
        return Err(ParseError::Row);
    }
    fields.push(current);
    Ok(fields)
}

fn parse_item_id(text: &str) -> Option<ItemId> {
    let value = parse_canonical_u64(text)?;
    (value > 0).then(|| ItemId::new(value)).flatten()
}

fn parse_copper(text: &str) -> Option<Copper> {
    Copper::new(parse_canonical_u64(text)?)
}

fn parse_canonical_u64(text: &str) -> Option<u64> {
    if text.is_empty() || (text.len() > 1 && text.starts_with('0')) {
        return None;
    }
    if !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    text.parse::<u64>().ok()
}

fn parse_non_negative_f64(text: &str) -> Option<f64> {
    if text.is_empty() || text.starts_with('+') {
        return None;
    }
    let value = text.parse::<f64>().ok()?;
    (value.is_finite() && value >= 0.0).then_some(value)
}

/// Parses an ISO-8601 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ` or `YYYY-MM-DDTHH:MM:SS.fffZ`).
#[must_use]
pub fn parse_timestamp(text: &str) -> Option<Timestamp> {
    let body = text.strip_suffix('Z')?;
    let (date, time) = body.split_once('T')?;
    if date.len() != 10 {
        return None;
    }
    let mut date_parts = date.splitn(3, '-');
    let year_str = date_parts.next()?;
    let month_str = date_parts.next()?;
    let day_str = date_parts.next()?;
    if year_str.len() != 4 || month_str.len() != 2 || day_str.len() != 2 {
        return None;
    }
    let year: i64 = year_str.parse().ok()?;
    let month: u32 = month_str.parse().ok()?;
    let day: u32 = day_str.parse().ok()?;
    if year < 1970 || !(1..=12).contains(&month) || !(1..=days_in_month(year, month)).contains(&day)
    {
        return None;
    }

    let (hms, fraction) = match time.split_once('.') {
        Some((hms, fraction)) => {
            if fraction.is_empty() || !fraction.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            (hms, Some(fraction))
        }
        None => (time, None),
    };
    let _ = fraction;
    if hms.len() != 8 {
        return None;
    }
    let mut time_parts = hms.splitn(3, ':');
    let hour_str = time_parts.next()?;
    let minute_str = time_parts.next()?;
    let second_str = time_parts.next()?;
    if hour_str.len() != 2 || minute_str.len() != 2 || second_str.len() != 2 {
        return None;
    }
    let hour: u64 = hour_str.parse().ok()?;
    let minute: u64 = minute_str.parse().ok()?;
    let second: u64 = second_str.parse().ok()?;
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }

    let days = u64::try_from(days_from_civil(year, month, day)).ok()?;
    Timestamp::new(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

const fn is_leap_year(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

const fn days_in_month(year: i64, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap_year(year) => 29,
        2 => 28,
        _ => 0,
    }
}

/// Days since 1970-01-01 (Howard Hinnant's civil calendar algorithm).
const fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let adjusted_year = year - if month <= 2 { 1 } else { 0 };
    let era = if adjusted_year >= 0 {
        adjusted_year
    } else {
        adjusted_year - 399
    } / 400;
    let year_of_era = adjusted_year - era * 400;
    let month_signed = month as i64;
    let day_of_year =
        (153 * (month_signed + if month_signed > 2 { -3 } else { 9 }) + 2) / 5 + day as i64 - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use arbitrage_shared::{Copper, Faction, ItemId, Timestamp};

    use super::{
        PROD_REALM_CRON, PROD_REGION_CRON, ParseError, REALM_FEEDS, REGION_FEEDS,
        STAGING_REALM_CRON, STAGING_REGION_CRON, SchedulePlan, TsmRealmItem, TsmRealmSnapshot,
        parse_realm_csv, parse_region_csv, parse_timestamp, schedule_plan,
    };
    use crate::{
        region::{TsmRegionItem, TsmRegionSnapshot},
        sync::MarketKey,
    };

    #[test]
    fn parses_utc_iso_timestamps_and_rejects_invalid_dates() {
        assert_eq!(parse_timestamp("1970-01-01T00:00:00Z"), Timestamp::new(0));
        assert_eq!(
            parse_timestamp("2026-11-13T18:22:38Z"),
            Timestamp::new(1_794_594_158)
        );
        assert_eq!(
            parse_timestamp("2026-11-13T21:17:45.000Z"),
            Timestamp::new(1_794_604_665)
        );
        assert_eq!(
            parse_timestamp("2024-02-29T23:59:59Z"),
            Timestamp::new(1_709_251_199)
        );

        for invalid in [
            "",
            "2026-11-13 18:22:38Z",
            "2026-11-13T18:22:38",
            "2026-02-29T00:00:00Z",
            "2026-13-01T00:00:00Z",
            "2026-11-13T24:00:00Z",
            "2026-11-13T18:22:38.Z",
            "1969-12-31T23:59:59Z",
        ] {
            assert_eq!(parse_timestamp(invalid), None, "{invalid} should fail");
        }
    }

    #[test]
    fn parses_realm_csv_including_quoted_names_and_empty_names() {
        let csv = concat!(
            "itemId,name,marketValue,minBuyout,recent,historical,updatedAt\r\n",
            "2592,Wool Cloth,107,133,138,95,2026-11-13T18:22:38Z\r\n",
            "3024,\"BKP 2700 \"\"Enforcer\"\", Mk. II\",2146,0,0,2200,2026-11-13T18:22:38Z\r\n",
            "286750,,3516,3400,3400,2933,2026-11-13T18:22:38Z\r\n",
        );

        assert_eq!(
            parse_realm_csv(csv),
            Ok(Some(TsmRealmSnapshot {
                scanned_at: Timestamp::new(1_794_594_158).unwrap(),
                items: BTreeMap::from([
                    (
                        ItemId::new(2_592).unwrap(),
                        TsmRealmItem::new(
                            Copper::new(107).unwrap(),
                            Copper::new(133).unwrap(),
                            Copper::new(138).unwrap(),
                            Copper::new(95).unwrap(),
                        ),
                    ),
                    (
                        ItemId::new(3_024).unwrap(),
                        TsmRealmItem::new(
                            Copper::new(2_146).unwrap(),
                            Copper::new(0).unwrap(),
                            Copper::new(0).unwrap(),
                            Copper::new(2_200).unwrap(),
                        ),
                    ),
                    (
                        ItemId::new(286_750).unwrap(),
                        TsmRealmItem::new(
                            Copper::new(3_516).unwrap(),
                            Copper::new(3_400).unwrap(),
                            Copper::new(3_400).unwrap(),
                            Copper::new(2_933).unwrap(),
                        ),
                    ),
                ]),
            }))
        );
    }

    #[test]
    fn parses_region_csv_and_handles_header_only_files() {
        let header_only =
            "itemId,name,marketValue,historical,avgSalePrice,saleRate,soldPerDay,updatedAt\n";
        assert_eq!(parse_region_csv(header_only), Ok(None));

        let csv = concat!(
            "itemId,name,marketValue,historical,avgSalePrice,saleRate,soldPerDay,updatedAt\n",
            "785,Mageroyal,53,49,40,0.887,1554.024,2026-11-12T08:51:09Z\n",
        );
        assert_eq!(
            parse_region_csv(csv),
            Ok(Some(TsmRegionSnapshot {
                scanned_at: Timestamp::new(1_794_473_469).unwrap(),
                items: BTreeMap::from([(
                    ItemId::new(785).unwrap(),
                    TsmRegionItem::new(
                        Copper::new(53).unwrap(),
                        Copper::new(49).unwrap(),
                        Copper::new(40).unwrap(),
                        0.887,
                        1_554.024,
                    ),
                )]),
            }))
        );
    }

    #[test]
    fn rejects_truncated_or_inconsistent_csv_files() {
        assert_eq!(parse_realm_csv("wrong,header\n"), Err(ParseError::Header));
        assert_eq!(
            parse_realm_csv(concat!(
                "itemId,name,marketValue,minBuyout,recent,historical,updatedAt\n",
                "2592,Wool Cloth,107,133"
            )),
            Err(ParseError::Row)
        );
        assert_eq!(
            parse_realm_csv(concat!(
                "itemId,name,marketValue,minBuyout,recent,historical,updatedAt\n",
                "2592,Wool Cloth,107,133,138,95,2026-11-13T18:22:38Z\n",
                "4306,Silk Cloth,235,200,210,222,2026-11-13T21:17:45Z\n",
            )),
            Err(ParseError::Timestamp)
        );
    }

    #[test]
    fn maps_forever_feeds_to_urls_and_market_keys() {
        assert_eq!(REALM_FEEDS.len(), 24);
        assert_eq!(REGION_FEEDS.len(), 4);
        assert_eq!(
            REALM_FEEDS[7].url(),
            "https://public-data.tradeskillmaster.com/forever/us/realm/roleplay-pvp-horde/items.csv"
        );
        assert_eq!(
            REALM_FEEDS[7].market_key(),
            MarketKey {
                region: 1,
                realm: "Roleplay PvP".to_owned(),
                market: Faction::Horde,
            }
        );
        assert_eq!(
            REGION_FEEDS[0].url(),
            "https://public-data.tradeskillmaster.com/forever/us/region/items.csv"
        );
    }

    #[test]
    fn routes_cron_expressions_to_the_matching_feeds() {
        for cron in [PROD_REALM_CRON, STAGING_REALM_CRON] {
            assert_eq!(
                schedule_plan(cron),
                SchedulePlan {
                    realms: true,
                    regions: false,
                }
            );
        }
        for cron in [PROD_REGION_CRON, STAGING_REGION_CRON] {
            assert_eq!(
                schedule_plan(cron),
                SchedulePlan {
                    realms: false,
                    regions: true,
                }
            );
        }
        assert_eq!(
            schedule_plan(""),
            SchedulePlan {
                realms: true,
                regions: true,
            }
        );
    }
}
