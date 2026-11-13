use std::collections::{BTreeMap, BTreeSet};

use arbitrage_shared::{Copper, DbKey, ItemId, Scan, Timestamp};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use worker::{
    DurableObject, Env, Method, Request, Response, SqlStorage, SqlStorageValue, State,
    durable_object,
};

use crate::{
    auth::types::digest_sha256,
    tsm::{self, TsmRealmItem, TsmRealmSnapshot},
};

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
)";
const PRUNE_SCANS: &str = "DELETE FROM scans WHERE scanned_at < ?";
const INSERT_SCAN: &str = "INSERT INTO scans (id, scanned_at, item_count, market_values, buyouts)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT (id) DO UPDATE SET buyouts = COALESCE(scans.buyouts, excluded.buyouts)";
const INSERT_UPLOADER: &str =
    "INSERT OR IGNORE INTO scan_uploaders (scan_id, account) VALUES (?, ?)";
const INSERT_TSM_SCAN: &str =
    "INSERT OR IGNORE INTO tsm_scans (scanned_at, item_count, items) VALUES (?, ?, ?)";
const INSERT_RANDOM_SUFFIX_ITEM: &str =
    "INSERT OR IGNORE INTO random_suffix_items (item_id) VALUES (?)";
const SELECT_RANDOM_SUFFIX_ITEMS: &str = "SELECT item_id FROM random_suffix_items";
const SELECT_TSM_SCANS: &str = "SELECT scanned_at, items FROM tsm_scans WHERE scanned_at >= ? AND scanned_at <= ? ORDER BY scanned_at";
/// Keeps one scan per clock hour: the requester's own first, then the fullest, then the newest,
/// then the lowest id.
const SELECT_COMBINED: &str = "SELECT scanned_at, market_values, buyouts FROM (
        SELECT s.scanned_at, s.market_values, s.buyouts, ROW_NUMBER() OVER (
            PARTITION BY s.scanned_at / 3600
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

/// What the worker sends one market: the account's own scans, and whether it wants the
/// combined view back.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct MarketSync {
    pub account: String,
    pub contributors: Vec<String>,
    pub scans: Vec<Scan>,
    pub read: bool,
    pub now: u64,
}

/// Names a scan by its time and market values, so the same scan from two uploads is one row.
///
/// Buyouts are not part of the name, because the addon drops them from all but its latest scan.
#[must_use]
pub fn scan_id(scan: &Scan) -> String {
    let values =
        serde_json::to_string(&scan.values).unwrap_or_else(|error| unreachable!("{error}"));
    let named = format!("{}:{values}", scan.at.get());
    URL_SAFE_NO_PAD.encode(digest_sha256(named.as_bytes()).0)
}

#[must_use]
pub const fn retained(scan: &Scan, now: u64) -> bool {
    let at = scan.at.get();
    at >= now.saturating_sub(SCAN_WINDOW_SECONDS) && at <= now + FUTURE_TOLERANCE_SECONDS
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

#[must_use]
pub fn project_tsm_scan(
    scanned_at: Timestamp,
    items: &BTreeMap<ItemId, TsmRealmItem>,
    dynamic_random_suffix: &BTreeSet<ItemId>,
) -> Option<Scan> {
    let mut values = BTreeMap::new();
    let mut buyouts = BTreeMap::new();

    for (&item_id, item) in items {
        if tsm::is_random_suffix(item_id) || dynamic_random_suffix.contains(&item_id) {
            continue;
        }
        let key = DbKey::new(item_id.get().to_string());
        if item.recent().get() > 0 {
            values.insert(key.clone(), item.recent());
        }
        if item.min_buyout().get() > 0 {
            buyouts.insert(key, item.min_buyout());
        }
    }

    if values.is_empty() && buyouts.is_empty() {
        return None;
    }

    Some(Scan {
        at: scanned_at,
        values,
        buyouts: (!buyouts.is_empty()).then_some(buyouts),
    })
}

/// Joins account scans with projected TSM scans at one scan per clock hour, preferring account
/// scans, and retains `buyouts` only on the single newest priced scan.
#[must_use]
pub fn merge_scans(own_scans: Vec<Scan>, tsm_scans: Vec<Scan>) -> Vec<Scan> {
    let mut by_hour: BTreeMap<u64, (bool, Scan)> = BTreeMap::new();

    for scan in own_scans {
        by_hour.insert(scan.at.get() / 3_600, (true, scan));
    }

    for scan in tsm_scans {
        let hour = scan.at.get() / 3_600;
        match by_hour.get(&hour) {
            Some((true, _)) => {}
            Some((false, existing))
                if (scan.values.len(), scan.at) <= (existing.values.len(), existing.at) => {}
            _ => {
                by_hour.insert(hour, (false, scan));
            }
        }
    }

    let mut merged: Vec<Scan> = by_hour.into_values().map(|(_, scan)| scan).collect();
    merged.sort_by_key(|scan| scan.at);

    if let Some(latest_priced_at) = merged
        .iter()
        .filter(|scan| scan.buyouts.is_some())
        .map(|scan| scan.at)
        .max()
    {
        for scan in &mut merged {
            if scan.at < latest_priced_at {
                scan.buyouts = None;
            }
        }
    }

    merged
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
            "/internal/tsm" => self.handle_tsm(&mut req).await,
            _ => Response::error("Not Found", 404),
        }
    }
}

impl MarketDatabase {
    async fn handle_sync(&self, req: &mut Request) -> worker::Result<Response> {
        // Request::json parses through serde-wasm-bindgen, which does not present these
        // exact integers as u64. The JSON text is the same document serde_json already accepts.
        let text = req.text().await?;
        let Ok(sync) = serde_json::from_str::<MarketSync>(&text) else {
            return Response::error("Bad Request", 400);
        };

        let sql = self.state.storage().sql();
        sql.exec(SCHEMA, None)?;
        let cutoff = sync.now.saturating_sub(SCAN_WINDOW_SECONDS);
        sql.exec(PRUNE_SCANS, vec![integer(cutoff)])?;
        for scan in sync.scans.iter().filter(|scan| retained(scan, sync.now)) {
            store(&sql, &sync.account, scan)?;
        }

        let scans = if sync.read {
            let own = account_scans(&sql, &sync, cutoff)?;
            let tsm = tsm_scans(&sql, cutoff, sync.now + FUTURE_TOLERANCE_SECONDS)?;
            merge_scans(own, tsm)
        } else {
            Vec::new()
        };
        Response::from_json(&scans)
    }

    async fn handle_tsm(&self, req: &mut Request) -> worker::Result<Response> {
        let text = req.text().await?;
        let Ok(snapshot) = serde_json::from_str::<TsmRealmSnapshot>(&text) else {
            return Response::error("Bad Request", 400);
        };

        let sql = self.state.storage().sql();
        sql.exec(SCHEMA, None)?;
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

fn store(sql: &SqlStorage, account: &str, scan: &Scan) -> worker::Result<()> {
    let mut suffix_items = BTreeSet::new();
    for key in scan
        .values
        .keys()
        .chain(scan.buyouts.iter().flat_map(BTreeMap::keys))
    {
        if let Some(item_id) = equip_item_id(key) {
            suffix_items.insert(item_id);
        }
    }
    for item_id in suffix_items {
        sql.exec(INSERT_RANDOM_SUFFIX_ITEM, vec![integer(item_id.get())])?;
    }

    let id = scan_id(scan);
    let buyouts = scan
        .buyouts
        .as_ref()
        .map(serde_json::to_string)
        .transpose()?;
    sql.exec(
        INSERT_SCAN,
        vec![
            id.as_str().into(),
            integer(scan.at.get()),
            integer(scan.values.len() as u64),
            serde_json::to_string(&scan.values)?.into(),
            buyouts.into(),
        ],
    )?;
    sql.exec(INSERT_UPLOADER, vec![id.into(), account.into()])?;
    Ok(())
}

#[derive(Deserialize)]
struct ScanRow {
    scanned_at: u64,
    market_values: String,
    buyouts: Option<String>,
}

fn account_scans(sql: &SqlStorage, sync: &MarketSync, cutoff: u64) -> worker::Result<Vec<Scan>> {
    sql.exec(
        SELECT_COMBINED,
        vec![
            sync.account.as_str().into(),
            integer(cutoff),
            serde_json::to_string(&sync.contributors)?.into(),
        ],
    )?
    .to_array::<ScanRow>()?
    .into_iter()
    .map(|row| {
        Ok(Scan {
            at: Timestamp::new(row.scanned_at)
                .ok_or_else(|| worker::Error::RustError("stored scan time".to_owned()))?,
            values: serde_json::from_str::<BTreeMap<DbKey, Copper>>(&row.market_values)?,
            buyouts: row
                .buyouts
                .as_deref()
                .map(serde_json::from_str)
                .transpose()?,
        })
    })
    .collect()
}

#[derive(Deserialize)]
struct RandomSuffixRow {
    item_id: u64,
}

#[derive(Deserialize)]
struct TsmScanRow {
    scanned_at: u64,
    items: String,
}

fn tsm_scans(sql: &SqlStorage, cutoff: u64, upper: u64) -> worker::Result<Vec<Scan>> {
    let dynamic_random_suffix: BTreeSet<ItemId> = sql
        .exec(SELECT_RANDOM_SUFFIX_ITEMS, None)?
        .to_array::<RandomSuffixRow>()?
        .into_iter()
        .filter_map(|row| ItemId::new(row.item_id))
        .collect();

    let rows = sql
        .exec(SELECT_TSM_SCANS, vec![integer(cutoff), integer(upper)])?
        .to_array::<TsmScanRow>()?;
    let mut scans = Vec::with_capacity(rows.len());
    for row in rows {
        let at = Timestamp::new(row.scanned_at)
            .ok_or_else(|| worker::Error::RustError("stored TSM scan time".to_owned()))?;
        let items = serde_json::from_str::<BTreeMap<ItemId, TsmRealmItem>>(&row.items)?;
        if let Some(scan) = project_tsm_scan(at, &items, &dynamic_random_suffix) {
            scans.push(scan);
        }
    }
    Ok(scans)
}

fn integer(value: u64) -> SqlStorageValue {
    // Timestamps and counts stay far below 2^53, the limit both SQLite bindings and JSON share.
    SqlStorageValue::Integer(i64::try_from(value).unwrap_or(i64::MAX))
}

#[cfg(test)]
mod tests {
    use super::{
        SCAN_WINDOW_SECONDS, equip_item_id, merge_scans, project_tsm_scan, retained, scan_id,
    };
    use crate::tsm::TsmRealmItem;
    use arbitrage_shared::{Copper, DbKey, ItemId, Scan, Timestamp};
    use std::collections::{BTreeMap, BTreeSet};

    const NOW: u64 = 1_700_000_000;

    fn scan(at: u64, values: &[(&str, u64)], buyouts: Option<&[(&str, u64)]>) -> Scan {
        let prices = |entries: &[(&str, u64)]| {
            entries
                .iter()
                .map(|&(key, value)| (DbKey::new(key), Copper::new(value).unwrap()))
                .collect::<BTreeMap<_, _>>()
        };
        Scan {
            at: Timestamp::new(at).unwrap(),
            values: prices(values),
            buyouts: buyouts.map(prices),
        }
    }

    #[test]
    fn the_same_scan_gets_the_same_id_whatever_its_buyouts() {
        let bare = scan(NOW, &[("2589", 10), ("4306", 20)], None);
        let priced = scan(NOW, &[("2589", 10), ("4306", 20)], Some(&[("2589", 9)]));

        assert_eq!(scan_id(&bare), scan_id(&priced));
        assert_eq!(scan_id(&bare).len(), 43);
    }

    #[test]
    fn a_different_time_or_value_gets_a_different_id() {
        let original = scan(NOW, &[("2589", 10)], None);

        assert_ne!(
            scan_id(&original),
            scan_id(&scan(NOW + 1, &[("2589", 10)], None))
        );
        assert_ne!(
            scan_id(&original),
            scan_id(&scan(NOW, &[("2589", 11)], None))
        );
        assert_ne!(
            scan_id(&original),
            scan_id(&scan(NOW, &[("2590", 10)], None))
        );
    }

    #[test]
    fn only_scans_inside_the_window_are_retained() {
        let cutoff = NOW - SCAN_WINDOW_SECONDS;

        assert!(retained(&scan(cutoff, &[], None), NOW));
        assert!(!retained(&scan(cutoff - 1, &[], None), NOW));
        assert!(retained(&scan(NOW + 300, &[], None), NOW));
        assert!(!retained(&scan(NOW + 301, &[], None), NOW));
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
            project_tsm_scan(Timestamp::new(NOW).unwrap(), &items, &dynamic),
            Some(scan(NOW, &[("2589", 14)], Some(&[("2589", 12)])))
        );
    }

    #[test]
    fn merges_tsm_scans_around_own_scans_and_keeps_only_the_latest_buyouts() {
        let hour = 3_600;
        let own = vec![scan(
            10 * hour + 900,
            &[("2589", 20), ("equip:9868:-18", 5_000)],
            Some(&[("2589", 18), ("equip:9868:-18", 5_000)]),
        )];
        let tsm = vec![
            scan(7 * hour + 100, &[("2589", 15)], Some(&[("2589", 14)])),
            scan(
                10 * hour + 200,
                &[("2589", 99), ("4306", 30)],
                Some(&[("2589", 99)]),
            ),
            scan(13 * hour + 300, &[("2589", 22)], Some(&[("2589", 19)])),
        ];

        assert_eq!(
            merge_scans(own, tsm),
            vec![
                scan(7 * hour + 100, &[("2589", 15)], None),
                scan(
                    10 * hour + 900,
                    &[("2589", 20), ("equip:9868:-18", 5_000)],
                    None
                ),
                scan(13 * hour + 300, &[("2589", 22)], Some(&[("2589", 19)])),
            ]
        );
    }
}
