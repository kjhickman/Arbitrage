use std::collections::BTreeMap;

use arbitrage_shared::{Copper, ItemId, Timestamp};
use serde::{Deserialize, Serialize};
use worker::{
    DurableObject, Env, Method, Request, Response, SqlStorageValue, State, durable_object,
};

pub const REGION_DATABASES: &str = "REGION_DATABASES";

const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS tsm_region_scans (
    scanned_at INTEGER PRIMARY KEY,
    item_count INTEGER NOT NULL,
    items TEXT NOT NULL
)";
const INSERT_TSM_REGION_SCAN: &str =
    "INSERT OR IGNORE INTO tsm_region_scans (scanned_at, item_count, items) VALUES (?, ?, ?)";

/// Compact `(market_value, historical, avg_sale_price, sale_rate, sold_per_day)` tuple per item.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct TsmRegionItem(pub Copper, pub Copper, pub Copper, pub f64, pub f64);

impl TsmRegionItem {
    #[must_use]
    pub const fn new(
        market_value: Copper,
        historical: Copper,
        avg_sale_price: Copper,
        sale_rate: f64,
        sold_per_day: f64,
    ) -> Self {
        Self(
            market_value,
            historical,
            avg_sale_price,
            sale_rate,
            sold_per_day,
        )
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TsmRegionSnapshot {
    pub scanned_at: Timestamp,
    pub items: BTreeMap<ItemId, TsmRegionItem>,
}

#[durable_object]
pub struct RegionDatabase {
    state: State,
}

impl DurableObject for RegionDatabase {
    fn new(state: State, _env: Env) -> Self {
        Self { state }
    }

    async fn fetch(&self, mut req: Request) -> worker::Result<Response> {
        let path = req.url()?.path().to_owned();
        if req.method() != Method::Post || path != "/internal/tsm" {
            return Response::error("Not Found", 404);
        }

        let text = req.text().await?;
        let Ok(snapshot) = serde_json::from_str::<TsmRegionSnapshot>(&text) else {
            return Response::error("Bad Request", 400);
        };

        let sql = self.state.storage().sql();
        sql.exec(SCHEMA, None)?;
        sql.exec(
            INSERT_TSM_REGION_SCAN,
            vec![
                integer(snapshot.scanned_at.get()),
                integer(snapshot.items.len() as u64),
                serde_json::to_string(&snapshot.items)?.into(),
            ],
        )?;
        Response::ok("ok")
    }
}

fn integer(value: u64) -> SqlStorageValue {
    SqlStorageValue::Integer(i64::try_from(value).unwrap_or(i64::MAX))
}
