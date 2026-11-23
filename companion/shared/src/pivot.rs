use std::collections::BTreeMap;

use crate::{
    database::{Copper, Database, DbKey, Timestamp},
    payload::{MarketScans, Scan, VendorPrices},
};

/// The account's own `SavedVariables` regrouped into per-market scans and vendor prices.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LocalDatabase {
    pub markets: Vec<MarketScans>,
    pub vendor_prices: Vec<VendorPrices>,
}

/// Lists every market's scans and every location's vendor prices.
///
/// Every market is listed, including ones without scans, so the worker sees each `lastPlayed`.
#[must_use]
pub fn to_local(database: Database) -> LocalDatabase {
    let mut local = LocalDatabase::default();

    for (name, realm) in database.realms {
        for (market, history) in realm.markets {
            local.markets.push(MarketScans {
                region: realm.region,
                realm: name.clone(),
                market,
                last_played: history.last_played,
                scans: history.scans,
            });
        }

        for (faction, prices) in realm.vendor_prices {
            if !prices.is_empty() {
                local.vendor_prices.push(VendorPrices {
                    region: realm.region,
                    realm: name.clone(),
                    faction,
                    prices,
                });
            }
        }
    }

    local
}

/// Regroups a version 2 market's item-by-item market values into one full scan per time, with
/// its latest buyouts on its last scan.
#[must_use]
pub fn scans_from_items(
    items: BTreeMap<DbKey, BTreeMap<Timestamp, Copper>>,
    last_scan: Option<Timestamp>,
    latest_buyouts: BTreeMap<DbKey, Copper>,
) -> Vec<Scan> {
    let mut by_time: BTreeMap<Timestamp, Scan> = BTreeMap::new();
    for (key, scans) in items {
        for (at, value) in scans {
            by_time
                .entry(at)
                .or_insert_with(|| Scan {
                    at,
                    ..Scan::default()
                })
                .market_values
                .insert(key.clone(), value);
        }
    }

    if let Some(at) = last_scan
        && !latest_buyouts.is_empty()
    {
        by_time
            .entry(at)
            .or_insert_with(|| Scan {
                at,
                ..Scan::default()
            })
            .buyouts = Some(latest_buyouts);
    }

    by_time.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::{LocalDatabase, scans_from_items, to_local};
    use crate::{
        database::{Copper, Database, DbKey, Faction, ItemId, Market, Realm, Timestamp},
        payload::{MarketScans, Scan, ScanKind, VendorPrices},
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

    fn scan(when: u64, values: &[(&str, u64)], buyouts: Option<&[(&str, u64)]>) -> Scan {
        Scan {
            at: at(when),
            market_values: prices(values),
            buyouts: buyouts.map(prices),
            ..Scan::default()
        }
    }

    #[test]
    fn version_2_items_regroup_into_one_scan_per_time_with_buyouts_on_the_last() {
        let items = BTreeMap::from([
            (
                DbKey::new("2589"),
                BTreeMap::from([(at(100), copper(10)), (at(200), copper(12))]),
            ),
            (DbKey::new("4306"), BTreeMap::from([(at(200), copper(30))])),
        ]);

        assert_eq!(
            scans_from_items(items, Some(at(200)), prices(&[("2589", 9)])),
            vec![
                scan(100, &[("2589", 10)], None),
                scan(200, &[("2589", 12), ("4306", 30)], Some(&[("2589", 9)])),
            ]
        );
    }

    #[test]
    fn buyouts_without_market_values_still_make_a_scan() {
        assert_eq!(
            scans_from_items(BTreeMap::new(), Some(at(300)), prices(&[("2589", 9)])),
            vec![scan(300, &[], Some(&[("2589", 9)]))]
        );
        assert_eq!(
            scans_from_items(BTreeMap::new(), Some(at(300)), BTreeMap::new()),
            vec![]
        );
    }

    #[test]
    fn every_market_and_location_with_vendor_prices_is_listed() {
        let quick = Scan {
            at: at(250),
            kind: ScanKind::Quick,
            buyouts: Some(prices(&[("2589", 8)])),
            ..Scan::default()
        };
        let database = Database {
            last_replicate_scan: Some(at(190)),
            realms: BTreeMap::from([(
                "Whitemane".to_owned(),
                Realm {
                    region: 1,
                    markets: BTreeMap::from([
                        (
                            Faction::Alliance,
                            Market {
                                last_played: Some(at(150)),
                                scans: vec![scan(200, &[("2589", 12)], None), quick.clone()],
                            },
                        ),
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
        };

        assert_eq!(
            to_local(database),
            LocalDatabase {
                markets: vec![
                    MarketScans {
                        region: 1,
                        realm: "Whitemane".to_owned(),
                        market: Faction::Alliance,
                        last_played: Some(at(150)),
                        scans: vec![scan(200, &[("2589", 12)], None), quick],
                    },
                    MarketScans {
                        region: 1,
                        realm: "Whitemane".to_owned(),
                        market: Faction::Neutral,
                        last_played: None,
                        scans: vec![],
                    },
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
