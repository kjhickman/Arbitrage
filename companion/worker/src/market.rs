use std::collections::{BTreeMap, BTreeSet};

use arbitrage_shared::{
    BuyoutList, BuyoutUpdate, CachedScan, Copper, Count, DbKey, ItemId, OwnScanSummary, Scan,
    ScanKind, Timestamp, scan_id,
};
use serde::{Deserialize, Serialize};
use worker::{
    Date, DurableObject, Env, Method, Request, Response, SqlStorage, SqlStorageValue, State,
    durable_object,
};

use crate::tsm::{self, TsmRealmItem, TsmRealmSnapshot};

pub const MARKET_DATABASES: &str = "MARKET_DATABASES";
pub const SCAN_WINDOW_SECONDS: u64 = 30 * 86_400;
const FUTURE_TOLERANCE_SECONDS: u64 = 5 * 60;

const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS scans (
    id TEXT PRIMARY KEY,
    scanned_at INTEGER NOT NULL,
    item_count INTEGER NOT NULL,
    market_values TEXT NOT NULL,
    buyouts TEXT
);
CREATE INDEX IF NOT EXISTS scans_scanned_at ON scans (scanned_at);
CREATE TABLE IF NOT EXISTS scan_uploaders (
    scan_id TEXT NOT NULL REFERENCES scans (id) ON DELETE CASCADE,
    account TEXT NOT NULL,
    PRIMARY KEY (scan_id, account)
);
CREATE TABLE IF NOT EXISTS tsm_scans (
    scanned_at INTEGER PRIMARY KEY,
    item_count INTEGER NOT NULL,
    items TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS random_suffix_items (
    item_id INTEGER PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER NOT NULL
)";
const SELECT_SCHEMA_VERSION: &str = "SELECT version FROM schema_version";
/// Version 2 gives each scan its kind, and the units and auctions it counted. Rows from before
/// are full scans without counts.
const MIGRATE_TO_2: &str = "ALTER TABLE scans ADD COLUMN kind TEXT NOT NULL DEFAULT 'full';
ALTER TABLE scans ADD COLUMN quantities TEXT;
ALTER TABLE scans ADD COLUMN auctions TEXT;
DELETE FROM schema_version;
INSERT INTO schema_version (version) VALUES (2)";
const PRUNE_SCANS: &str = "DELETE FROM scans WHERE scanned_at < ?";
const PRUNE_TSM_SCANS: &str = "DELETE FROM tsm_scans WHERE scanned_at < ?";
const INSERT_SCAN: &str = "INSERT INTO scans
        (id, kind, scanned_at, item_count, market_values, buyouts, quantities, auctions)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (id) DO UPDATE SET
        buyouts = COALESCE(scans.buyouts, excluded.buyouts),
        quantities = COALESCE(scans.quantities, excluded.quantities),
        auctions = COALESCE(scans.auctions, excluded.auctions)";
const INSERT_UPLOADER: &str =
    "INSERT OR IGNORE INTO scan_uploaders (scan_id, account) VALUES (?, ?)";
const INSERT_TSM_SCAN: &str =
    "INSERT OR IGNORE INTO tsm_scans (scanned_at, item_count, items) VALUES (?, ?, ?)";
const INSERT_RANDOM_SUFFIX_ITEM: &str =
    "INSERT OR IGNORE INTO random_suffix_items (item_id) VALUES (?)";
const SELECT_RANDOM_SUFFIX_ITEMS: &str = "SELECT item_id FROM random_suffix_items";
const SELECT_ACCOUNT_UPLOADED: &str =
    "SELECT s.kind, s.scanned_at, MAX(s.buyouts IS NOT NULL) AS has_buyouts
    FROM scans s
    JOIN scan_uploaders u ON u.scan_id = s.id
    WHERE u.account = ? AND s.scanned_at >= ?
    GROUP BY s.kind, s.scanned_at";
/// Picks one winning account scan of each kind per clock hour without reading any JSON price
/// blobs.
const SELECT_COMBINED_META: &str =
    "SELECT id, kind, scanned_at, buyouts IS NOT NULL AS has_buyouts FROM (
        SELECT s.id, s.kind, s.scanned_at, s.buyouts, ROW_NUMBER() OVER (
            PARTITION BY s.kind, s.scanned_at / 3600
            ORDER BY EXISTS (SELECT 1 FROM scan_uploaders o
                    WHERE o.scan_id = s.id AND o.account = ?) DESC,
                s.item_count DESC, s.scanned_at DESC, s.id
        ) AS place
        FROM scans s
        WHERE s.scanned_at >= ?
            AND EXISTS (SELECT 1 FROM scan_uploaders u WHERE u.scan_id = s.id
                AND u.account IN (SELECT value FROM json_each(?)))
    )
    WHERE place = 1
    ORDER BY scanned_at";
/// Picks one winning TSM snapshot per clock hour without reading any JSON price blobs.
const SELECT_TSM_META: &str = "SELECT scanned_at, item_count FROM (
        SELECT scanned_at, item_count, ROW_NUMBER() OVER (
            PARTITION BY scanned_at / 3600
            ORDER BY item_count DESC, scanned_at DESC
        ) AS place
        FROM tsm_scans
        WHERE scanned_at >= ? AND scanned_at <= ?
    )
    WHERE place = 1
    ORDER BY scanned_at";
const SELECT_SCAN_VALUES: &str =
    "SELECT market_values, buyouts, quantities, auctions FROM scans WHERE id = ?";
const SELECT_SCAN_BUYOUTS: &str = "SELECT buyouts FROM scans WHERE id = ?";
const SELECT_TSM_ITEMS: &str = "SELECT items FROM tsm_scans WHERE scanned_at = ?";

/// Incremental sync request sent from the stateless worker to one market Durable Object.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct MarketSync {
    pub account: String,
    pub contributors: Vec<String>,
    pub own_scans: Vec<OwnScanSummary>,
    pub have_scans: Vec<String>,
    pub have_item_buyouts_at: Option<Timestamp>,
    pub have_variant_buyouts_at: Option<Timestamp>,
    pub read: bool,
    pub max_scan_bytes: usize,
    pub now: u64,
}

/// Incremental sync response returned by one market Durable Object.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct MarketSyncResult {
    pub upload: Vec<Timestamp>,
    pub active_scans: Vec<String>,
    pub scans: Vec<CachedScan>,
    pub more_scans: bool,
    pub item_buyouts: BuyoutUpdate,
    pub variant_buyouts: BuyoutUpdate,
    pub excluded_random_suffix: Vec<ItemId>,
}

/// Single-scan upload forwarded from the stateless worker to one market Durable Object.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct MarketUploadScan {
    pub account: String,
    pub scan: Scan,
    pub now: u64,
}

/// Lightweight metadata for one hourly-winning account scan.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnScanMeta {
    pub id: String,
    pub kind: ScanKind,
    pub at: Timestamp,
    pub has_buyouts: bool,
}

/// Lightweight metadata for one hourly-winning TSM snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TsmScanMeta {
    pub at: Timestamp,
    pub item_count: u64,
}

/// The single winning scan chosen for one clock hour.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HourWinner {
    Own(OwnScanMeta),
    Tsm(TsmScanMeta),
}

impl HourWinner {
    #[must_use]
    pub const fn at(&self) -> Timestamp {
        match self {
            Self::Own(meta) => meta.at,
            Self::Tsm(meta) => meta.at,
        }
    }

    #[must_use]
    pub fn wire_id(&self) -> String {
        match self {
            Self::Own(meta) => own_wire_id(&meta.id),
            Self::Tsm(meta) => tsm_wire_id(meta.at),
        }
    }
}

#[must_use]
pub fn own_wire_id(id: &str) -> String {
    format!("own:{id}")
}

#[must_use]
pub fn tsm_wire_id(at: Timestamp) -> String {
    format!("tsm:{}", at.get())
}

#[must_use]
pub const fn retained_at(at: Timestamp, now: u64) -> bool {
    let seconds = at.get();
    seconds >= now.saturating_sub(SCAN_WINDOW_SECONDS) && seconds <= now + FUTURE_TOLERANCE_SECONDS
}

/// Lists the account's retained local scan timestamps that still need uploading (either missing on
/// the server, or previously stored without buyouts when the client now has buyouts for that scan).
#[must_use]
pub fn missing_uploads(
    own_scans: &[OwnScanSummary],
    uploaded: &BTreeMap<(ScanKind, Timestamp), bool>,
    now: u64,
) -> Vec<Timestamp> {
    own_scans
        .iter()
        .filter(|scan| retained_at(scan.at, now))
        .filter(|scan| {
            uploaded
                .get(&(scan.kind, scan.at))
                .is_none_or(|&stored_has_buyouts| scan.has_buyouts && !stored_has_buyouts)
        })
        .map(|scan| scan.at)
        .collect()
}

/// Extracts `<itemId>` from an `"equip:<itemId>:<suffixId>"` database key.
#[must_use]
pub fn equip_item_id(key: &DbKey) -> Option<ItemId> {
    let rest = key.as_str().strip_prefix("equip:")?;
    let (item_id, suffix) = rest.split_once(':')?;
    if suffix.is_empty() || suffix.parse::<i64>().is_err() {
        return None;
    }
    if item_id.is_empty() || (item_id.len() > 1 && item_id.starts_with('0')) {
        return None;
    }
    let parsed = item_id.parse::<u64>().ok()?;
    (parsed > 0).then(|| ItemId::new(parsed)).flatten()
}

/// Whether a key prices random-enchant gear: a variant, or the item ID of gear that comes in them.
#[must_use]
pub fn is_random_enchant(key: &DbKey, dynamic_random_suffix: &BTreeSet<ItemId>) -> bool {
    equip_item_id(key).is_some()
        || key
            .as_str()
            .parse::<u64>()
            .ok()
            .and_then(ItemId::new)
            .is_some_and(|id| tsm::is_random_suffix(id) || dynamic_random_suffix.contains(&id))
}

/// Projects one TSM column into scan prices, leaving out unlisted items and random-enchant gear.
#[must_use]
pub fn project_tsm(
    items: &BTreeMap<ItemId, TsmRealmItem>,
    dynamic_random_suffix: &BTreeSet<ItemId>,
    pick: fn(TsmRealmItem) -> Copper,
) -> BTreeMap<DbKey, Copper> {
    items
        .iter()
        .filter(|&(&id, _)| !tsm::is_random_suffix(id) && !dynamic_random_suffix.contains(&id))
        .map(|(id, &item)| (DbKey::new(id.get().to_string()), pick(item)))
        .filter(|(_, copper)| copper.get() > 0)
        .collect()
}

/// Keeps non-variant item buyouts from an account scan.
#[must_use]
pub fn filter_item_buyouts(buyouts: &BTreeMap<DbKey, Copper>) -> BTreeMap<DbKey, Copper> {
    buyouts
        .iter()
        .filter(|(key, _)| !key.as_str().starts_with("equip:"))
        .map(|(key, &price)| (key.clone(), price))
        .collect()
}

/// Keeps random-enchant buyouts (variants and their base item IDs) from an account scan, only when
/// the scan saw at least one variant.
#[must_use]
pub fn filter_variant_buyouts(
    buyouts: &BTreeMap<DbKey, Copper>,
    dynamic_random_suffix: &BTreeSet<ItemId>,
) -> Option<BTreeMap<DbKey, Copper>> {
    if !buyouts.keys().any(|key| key.as_str().starts_with("equip:")) {
        return None;
    }
    let prices: BTreeMap<DbKey, Copper> = buyouts
        .iter()
        .filter(|(key, _)| is_random_enchant(key, dynamic_random_suffix))
        .map(|(key, &price)| (key.clone(), price))
        .collect();
    (!prices.is_empty()).then_some(prices)
}

/// Joins account scan metadata with TSM scan metadata at one full scan per clock hour, preferring
/// account scans, beside one quick scan per clock hour.
#[must_use]
pub fn merge_winners(own: Vec<OwnScanMeta>, tsm: Vec<TsmScanMeta>) -> Vec<HourWinner> {
    let mut by_hour: BTreeMap<(ScanKind, u64), HourWinner> = BTreeMap::new();

    for scan in own {
        by_hour.insert((scan.kind, scan.at.get() / 3_600), HourWinner::Own(scan));
    }

    for scan in tsm {
        let hour = (ScanKind::Full, scan.at.get() / 3_600);
        match by_hour.get(&hour) {
            Some(HourWinner::Own(_)) => {}
            Some(HourWinner::Tsm(existing))
                if (scan.item_count, scan.at) <= (existing.item_count, existing.at) => {}
            _ => {
                by_hour.insert(hour, HourWinner::Tsm(scan));
            }
        }
    }

    let mut winners: Vec<HourWinner> = by_hour.into_values().collect();
    winners.sort_by_key(HourWinner::at);
    winners
}

#[durable_object]
pub struct MarketDatabase {
    state: State,
}

impl DurableObject for MarketDatabase {
    fn new(state: State, _env: Env) -> Self {
        Self { state }
    }

    async fn fetch(&self, mut req: Request) -> worker::Result<Response> {
        if req.method() != Method::Post {
            return Response::error("Not Found", 404);
        }
        let path = req.url()?.path().to_owned();
        match path.as_str() {
            "/internal/sync" => self.handle_sync(&mut req).await,
            "/internal/upload-scan" => self.handle_upload_scan(&mut req).await,
            "/internal/tsm" => self.handle_tsm(&mut req).await,
            _ => Response::error("Not Found", 404),
        }
    }
}

impl MarketDatabase {
    async fn handle_upload_scan(&self, req: &mut Request) -> worker::Result<Response> {
        let text = req.text().await?;
        let Ok(upload) = serde_json::from_str::<MarketUploadScan>(&text) else {
            return Response::error("Bad Request", 400);
        };

        // The sync round that asked for this upload already pruned the window.
        let sql = self.state.storage().sql();
        prepare(&sql)?;
        if retained_at(upload.scan.at, upload.now) {
            store(&sql, &upload.account, &upload.scan)?;
        }
        Response::ok("ok")
    }

    async fn handle_sync(&self, req: &mut Request) -> worker::Result<Response> {
        // Request::json parses through serde-wasm-bindgen, which does not present these
        // exact integers as u64. The JSON text is the same document serde_json already accepts.
        let text = req.text().await?;
        let Ok(sync) = serde_json::from_str::<MarketSync>(&text) else {
            return Response::error("Bad Request", 400);
        };

        let sql = self.state.storage().sql();
        prepare(&sql)?;
        let cutoff = sync.now.saturating_sub(SCAN_WINDOW_SECONDS);
        sql.exec(PRUNE_SCANS, vec![integer(cutoff)])?;
        sql.exec(PRUNE_TSM_SCANS, vec![integer(cutoff)])?;

        let uploaded = account_uploaded_scans(&sql, &sync.account, cutoff)?;
        let upload = missing_uploads(&sync.own_scans, &uploaded, sync.now);
        if !sync.read || !upload.is_empty() {
            return Response::from_json(&MarketSyncResult {
                upload,
                ..MarketSyncResult::default()
            });
        }

        let own_meta = account_scan_meta(&sql, &sync, cutoff)?;
        let tsm_meta = tsm_scan_meta(&sql, cutoff, sync.now + FUTURE_TOLERANCE_SECONDS)?;
        let winners = merge_winners(own_meta, tsm_meta);
        let active_scans: Vec<String> = winners.iter().map(HourWinner::wire_id).collect();

        let have: BTreeSet<&str> = sync.have_scans.iter().map(String::as_str).collect();
        let missing: Vec<&HourWinner> = winners
            .iter()
            .filter(|winner| !have.contains(winner.wire_id().as_str()))
            .collect();

        let dynamic_random_suffix = random_suffix_items(&sql)?;
        let excluded_random_suffix: Vec<ItemId> = dynamic_random_suffix
            .iter()
            .copied()
            .filter(|&id| !tsm::is_random_suffix(id))
            .collect();

        let (scans, more_scans) =
            load_missing_scans(&sql, &missing, &dynamic_random_suffix, sync.max_scan_bytes)?;
        let (item_buyouts, variant_buyouts) = load_buyout_updates(
            &sql,
            &winners,
            &dynamic_random_suffix,
            sync.have_item_buyouts_at,
            sync.have_variant_buyouts_at,
        )?;

        Response::from_json(&MarketSyncResult {
            upload,
            active_scans,
            scans,
            more_scans,
            item_buyouts,
            variant_buyouts,
            excluded_random_suffix,
        })
    }

    async fn handle_tsm(&self, req: &mut Request) -> worker::Result<Response> {
        let text = req.text().await?;
        let Ok(snapshot) = serde_json::from_str::<TsmRealmSnapshot>(&text) else {
            return Response::error("Bad Request", 400);
        };

        let sql = self.state.storage().sql();
        prepare(&sql)?;
        let cutoff = (Date::now().as_millis() / 1_000).saturating_sub(SCAN_WINDOW_SECONDS);
        sql.exec(PRUNE_TSM_SCANS, vec![integer(cutoff)])?;
        sql.exec(
            INSERT_TSM_SCAN,
            vec![
                integer(snapshot.scanned_at.get()),
                integer(snapshot.items.len() as u64),
                serde_json::to_string(&snapshot.items)?.into(),
            ],
        )?;
        Response::ok("ok")
    }
}

#[derive(Deserialize)]
struct SchemaVersionRow {
    version: u64,
}

/// Creates the tables, and brings a database from before scan kinds up to date.
fn prepare(sql: &SqlStorage) -> worker::Result<()> {
    sql.exec(SCHEMA, None)?;
    let version = sql
        .exec(SELECT_SCHEMA_VERSION, None)?
        .to_array::<SchemaVersionRow>()?
        .into_iter()
        .map(|row| row.version)
        .max()
        .unwrap_or(1);
    if version < 2 {
        sql.exec(MIGRATE_TO_2, None)?;
    }
    Ok(())
}

fn store(sql: &SqlStorage, account: &str, scan: &Scan) -> worker::Result<()> {
    let keys = scan.keys();
    let suffix_items: BTreeSet<ItemId> = keys.iter().filter_map(|key| equip_item_id(key)).collect();
    for item_id in suffix_items {
        sql.exec(INSERT_RANDOM_SUFFIX_ITEM, vec![integer(item_id.get())])?;
    }

    let id = scan_id(scan);
    let json = |value: Option<String>| -> SqlStorageValue { value.into() };
    sql.exec(
        INSERT_SCAN,
        vec![
            id.as_str().into(),
            scan.kind.name().into(),
            integer(scan.at.get()),
            integer(keys.len() as u64),
            serde_json::to_string(&scan.market_values)?.into(),
            json(
                scan.buyouts
                    .as_ref()
                    .map(serde_json::to_string)
                    .transpose()?,
            ),
            json(
                scan.quantities
                    .as_ref()
                    .map(serde_json::to_string)
                    .transpose()?,
            ),
            json(
                scan.auctions
                    .as_ref()
                    .map(serde_json::to_string)
                    .transpose()?,
            ),
        ],
    )?;
    sql.exec(INSERT_UPLOADER, vec![id.into(), account.into()])?;
    Ok(())
}

#[derive(Deserialize)]
struct UploadedScanRow {
    kind: String,
    scanned_at: u64,
    has_buyouts: u64,
}

fn account_uploaded_scans(
    sql: &SqlStorage,
    account: &str,
    cutoff: u64,
) -> worker::Result<BTreeMap<(ScanKind, Timestamp), bool>> {
    let rows = sql
        .exec(
            SELECT_ACCOUNT_UPLOADED,
            vec![account.into(), integer(cutoff)],
        )?
        .to_array::<UploadedScanRow>()?;
    let mut uploaded = BTreeMap::new();
    for row in rows {
        if let (Some(kind), Some(at)) = (
            ScanKind::from_name(&row.kind),
            Timestamp::new(row.scanned_at),
        ) {
            uploaded.insert((kind, at), row.has_buyouts != 0);
        }
    }
    Ok(uploaded)
}

#[derive(Deserialize)]
struct OwnScanMetaRow {
    id: String,
    kind: String,
    scanned_at: u64,
    has_buyouts: u64,
}

fn account_scan_meta(
    sql: &SqlStorage,
    sync: &MarketSync,
    cutoff: u64,
) -> worker::Result<Vec<OwnScanMeta>> {
    sql.exec(
        SELECT_COMBINED_META,
        vec![
            sync.account.as_str().into(),
            integer(cutoff),
            serde_json::to_string(&sync.contributors)?.into(),
        ],
    )?
    .to_array::<OwnScanMetaRow>()?
    .into_iter()
    .map(|row| {
        Ok(OwnScanMeta {
            kind: ScanKind::from_name(&row.kind)
                .ok_or_else(|| worker::Error::RustError("stored scan kind".to_owned()))?,
            id: row.id,
            at: Timestamp::new(row.scanned_at)
                .ok_or_else(|| worker::Error::RustError("stored scan time".to_owned()))?,
            has_buyouts: row.has_buyouts != 0,
        })
    })
    .collect()
}

#[derive(Deserialize)]
struct TsmScanMetaRow {
    scanned_at: u64,
    item_count: u64,
}

fn tsm_scan_meta(sql: &SqlStorage, cutoff: u64, upper: u64) -> worker::Result<Vec<TsmScanMeta>> {
    sql.exec(SELECT_TSM_META, vec![integer(cutoff), integer(upper)])?
        .to_array::<TsmScanMetaRow>()?
        .into_iter()
        .map(|row| {
            Ok(TsmScanMeta {
                at: Timestamp::new(row.scanned_at)
                    .ok_or_else(|| worker::Error::RustError("stored TSM scan time".to_owned()))?,
                item_count: row.item_count,
            })
        })
        .collect()
}

#[derive(Deserialize)]
struct RandomSuffixRow {
    item_id: u64,
}

/// The item IDs account scans have seen as random-enchant variants.
fn random_suffix_items(sql: &SqlStorage) -> worker::Result<BTreeSet<ItemId>> {
    Ok(sql
        .exec(SELECT_RANDOM_SUFFIX_ITEMS, None)?
        .to_array::<RandomSuffixRow>()?
        .into_iter()
        .filter_map(|row| ItemId::new(row.item_id))
        .collect())
}

#[derive(Deserialize)]
struct ScanValuesRow {
    market_values: String,
    buyouts: Option<String>,
    quantities: Option<String>,
    auctions: Option<String>,
}

impl ScanValuesRow {
    fn bytes(&self) -> usize {
        [&self.buyouts, &self.quantities, &self.auctions]
            .into_iter()
            .flatten()
            .map(String::len)
            .sum::<usize>()
            .saturating_add(self.market_values.len())
    }
}

fn parse_column<T: serde::de::DeserializeOwned>(
    column: Option<&str>,
) -> worker::Result<Option<BTreeMap<DbKey, T>>> {
    column
        .map(serde_json::from_str)
        .transpose()
        .map_err(Into::into)
}

#[derive(Deserialize)]
struct ScanBuyoutsRow {
    buyouts: Option<String>,
}

#[derive(Deserialize)]
struct TsmItemsRow {
    items: String,
}

fn load_missing_scans(
    sql: &SqlStorage,
    missing: &[&HourWinner],
    dynamic_random_suffix: &BTreeSet<ItemId>,
    max_scan_bytes: usize,
) -> worker::Result<(Vec<CachedScan>, bool)> {
    let mut scans = Vec::new();
    let mut estimated_bytes = 0_usize;

    // Fetch newest scans first so an interrupted initial backfill still has the latest prices.
    for winner in missing.iter().rev() {
        if !scans.is_empty() && estimated_bytes >= max_scan_bytes {
            break;
        }
        match winner {
            HourWinner::Own(meta) => {
                let Some(row) = sql
                    .exec(SELECT_SCAN_VALUES, vec![meta.id.as_str().into()])?
                    .to_array::<ScanValuesRow>()?
                    .into_iter()
                    .next()
                else {
                    continue;
                };
                estimated_bytes = estimated_bytes.saturating_add(row.bytes());
                scans.push(CachedScan {
                    id: own_wire_id(&meta.id),
                    scan: Scan {
                        at: meta.at,
                        kind: meta.kind,
                        market_values: serde_json::from_str(&row.market_values)?,
                        buyouts: parse_column::<Copper>(row.buyouts.as_deref())?,
                        quantities: parse_column::<Count>(row.quantities.as_deref())?,
                        auctions: parse_column::<Count>(row.auctions.as_deref())?,
                    },
                });
            }
            HourWinner::Tsm(meta) => {
                let Some(row) = sql
                    .exec(SELECT_TSM_ITEMS, vec![integer(meta.at.get())])?
                    .to_array::<TsmItemsRow>()?
                    .into_iter()
                    .next()
                else {
                    continue;
                };
                let items = serde_json::from_str::<BTreeMap<ItemId, TsmRealmItem>>(&row.items)?;
                let market_values =
                    project_tsm(&items, dynamic_random_suffix, TsmRealmItem::recent);
                let buyouts = project_tsm(&items, dynamic_random_suffix, TsmRealmItem::min_buyout);
                estimated_bytes = estimated_bytes
                    .saturating_add((market_values.len() + buyouts.len()).saturating_mul(14));
                scans.push(CachedScan {
                    id: tsm_wire_id(meta.at),
                    scan: Scan {
                        at: meta.at,
                        market_values,
                        buyouts: (!buyouts.is_empty()).then_some(buyouts),
                        ..Scan::default()
                    },
                });
            }
        }
    }

    let more_scans = scans.len() < missing.len();
    Ok((scans, more_scans))
}

fn load_own_buyouts(sql: &SqlStorage, id: &str) -> worker::Result<Option<BTreeMap<DbKey, Copper>>> {
    let Some(row) = sql
        .exec(SELECT_SCAN_BUYOUTS, vec![id.into()])?
        .to_array::<ScanBuyoutsRow>()?
        .into_iter()
        .next()
    else {
        return Ok(None);
    };
    row.buyouts
        .as_deref()
        .map(serde_json::from_str)
        .transpose()
        .map_err(Into::into)
}

fn load_buyout_updates(
    sql: &SqlStorage,
    winners: &[HourWinner],
    dynamic_random_suffix: &BTreeSet<ItemId>,
    have_item_buyouts_at: Option<Timestamp>,
    have_variant_buyouts_at: Option<Timestamp>,
) -> worker::Result<(BuyoutUpdate, BuyoutUpdate)> {
    let mut item_buyouts = None;
    for winner in winners.iter().rev() {
        match winner {
            HourWinner::Own(meta) if meta.has_buyouts => {
                if have_item_buyouts_at == Some(meta.at) {
                    item_buyouts = Some(BuyoutUpdate::Unchanged);
                } else {
                    let prices = load_own_buyouts(sql, &meta.id)?
                        .as_ref()
                        .map_or_else(BTreeMap::new, filter_item_buyouts);
                    item_buyouts = Some(BuyoutUpdate::Replace(BuyoutList {
                        at: meta.at,
                        prices,
                    }));
                }
                break;
            }
            HourWinner::Own(_) => {}
            HourWinner::Tsm(meta) => {
                if have_item_buyouts_at == Some(meta.at) {
                    item_buyouts = Some(BuyoutUpdate::Unchanged);
                    break;
                }
                let Some(row) = sql
                    .exec(SELECT_TSM_ITEMS, vec![integer(meta.at.get())])?
                    .to_array::<TsmItemsRow>()?
                    .into_iter()
                    .next()
                else {
                    continue;
                };
                let items = serde_json::from_str::<BTreeMap<ItemId, TsmRealmItem>>(&row.items)?;
                let prices = project_tsm(&items, dynamic_random_suffix, TsmRealmItem::min_buyout);
                if !prices.is_empty() {
                    item_buyouts = Some(BuyoutUpdate::Replace(BuyoutList {
                        at: meta.at,
                        prices,
                    }));
                    break;
                }
            }
        }
    }
    let item_buyouts = item_buyouts.unwrap_or_else(|| {
        if have_item_buyouts_at.is_some() {
            BuyoutUpdate::Clear
        } else {
            BuyoutUpdate::Unchanged
        }
    });

    // Quick scans see item IDs only, so variants come from the newest full scan.
    let newest_own_priced = winners.iter().rev().find_map(|winner| match winner {
        HourWinner::Own(meta) if meta.has_buyouts && meta.kind.is_full() => Some(meta),
        _ => None,
    });
    let variant_buyouts = match newest_own_priced {
        None => {
            if have_variant_buyouts_at.is_some() {
                BuyoutUpdate::Clear
            } else {
                BuyoutUpdate::Unchanged
            }
        }
        Some(meta) if have_variant_buyouts_at == Some(meta.at) => BuyoutUpdate::Unchanged,
        Some(meta) => {
            match load_own_buyouts(sql, &meta.id)?
                .as_ref()
                .and_then(|buyouts| filter_variant_buyouts(buyouts, dynamic_random_suffix))
            {
                Some(prices) => BuyoutUpdate::Replace(BuyoutList {
                    at: meta.at,
                    prices,
                }),
                None if have_variant_buyouts_at.is_some() => BuyoutUpdate::Clear,
                None => BuyoutUpdate::Unchanged,
            }
        }
    };

    Ok((item_buyouts, variant_buyouts))
}

fn integer(value: u64) -> SqlStorageValue {
    // Timestamps and counts stay far below 2^53, the limit both SQLite bindings and JSON share.
    SqlStorageValue::Integer(i64::try_from(value).unwrap_or(i64::MAX))
}

#[cfg(test)]
mod tests {
    use super::{
        HourWinner, OwnScanMeta, SCAN_WINDOW_SECONDS, TsmScanMeta, equip_item_id,
        filter_item_buyouts, filter_variant_buyouts, merge_winners, missing_uploads, project_tsm,
        retained_at,
    };
    use crate::tsm::TsmRealmItem;
    use arbitrage_shared::{Copper, DbKey, ItemId, OwnScanSummary, ScanKind, Timestamp};
    use std::collections::{BTreeMap, BTreeSet};

    const NOW: u64 = 1_700_000_000;

    fn at(seconds: u64) -> Timestamp {
        Timestamp::new(seconds).unwrap()
    }

    fn prices(entries: &[(&str, u64)]) -> BTreeMap<DbKey, Copper> {
        entries
            .iter()
            .map(|&(key, value)| (DbKey::new(key), Copper::new(value).unwrap()))
            .collect()
    }

    #[test]
    fn only_scans_inside_the_window_are_retained() {
        let cutoff = NOW - SCAN_WINDOW_SECONDS;

        assert!(retained_at(at(cutoff), NOW));
        assert!(!retained_at(at(cutoff - 1), NOW));
        assert!(retained_at(at(NOW + 300), NOW));
        assert!(!retained_at(at(NOW + 301), NOW));
    }

    fn summary(seconds: u64, kind: ScanKind, has_buyouts: bool) -> OwnScanSummary {
        OwnScanSummary {
            at: at(seconds),
            kind,
            has_buyouts,
        }
    }

    #[test]
    fn missing_uploads_skips_already_uploaded_and_expired_scans_but_backfills_buyouts() {
        let cutoff = NOW - SCAN_WINDOW_SECONDS;
        let own = vec![
            summary(cutoff - 1, ScanKind::Full, false),
            summary(NOW - 3_600, ScanKind::Full, false),
            summary(NOW - 1_800, ScanKind::Full, true),
            summary(NOW - 900, ScanKind::Full, true),
            summary(NOW - 600, ScanKind::Quick, true),
            summary(NOW - 60, ScanKind::Full, true),
        ];
        let uploaded = BTreeMap::from([
            // Already uploaded without buyouts, and the client has none: skipped.
            ((ScanKind::Full, at(NOW - 3_600)), false),
            // Already uploaded without buyouts, and the client has them now: backfilled.
            ((ScanKind::Full, at(NOW - 1_800)), false),
            // Already uploaded with buyouts: skipped.
            ((ScanKind::Full, at(NOW - 900)), true),
            // A full scan at the same time doesn't stand in for a quick scan.
            ((ScanKind::Full, at(NOW - 600)), true),
        ]);

        assert_eq!(
            missing_uploads(&own, &uploaded, NOW),
            vec![at(NOW - 1_800), at(NOW - 600), at(NOW - 60)]
        );
    }

    #[test]
    fn extracts_item_ids_from_suffix_equipment_keys() {
        assert_eq!(
            equip_item_id(&DbKey::new("equip:9868:-18")),
            ItemId::new(9_868)
        );
        assert_eq!(
            equip_item_id(&DbKey::new("equip:9849:776")),
            ItemId::new(9_849)
        );
        for non_equip in ["9868", "equip:0:-18", "equip:09868:-18", "equip:9868:abc"] {
            assert_eq!(equip_item_id(&DbKey::new(non_equip)), None);
        }
    }

    #[test]
    fn projects_tsm_scans_without_random_suffix_or_unlisted_items() {
        let items = BTreeMap::from([
            (
                ItemId::new(2_589).unwrap(), // Linen Cloth
                TsmRealmItem::new(
                    Copper::new(15).unwrap(),
                    Copper::new(12).unwrap(),
                    Copper::new(14).unwrap(),
                    Copper::new(16).unwrap(),
                ),
            ),
            (
                ItemId::new(9_868).unwrap(), // Static Classic random-suffix item
                TsmRealmItem::new(
                    Copper::new(3_900).unwrap(),
                    Copper::new(2_900).unwrap(),
                    Copper::new(3_600).unwrap(),
                    Copper::new(3_700).unwrap(),
                ),
            ),
            (
                ItemId::new(300_001).unwrap(), // Dynamically learned random-suffix item
                TsmRealmItem::new(
                    Copper::new(500).unwrap(),
                    Copper::new(400).unwrap(),
                    Copper::new(450).unwrap(),
                    Copper::new(500).unwrap(),
                ),
            ),
            (
                ItemId::new(4_306).unwrap(), // Unlisted in this snapshot (0 recent & minBuyout)
                TsmRealmItem::new(
                    Copper::new(235).unwrap(),
                    Copper::new(0).unwrap(),
                    Copper::new(0).unwrap(),
                    Copper::new(220).unwrap(),
                ),
            ),
        ]);
        let dynamic = BTreeSet::from([ItemId::new(300_001).unwrap()]);

        assert_eq!(
            project_tsm(&items, &dynamic, TsmRealmItem::recent),
            prices(&[("2589", 14)])
        );
        assert_eq!(
            project_tsm(&items, &dynamic, TsmRealmItem::min_buyout),
            prices(&[("2589", 12)])
        );
    }

    fn own_meta(id: &str, kind: ScanKind, seconds: u64) -> OwnScanMeta {
        OwnScanMeta {
            id: id.to_owned(),
            kind,
            at: at(seconds),
            has_buyouts: true,
        }
    }

    #[test]
    fn merge_winners_prefers_account_scans_per_clock_hour() {
        let hour = 3_600;
        let own = vec![own_meta("abc", ScanKind::Full, 10 * hour + 900)];
        let tsm = vec![
            TsmScanMeta {
                at: at(7 * hour + 100),
                item_count: 500,
            },
            TsmScanMeta {
                at: at(10 * hour + 200),
                item_count: 900,
            },
            TsmScanMeta {
                at: at(13 * hour + 300),
                item_count: 600,
            },
        ];

        assert_eq!(
            merge_winners(own, tsm),
            vec![
                HourWinner::Tsm(TsmScanMeta {
                    at: at(7 * hour + 100),
                    item_count: 500,
                }),
                HourWinner::Own(own_meta("abc", ScanKind::Full, 10 * hour + 900)),
                HourWinner::Tsm(TsmScanMeta {
                    at: at(13 * hour + 300),
                    item_count: 600,
                }),
            ]
        );
    }

    #[test]
    fn a_quick_scan_wins_its_own_hour_beside_a_full_scan() {
        let hour = 3_600;
        let tsm = vec![TsmScanMeta {
            at: at(7 * hour + 100),
            item_count: 500,
        }];
        let own = vec![
            own_meta("full", ScanKind::Full, 10 * hour + 900),
            own_meta("quick", ScanKind::Quick, 7 * hour + 50),
            own_meta("later", ScanKind::Quick, 10 * hour + 1_200),
        ];

        assert_eq!(
            merge_winners(own, tsm),
            vec![
                HourWinner::Own(own_meta("quick", ScanKind::Quick, 7 * hour + 50)),
                HourWinner::Tsm(TsmScanMeta {
                    at: at(7 * hour + 100),
                    item_count: 500,
                }),
                HourWinner::Own(own_meta("full", ScanKind::Full, 10 * hour + 900)),
                HourWinner::Own(own_meta("later", ScanKind::Quick, 10 * hour + 1_200)),
            ]
        );
    }

    #[test]
    fn buyout_filters_separate_item_ids_and_random_enchant_gear() {
        let raw = prices(&[
            ("2589", 10),
            ("9868", 3_900),   // Static random-suffix item
            ("300001", 450),   // Dynamically learned random-suffix item
            ("12640", 90_000), // Gear without random enchants
            ("equip:9868:-18", 5_000),
        ]);
        let dynamic = BTreeSet::from([ItemId::new(300_001).unwrap()]);

        assert_eq!(
            filter_item_buyouts(&raw),
            prices(&[
                ("2589", 10),
                ("9868", 3_900),
                ("300001", 450),
                ("12640", 90_000),
            ])
        );
        assert_eq!(
            filter_variant_buyouts(&raw, &dynamic),
            Some(prices(&[
                ("9868", 3_900),
                ("300001", 450),
                ("equip:9868:-18", 5_000),
            ]))
        );
        assert_eq!(
            filter_variant_buyouts(&prices(&[("2589", 10), ("9868", 3_900)]), &dynamic),
            None
        );
    }
}
