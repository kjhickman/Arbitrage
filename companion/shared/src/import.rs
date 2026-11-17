use std::collections::{BTreeMap, BTreeSet};

use crate::{
    database::{Copper, DbKey, Faction, ItemId, Timestamp},
    payload::{Scan, SyncPayload},
};

const DAY: u64 = 86_400;
/// The addon's market value window. Older days only move an item's `latest`.
const WINDOW_DAYS: u64 = 14;
/// The addon holds a day as one number, `total * SCANS_PER_DAY + count`. The worker keeps at most
/// one scan an hour, and 24 scans at the gold cap stay far below the 2^53 that Lua holds exactly.
const SCANS_PER_DAY: u64 = 1024;

/// The combined database the addon reads at login, with each item's scans added up per UTC day.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Import {
    pub realms: BTreeMap<String, ImportRealm>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportRealm {
    /// The number `GetCurrentRegion()` returns, since realm names repeat across regions.
    pub region: u32,
    pub markets: BTreeMap<Faction, ImportMarket>,
    pub vendor_prices: BTreeMap<String, BTreeMap<ItemId, Copper>>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportMarket {
    pub last_scan: Option<Timestamp>,
    pub latest_buyouts: BTreeMap<DbKey, Copper>,
    /// Every scan the totals hold, so the addon adds only its own scans that are missing.
    pub scans: BTreeSet<Timestamp>,
    pub items: BTreeMap<DbKey, ImportItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportItem {
    /// The item's newest scan, which the addon shows as Last Seen.
    pub latest: Timestamp,
    /// Each day's scans by day number, `at / 86400`, packed as `total * 1024 + count`, from
    /// fourteen days before the market's newest scan.
    pub days: BTreeMap<u64, u64>,
}

impl Import {
    /// Adds up the worker's combined scans by day.
    ///
    /// A realm name already held by another region keeps the region it was first seen with.
    #[must_use]
    pub fn from_payload(payload: &SyncPayload) -> Self {
        let mut import = Self::default();

        for entry in &payload.markets {
            if let Some(realm) = import.realm_in(entry.region, &entry.realm) {
                realm
                    .markets
                    .entry(entry.market)
                    .or_default()
                    .add_scans(&entry.scans);
            }
        }

        for entry in &payload.vendor_prices {
            if let Some(realm) = import.realm_in(entry.region, &entry.realm) {
                realm
                    .vendor_prices
                    .insert(entry.faction.clone(), entry.prices.clone());
            }
        }

        import
    }

    fn realm_in(&mut self, region: u32, name: &str) -> Option<&mut ImportRealm> {
        let realm = self
            .realms
            .entry(name.to_owned())
            .or_insert_with(|| ImportRealm {
                region,
                ..ImportRealm::default()
            });
        (realm.region == region).then_some(realm)
    }
}

impl ImportMarket {
    fn add_scans(&mut self, scans: &[Scan]) {
        // The buyout map is one snapshot, so the newest scan that carries one brings it whole.
        let priced = scans
            .iter()
            .filter_map(|scan| scan.buyouts.as_ref().map(|buyouts| (scan.at, buyouts)))
            .max_by_key(|&(at, _)| at);
        let (last_scan, buyouts) = match priced {
            Some((at, buyouts)) => (Some(at), buyouts.clone()),
            None => (scans.iter().map(|scan| scan.at).max(), BTreeMap::new()),
        };
        if last_scan > self.last_scan {
            self.last_scan = last_scan;
            self.latest_buyouts = buyouts;
        }

        let first_day = scans
            .iter()
            .map(|scan| scan.at.get() / DAY)
            .max()
            .unwrap_or_default()
            .saturating_sub(WINDOW_DAYS);

        for scan in scans {
            self.scans.insert(scan.at);
            let day = scan.at.get() / DAY;
            for (key, copper) in scan.values.iter().filter(|(_, copper)| copper.get() > 0) {
                let item = self.items.entry(key.clone()).or_insert_with(|| ImportItem {
                    latest: scan.at,
                    days: BTreeMap::new(),
                });
                item.latest = item.latest.max(scan.at);
                if day >= first_day {
                    *item.days.entry(day).or_default() += copper.get() * SCANS_PER_DAY + 1;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{DAY, Import, ImportItem, SCANS_PER_DAY};
    use crate::{
        database::{Copper, DbKey, Faction, ItemId, Timestamp},
        payload::{MarketScans, Scan, SyncPayload, VendorPrices},
    };
    use std::collections::{BTreeMap, BTreeSet};

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

    fn import_of(scans: Vec<Scan>) -> Import {
        Import::from_payload(&SyncPayload {
            markets: vec![market_scans("Whitemane", Faction::Alliance, scans)],
            vendor_prices: vec![],
        })
    }

    fn day(total: u64, count: u64) -> u64 {
        total * SCANS_PER_DAY + count
    }

    #[test]
    fn scans_add_up_by_day_within_the_window_before_the_newest_scan() {
        let newest = 40 * DAY + 3_600;
        let import = import_of(vec![
            scan(25 * DAY + 60, &[("2589", 7), ("4306", 50)], None),
            scan(26 * DAY + 60, &[("2589", 10)], None),
            scan(40 * DAY + 60, &[("2589", 30), ("4306", 0)], None),
            scan(newest, &[("2589", 12)], Some(&[("2589", 9)])),
        ]);
        let market = &import.realms["Whitemane"].markets[&Faction::Alliance];

        assert_eq!(market.last_scan, Some(at(newest)));
        assert_eq!(market.latest_buyouts, prices(&[("2589", 9)]));
        assert_eq!(
            market.scans,
            BTreeSet::from([
                at(25 * DAY + 60),
                at(26 * DAY + 60),
                at(40 * DAY + 60),
                at(newest)
            ])
        );
        assert_eq!(
            market.items,
            BTreeMap::from([
                (
                    DbKey::new("2589"),
                    ImportItem {
                        latest: at(newest),
                        days: BTreeMap::from([(26, day(10, 1)), (40, day(42, 2))]),
                    },
                ),
                (
                    DbKey::new("4306"),
                    ImportItem {
                        latest: at(25 * DAY + 60),
                        days: BTreeMap::new(),
                    },
                ),
            ])
        );
    }

    #[test]
    fn the_newest_scan_with_buyouts_sets_the_latest_snapshot() {
        let import = import_of(vec![
            scan(100, &[("2589", 40)], Some(&[("2589", 35)])),
            scan(300, &[("2589", 42)], None),
            scan(200, &[("2589", 41)], Some(&[("2589", 38), ("4306", 1)])),
        ]);
        let market = &import.realms["Whitemane"].markets[&Faction::Alliance];

        assert_eq!(market.last_scan, Some(at(200)));
        assert_eq!(market.latest_buyouts, prices(&[("2589", 38), ("4306", 1)]));
    }

    #[test]
    fn without_any_buyouts_the_newest_scan_is_the_last_scan() {
        let import = import_of(vec![scan(100, &[("2589", 40)], None), scan(300, &[], None)]);
        let market = &import.realms["Whitemane"].markets[&Faction::Alliance];

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
            vendor_prices: vec![
                VendorPrices {
                    region: 1,
                    realm: "Whitemane".to_owned(),
                    faction: "Alliance".to_owned(),
                    prices: BTreeMap::from([(ItemId::new(2589).unwrap(), copper(5))]),
                },
                VendorPrices {
                    region: 3,
                    realm: "Whitemane".to_owned(),
                    faction: "Horde".to_owned(),
                    prices: BTreeMap::from([(ItemId::new(1).unwrap(), copper(1))]),
                },
            ],
        };

        let whitemane = &Import::from_payload(&payload).realms["Whitemane"];
        assert_eq!(whitemane.region, 1);
        assert_eq!(
            whitemane.markets.keys().collect::<Vec<_>>(),
            vec![&Faction::Alliance]
        );
        assert_eq!(
            whitemane.vendor_prices,
            BTreeMap::from([(
                "Alliance".to_owned(),
                BTreeMap::from([(ItemId::new(2589).unwrap(), copper(5))]),
            )])
        );
    }
}
