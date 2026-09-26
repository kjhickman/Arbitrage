use std::collections::BTreeMap;

use crate::{
    database::{Copper, Database, DbKey, Market, Realm, Timestamp},
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

/// Rebuilds the addon's item-by-item layout from per-scan entries.
///
/// A realm name already held by another region keeps the region it was first seen with.
#[must_use]
pub fn to_database(payload: &SyncPayload) -> Database {
    let mut database = Database::default();

    for entry in &payload.markets {
        let Some(realm) = realm_in(&mut database, entry.region, &entry.realm) else {
            continue;
        };
        add_scans(realm.markets.entry(entry.market).or_default(), &entry.scans);
    }

    for entry in &payload.vendor_prices {
        let Some(realm) = realm_in(&mut database, entry.region, &entry.realm) else {
            continue;
        };
        realm
            .vendor_prices
            .insert(entry.faction.clone(), entry.prices.clone());
    }

    database
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

fn add_scans(market: &mut Market, scans: &[Scan]) {
    for scan in scans {
        for (key, &value) in &scan.values {
            market
                .items
                .entry(key.clone())
                .or_default()
                .scans
                .insert(scan.at, value);
        }
    }

    // The buyout map is one snapshot, so the newest scan that carries one brings it whole.
    let priced = scans
        .iter()
        .filter_map(|scan| scan.buyouts.as_ref().map(|buyouts| (scan.at, buyouts)))
        .max_by_key(|&(at, _)| at);
    let (last_scan, buyouts) = match priced {
        Some((at, buyouts)) => (Some(at), buyouts.clone()),
        None => (scans.iter().map(|scan| scan.at).max(), BTreeMap::new()),
    };
    if last_scan > market.last_scan {
        market.last_scan = last_scan;
        market.latest_buyouts = buyouts;
    }
}

fn realm_in<'a>(database: &'a mut Database, region: u32, name: &str) -> Option<&'a mut Realm> {
    let realm = database
        .realms
        .entry(name.to_owned())
        .or_insert_with(|| Realm {
            region,
            ..Realm::default()
        });
    (realm.region == region).then_some(realm)
}

#[cfg(test)]
mod tests {
    use super::{to_database, to_payload};
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

    #[test]
    fn scans_pivot_back_into_the_same_items() {
        let own = own_database();
        let rebuilt = to_database(&to_payload(&own));
        let whitemane = &rebuilt.realms["Whitemane"];

        assert_eq!(rebuilt.last_replicate_scan, None);
        assert_eq!(whitemane.region, 1);
        assert_eq!(
            whitemane.markets[&Faction::Alliance],
            Market {
                last_played: None,
                ..own.realms["Whitemane"].markets[&Faction::Alliance].clone()
            }
        );
        assert_eq!(whitemane.markets[&Faction::Neutral], Market::default());
        assert_eq!(
            whitemane.vendor_prices,
            BTreeMap::from([(
                "Alliance".to_owned(),
                BTreeMap::from([(ItemId::new(2589).unwrap(), copper(5))]),
            )])
        );
    }

    #[test]
    fn the_newest_scan_with_buyouts_sets_the_latest_snapshot() {
        let payload = SyncPayload {
            markets: vec![market_scans(
                "Whitemane",
                Faction::Alliance,
                vec![
                    scan(100, &[("2589", 40)], Some(&[("2589", 35)])),
                    scan(300, &[("2589", 42)], None),
                    scan(200, &[("2589", 41)], Some(&[("2589", 38), ("4306", 1)])),
                ],
            )],
            vendor_prices: vec![],
        };

        let market = &to_database(&payload).realms["Whitemane"].markets[&Faction::Alliance];
        assert_eq!(market.last_scan, Some(at(200)));
        assert_eq!(market.latest_buyouts, prices(&[("2589", 38), ("4306", 1)]));
    }

    #[test]
    fn without_any_buyouts_the_newest_scan_is_the_last_scan() {
        let payload = SyncPayload {
            markets: vec![market_scans(
                "Whitemane",
                Faction::Alliance,
                vec![scan(100, &[("2589", 40)], None), scan(300, &[], None)],
            )],
            vendor_prices: vec![],
        };

        let market = &to_database(&payload).realms["Whitemane"].markets[&Faction::Alliance];
        assert_eq!(market.last_scan, Some(at(300)));
        assert!(market.latest_buyouts.is_empty());
    }

    #[test]
    fn a_realm_name_from_a_second_region_is_dropped() {
        let payload = SyncPayload {
            markets: vec![
                market_scans(
                    "Whitemane",
                    Faction::Alliance,
                    vec![scan(100, &[("1", 1)], None)],
                ),
                MarketScans {
                    region: 3,
                    ..market_scans(
                        "Whitemane",
                        Faction::Horde,
                        vec![scan(100, &[("2", 2)], None)],
                    )
                },
            ],
            vendor_prices: vec![VendorPrices {
                region: 3,
                realm: "Whitemane".to_owned(),
                faction: "Horde".to_owned(),
                prices: BTreeMap::from([(ItemId::new(1).unwrap(), copper(1))]),
            }],
        };

        let whitemane = &to_database(&payload).realms["Whitemane"];
        assert_eq!(whitemane.region, 1);
        assert_eq!(
            whitemane.markets.keys().collect::<Vec<_>>(),
            vec![&Faction::Alliance]
        );
        assert!(whitemane.vendor_prices.is_empty());
    }
}
