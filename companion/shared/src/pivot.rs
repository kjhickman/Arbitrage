use std::collections::BTreeMap;

use crate::{
    database::{Copper, Database, DbKey, Market, Timestamp},
    payload::{MarketScans, Scan, SyncPayload, VendorPrices},
};

/// Regroups the addon's item-by-item history into one entry per scan.
///
/// Every market is listed, including ones without scans, so the worker sees each `lastPlayed`.
#[must_use]
pub fn to_payload(database: &Database) -> SyncPayload {
    let mut payload = SyncPayload::default();

    for (name, realm) in &database.realms {
        for (&market, history) in &realm.markets {
            payload.markets.push(MarketScans {
                region: realm.region,
                realm: name.clone(),
                market,
                last_played: history.last_played,
                scans: scans_of(history),
            });
        }

        for (faction, prices) in &realm.vendor_prices {
            if !prices.is_empty() {
                payload.vendor_prices.push(VendorPrices {
                    region: realm.region,
                    realm: name.clone(),
                    faction: faction.clone(),
                    prices: prices.clone(),
                });
            }
        }
    }

    payload
}

fn scans_of(market: &Market) -> Vec<Scan> {
    let mut by_time: BTreeMap<Timestamp, BTreeMap<DbKey, Copper>> = BTreeMap::new();
    for (key, history) in &market.items {
        for (&at, &value) in &history.scans {
            by_time.entry(at).or_default().insert(key.clone(), value);
        }
    }

    by_time
        .into_iter()
        .map(|(at, values)| Scan {
            at,
            values,
            buyouts: (Some(at) == market.last_scan && !market.latest_buyouts.is_empty())
                .then(|| market.latest_buyouts.clone()),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::to_payload;
    use crate::{
        database::{
            Copper, Database, DbKey, Faction, ItemHistory, ItemId, Market, Realm, Timestamp,
        },
        payload::{MarketScans, Scan, SyncPayload, VendorPrices},
    };
    use std::collections::BTreeMap;

    fn at(seconds: u64) -> Timestamp {
        Timestamp::new(seconds).expect("the timestamp should be in range")
    }

    fn copper(value: u64) -> Copper {
        Copper::new(value).expect("the price should be in range")
    }

    fn prices(entries: &[(&str, u64)]) -> BTreeMap<DbKey, Copper> {
        entries
            .iter()
            .map(|&(key, value)| (DbKey::new(key), copper(value)))
            .collect()
    }

    fn history(scans: &[(u64, u64)]) -> ItemHistory {
        ItemHistory {
            scans: scans
                .iter()
                .map(|&(when, value)| (at(when), copper(value)))
                .collect(),
        }
    }

    fn scan(when: u64, values: &[(&str, u64)], buyouts: Option<&[(&str, u64)]>) -> Scan {
        Scan {
            at: at(when),
            values: prices(values),
            buyouts: buyouts.map(prices),
        }
    }

    fn market_scans(realm: &str, market: Faction, scans: Vec<Scan>) -> MarketScans {
        MarketScans {
            region: 1,
            realm: realm.to_owned(),
            market,
            last_played: None,
            scans,
        }
    }

    fn own_database() -> Database {
        let alliance = Market {
            items: BTreeMap::from([
                (DbKey::new("2589"), history(&[(100, 10), (200, 12)])),
                (DbKey::new("4306"), history(&[(200, 30)])),
            ]),
            last_scan: Some(at(200)),
            last_played: Some(at(150)),
            latest_buyouts: prices(&[("2589", 9)]),
        };

        Database {
            last_replicate_scan: Some(at(190)),
            realms: BTreeMap::from([(
                "Whitemane".to_owned(),
                Realm {
                    region: 1,
                    markets: BTreeMap::from([
                        (Faction::Alliance, alliance),
                        (Faction::Neutral, Market::default()),
                    ]),
                    vendor_prices: BTreeMap::from([
                        (
                            "Alliance".to_owned(),
                            BTreeMap::from([(ItemId::new(2589).unwrap(), copper(5))]),
                        ),
                        ("Horde".to_owned(), BTreeMap::new()),
                    ]),
                },
            )]),
        }
    }

    #[test]
    fn items_regroup_into_one_scan_per_timestamp_with_buyouts_on_the_last() {
        let payload = to_payload(&own_database());

        assert_eq!(
            payload,
            SyncPayload {
                markets: vec![
                    MarketScans {
                        last_played: Some(at(150)),
                        ..market_scans(
                            "Whitemane",
                            Faction::Alliance,
                            vec![
                                scan(100, &[("2589", 10)], None),
                                scan(200, &[("2589", 12), ("4306", 30)], Some(&[("2589", 9)])),
                            ],
                        )
                    },
                    market_scans("Whitemane", Faction::Neutral, vec![]),
                ],
                vendor_prices: vec![VendorPrices {
                    region: 1,
                    realm: "Whitemane".to_owned(),
                    faction: "Alliance".to_owned(),
                    prices: BTreeMap::from([(ItemId::new(2589).unwrap(), copper(5))]),
                }],
            }
        );
    }
}
