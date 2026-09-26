use std::collections::BTreeMap;

use arbitrage_shared::{Copper, DbKey, Scan, Timestamp};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use worker::{
    DurableObject, Env, Request, Response, SqlStorage, SqlStorageValue, State, durable_object,
};

use crate::auth::types::digest_sha256;

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
)";
const PRUNE_SCANS: &str = "DELETE FROM scans WHERE scanned_at < ?";
const INSERT_SCAN: &str = "INSERT INTO scans (id, scanned_at, item_count, market_values, buyouts)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT (id) DO UPDATE SET buyouts = COALESCE(scans.buyouts, excluded.buyouts)";
const INSERT_UPLOADER: &str =
    "INSERT OR IGNORE INTO scan_uploaders (scan_id, account) VALUES (?, ?)";
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

#[durable_object]
pub struct MarketDatabase {
    state: State,
}

impl DurableObject for MarketDatabase {
    fn new(state: State, _env: Env) -> Self {
        Self { state }
    }

    async fn fetch(&self, mut req: Request) -> worker::Result<Response> {
        let path = req.url()?.path().to_owned();
        if req.method() != worker::Method::Post || path != "/internal/sync" {
            return Response::error("Not Found", 404);
        }
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
            combined(&sql, &sync, cutoff)?
        } else {
            Vec::new()
        };
        Response::from_json(&scans)
    }
}

fn store(sql: &SqlStorage, account: &str, scan: &Scan) -> worker::Result<()> {
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

fn combined(sql: &SqlStorage, sync: &MarketSync, cutoff: u64) -> worker::Result<Vec<Scan>> {
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

fn integer(value: u64) -> SqlStorageValue {
    // Timestamps and counts stay far below 2^53, the limit both SQLite bindings and JSON share.
    SqlStorageValue::Integer(i64::try_from(value).unwrap_or(i64::MAX))
}

#[cfg(test)]
mod tests {
    use super::{SCAN_WINDOW_SECONDS, retained, scan_id};
    use arbitrage_shared::{Copper, DbKey, Scan, Timestamp};
    use std::collections::BTreeMap;

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
}
