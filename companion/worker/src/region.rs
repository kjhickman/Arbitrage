use std::{collections::BTreeMap, fmt};

use arbitrage_shared::{Copper, Count, ItemId, RegionSales, Sale, Timestamp};
use serde::{
    Deserialize, Deserializer, Serialize,
    de::{self, IgnoredAny, SeqAccess, Visitor},
};
use worker::{
    Date, DurableObject, Env, Method, Request, Response, SqlStorage, SqlStorageValue, State,
    durable_object,
};

use crate::market::SCAN_WINDOW_SECONDS;
use crate::tsm;

pub const REGION_DATABASES: &str = "REGION_DATABASES";

const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS tsm_region_scans (
    scanned_at INTEGER PRIMARY KEY,
    item_count INTEGER NOT NULL,
    items TEXT NOT NULL
)";
const PRUNE_TSM_REGION_SCANS: &str = "DELETE FROM tsm_region_scans WHERE scanned_at < ?";
const INSERT_TSM_REGION_SCAN: &str =
    "INSERT OR IGNORE INTO tsm_region_scans (scanned_at, item_count, items) VALUES (?, ?, ?)";
const SELECT_NEWEST_TSM_REGION_SCAN: &str =
    "SELECT scanned_at, items FROM tsm_region_scans ORDER BY scanned_at DESC LIMIT 1";

/// Compact `(market_value, historical, avg_sale_price, sale_rate)` tuple per item. Snapshots stored
/// by 0.8.5 carry units sold a day as a fifth number, which reading skips.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct TsmRegionItem(pub Copper, pub Copper, pub Copper, pub f64);

impl<'de> Deserialize<'de> for TsmRegionItem {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ItemVisitor;

        impl<'de> Visitor<'de> for ItemVisitor {
            type Value = TsmRegionItem;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("at least four numbers")
            }

            fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
                let market_value = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::invalid_length(0, &self))?;
                let historical = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::invalid_length(1, &self))?;
                let avg_sale_price = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::invalid_length(2, &self))?;
                let sale_rate = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::invalid_length(3, &self))?;
                while seq.next_element::<IgnoredAny>()?.is_some() {}
                Ok(TsmRegionItem(
                    market_value,
                    historical,
                    avg_sale_price,
                    sale_rate,
                ))
            }
        }

        deserializer.deserialize_seq(ItemVisitor)
    }
}

impl TsmRegionItem {
    #[must_use]
    pub const fn new(
        market_value: Copper,
        historical: Copper,
        avg_sale_price: Copper,
        sale_rate: f64,
    ) -> Self {
        Self(market_value, historical, avg_sale_price, sale_rate)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TsmRegionSnapshot {
    pub scanned_at: Timestamp,
    pub items: BTreeMap<ItemId, TsmRegionItem>,
}

/// Asks one region for its newest sales, unless the companion already holds that snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SalesRequest {
    pub region: u32,
    pub have_at: Option<Timestamp>,
}

/// A rate as the thousandths TSM publishes it to, or `None` past what Lua holds exactly.
fn thousandths(rate: f64) -> Option<Count> {
    let scaled = (rate * 1_000.0).round();
    if !(0.0..=9_007_199_254_740_992.0).contains(&scaled) {
        return None;
    }
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "checked to be a non-negative whole number within 2^53"
    )]
    Count::new(scaled as u64)
}

/// Keeps each item's sales from a snapshot, leaving out items nothing is known to sell and gear that
/// rolls random suffixes, whose figures blend every suffix.
#[must_use]
pub fn sales_of(
    region: u32,
    at: Timestamp,
    items: &BTreeMap<ItemId, TsmRegionItem>,
) -> RegionSales {
    RegionSales {
        region,
        at,
        items: items
            .iter()
            .filter(|&(&id, _)| !tsm::is_random_suffix(id))
            .filter_map(|(&id, item)| {
                let sale = Sale(item.2, thousandths(item.3)?);
                let known =
                    sale.average_price().get() > 0 || sale.sale_rate_thousandths().get() > 0;
                known.then_some((id, sale))
            })
            .collect(),
    }
}

#[derive(Deserialize)]
struct NewestRow {
    scanned_at: u64,
    items: String,
}

fn newest_sales(sql: &SqlStorage, request: SalesRequest) -> worker::Result<Option<RegionSales>> {
    let Some(row) = sql
        .exec(SELECT_NEWEST_TSM_REGION_SCAN, None)?
        .to_array::<NewestRow>()?
        .into_iter()
        .next()
    else {
        return Ok(None);
    };
    let Some(at) = Timestamp::new(row.scanned_at) else {
        return Ok(None);
    };
    if request.have_at == Some(at) {
        return Ok(None);
    }
    let items = serde_json::from_str::<BTreeMap<ItemId, TsmRegionItem>>(&row.items)?;
    Ok(Some(sales_of(request.region, at, &items)))
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
        if req.method() != Method::Post {
            return Response::error("Not Found", 404);
        }
        let path = req.url()?.path().to_owned();
        let text = req.text().await?;
        let sql = self.state.storage().sql();
        sql.exec(SCHEMA, None)?;

        match path.as_str() {
            "/internal/tsm" => {
                let Ok(snapshot) = serde_json::from_str::<TsmRegionSnapshot>(&text) else {
                    return Response::error("Bad Request", 400);
                };
                let cutoff = (Date::now().as_millis() / 1_000).saturating_sub(SCAN_WINDOW_SECONDS);
                sql.exec(PRUNE_TSM_REGION_SCANS, vec![integer(cutoff)])?;
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
            "/internal/sales" => {
                let Ok(request) = serde_json::from_str::<SalesRequest>(&text) else {
                    return Response::error("Bad Request", 400);
                };
                Response::from_json(&newest_sales(&sql, request)?)
            }
            _ => Response::error("Not Found", 404),
        }
    }
}

fn integer(value: u64) -> SqlStorageValue {
    SqlStorageValue::Integer(i64::try_from(value).unwrap_or(i64::MAX))
}

#[cfg(test)]
mod tests {
    use super::{TsmRegionItem, sales_of, thousandths};
    use arbitrage_shared::{Copper, Count, ItemId, Sale, Timestamp};
    use std::collections::BTreeMap;

    fn item(average: u64, rate: f64) -> TsmRegionItem {
        TsmRegionItem::new(
            Copper::new(53).unwrap(),
            Copper::new(49).unwrap(),
            Copper::new(average).unwrap(),
            rate,
        )
    }

    #[test]
    fn items_stored_before_sold_per_day_was_dropped_still_read() {
        // 0.8.5 stored units sold a day as a fifth number.
        assert_eq!(
            serde_json::from_str::<TsmRegionItem>("[53,49,40,0.887,1554.024]").unwrap(),
            item(40, 0.887)
        );
        let stored = serde_json::to_string(&item(40, 0.887)).unwrap();
        assert_eq!(stored, "[53,49,40,0.887]");
        assert_eq!(
            serde_json::from_str::<TsmRegionItem>(&stored).unwrap(),
            item(40, 0.887)
        );
        assert!(serde_json::from_str::<TsmRegionItem>("[53,49,40]").is_err());
    }

    #[test]
    fn rates_keep_the_thousandths_tsm_publishes() {
        assert_eq!(thousandths(0.887), Count::new(887));
        assert_eq!(thousandths(1_554.024), Count::new(1_554_024));
        assert_eq!(thousandths(0.02), Count::new(20));
        assert_eq!(thousandths(0.0), Count::new(0));
        assert_eq!(thousandths(1e300), None);
    }

    #[test]
    fn sales_leave_out_items_nothing_is_known_to_sell_and_random_suffix_gear() {
        let at = Timestamp::new(1_794_473_469).unwrap();
        let items = BTreeMap::from([
            (ItemId::new(785).unwrap(), item(40, 0.887)),
            (ItemId::new(876).unwrap(), item(1_045, 0.0)),
            (ItemId::new(900).unwrap(), item(0, 0.0)),
            // Ribsplitter
            (ItemId::new(12_527).unwrap(), item(52_000, 0.2)),
        ]);

        let sales = sales_of(1, at, &items);

        assert_eq!(sales.region, 1);
        assert_eq!(sales.at, at);
        assert_eq!(
            sales.items,
            BTreeMap::from([
                (
                    ItemId::new(785).unwrap(),
                    Sale(Copper::new(40).unwrap(), Count::new(887).unwrap())
                ),
                (
                    ItemId::new(876).unwrap(),
                    Sale(Copper::new(1_045).unwrap(), Count::new(0).unwrap())
                ),
            ])
        );
    }
}
