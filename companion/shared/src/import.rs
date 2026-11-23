use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::{
    database::{Copper, Count, DbKey, Faction, ItemId, Timestamp},
    payload::{CachedScan, RegionSales, ScanKind, VendorPrices},
};

const DAY: u64 = 86_400;
/// The addon's market value window. Older days only move an item's `latest`.
const WINDOW_DAYS: u64 = 14;
/// The addon holds each of a day's values as one number, `total * SCANS_PER_DAY + count`. The
/// worker keeps at most one scan of each kind an hour, and 48 scans at the gold cap stay far below
/// the 2^53 that Lua holds exactly.
const SCANS_PER_DAY: u64 = 1024;

/// The combined database the addon reads at login, with each item's scans added up per UTC day.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Import {
    pub realms: BTreeMap<String, ImportRealm>,
    /// Region-wide sales by the number `GetCurrentRegion()` returns.
    pub regions: BTreeMap<u32, RegionSales>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportRealm {
    /// The number `GetCurrentRegion()` returns, since realm names repeat across regions.
    pub region: u32,
    pub markets: BTreeMap<Faction, ImportMarket>,
    pub vendor_prices: BTreeMap<String, BTreeMap<ItemId, Copper>>,
}

/// The buyouts one scan saw for some kind of item, and when it ran. The addon treats an item of
/// that kind missing from the list as not listed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BuyoutList {
    pub at: Timestamp,
    pub prices: BTreeMap<DbKey, Copper>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportMarket {
    /// The newest full scan or TSM snapshot.
    pub last_scan: Option<Timestamp>,
    /// Buyouts by item ID, from the newest scan with buyouts.
    pub item_buyouts: Option<BuyoutList>,
    /// Random-enchant gear, from the newest full scan that saw it. When that's an older scan than
    /// the item list's, it also holds the gear's item IDs, which the newer scan couldn't see.
    pub variant_buyouts: Option<BuyoutList>,
    /// Every full scan and TSM snapshot the totals hold, so the addon adds only its
    /// own scans that are missing.
    pub scans: BTreeSet<Timestamp>,
    /// Every quick scan the totals hold.
    pub quick_scans: BTreeSet<Timestamp>,
    pub items: BTreeMap<DbKey, ImportItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportItem {
    /// The newest scan that saw the item, which the addon shows as Last Seen.
    pub latest: Timestamp,
    /// Each day's scans by day number, `at / 86400`, from fourteen days before the market's newest
    /// scan.
    pub days: BTreeMap<u64, DayTotals>,
}

/// One day's scans of an item, each value packed as `total * 1024 + count`, or 0 when no scan
/// that day recorded it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DayTotals {
    pub market_value: u64,
    pub buyout: u64,
    pub quantity: u64,
}

impl DayTotals {
    /// The values in the order the addon lists them after the day number.
    #[must_use]
    pub const fn values(self) -> [u64; 3] {
        [self.market_value, self.buyout, self.quantity]
    }
}

impl Import {
    /// Returns the import market for `(region, name, market)`, or `None` when `name` is already
    /// held by another region.
    pub fn market_mut(
        &mut self,
        region: u32,
        name: &str,
        market: Faction,
    ) -> Option<&mut ImportMarket> {
        Some(
            self.realm_in(region, name)?
                .markets
                .entry(market)
                .or_default(),
        )
    }

    /// Adds merged vendor prices, keeping the region each realm name was first seen with and
    /// leaving out grey items.
    pub fn add_vendor_prices(&mut self, vendor_prices: &[VendorPrices], grey: &BTreeSet<ItemId>) {
        for entry in vendor_prices {
            if let Some(realm) = self.realm_in(entry.region, &entry.realm) {
                let prices = entry
                    .prices
                    .iter()
                    .filter(|(item, _)| !grey.contains(item))
                    .map(|(&item, &price)| (item, price))
                    .collect();
                realm.vendor_prices.insert(entry.faction.clone(), prices);
            }
        }
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

const fn copper<'a>((key, value): (&'a DbKey, &Copper)) -> (&'a DbKey, u64) {
    (key, value.get())
}

const fn count<'a>((key, value): (&'a DbKey, &Count)) -> (&'a DbKey, u64) {
    (key, value.get())
}

fn is_grey(key: &DbKey, grey: &BTreeSet<ItemId>) -> bool {
    !grey.is_empty() && key.item_id().is_some_and(|id| grey.contains(&id))
}

impl ImportMarket {
    /// Computes the first UTC day number kept in `days` for a market whose newest scan is `newest`.
    #[must_use]
    pub const fn first_day_for(newest_scan: Option<Timestamp>) -> u64 {
        match newest_scan {
            Some(at) => (at.get() / DAY).saturating_sub(WINDOW_DAYS),
            None => 0,
        }
    }

    /// Sets the synced buyout lists, leaving out grey items.
    pub fn set_buyouts(
        &mut self,
        items: Option<BuyoutList>,
        variants: Option<BuyoutList>,
        grey: &BTreeSet<ItemId>,
    ) {
        let mut items = items;
        let mut variants = variants.filter(|list| list.prices.keys().any(DbKey::is_variant));

        // When one scan saw both, the item list already holds that scan's item IDs.
        if let (Some(items), Some(variants)) = (&items, &mut variants)
            && items.at == variants.at
        {
            variants.prices.retain(|key, _| key.is_variant());
        }
        for list in items.iter_mut().chain(variants.iter_mut()) {
            list.prices.retain(|key, _| !is_grey(key, grey));
        }
        self.item_buyouts = items;
        self.variant_buyouts = variants;
    }

    /// Folds one cached scan into this market's daily totals and `latest` timestamps, leaving out
    /// grey items, and random-enchant gear that TSM prices by item ID.
    pub fn add_scan(
        &mut self,
        cached: &CachedScan,
        first_day: u64,
        excluded_random_suffix: &BTreeSet<ItemId>,
        grey: &BTreeSet<ItemId>,
    ) {
        let scan = &cached.scan;
        match scan.kind {
            ScanKind::Full => self.scans.insert(scan.at),
            ScanKind::Quick => self.quick_scans.insert(scan.at),
        };
        let excluded = if cached.is_tsm() {
            excluded_random_suffix
        } else {
            &BTreeSet::new()
        };
        let day = (scan.at.get() / DAY >= first_day).then_some(scan.at.get() / DAY);
        let skip = |key: &DbKey| {
            is_grey(key, grey) || key.item_id().is_some_and(|id| excluded.contains(&id))
        };

        let mut add = |values: &mut dyn Iterator<Item = (&DbKey, u64)>,
                       field: fn(&mut DayTotals) -> &mut u64| {
            for (key, value) in values {
                if value == 0 || skip(key) {
                    continue;
                }
                let item = self.items.entry(key.clone()).or_insert_with(|| ImportItem {
                    latest: scan.at,
                    days: BTreeMap::new(),
                });
                item.latest = item.latest.max(scan.at);
                if let Some(day) = day {
                    *field(item.days.entry(day).or_default()) += value * SCANS_PER_DAY + 1;
                }
            }
        };

        add(&mut scan.market_values.iter().map(copper), |day| {
            &mut day.market_value
        });
        add(&mut scan.buyouts.iter().flatten().map(copper), |day| {
            &mut day.buyout
        });
        add(&mut scan.quantities.iter().flatten().map(count), |day| {
            &mut day.quantity
        });
    }

    /// Records the newest full scan or snapshot as the last scan.
    pub fn finish(&mut self) {
        self.last_scan = self.scans.iter().next_back().copied();
    }
}

#[cfg(test)]
mod tests {
    use super::{BuyoutList, DAY, DayTotals, Import, ImportItem, ImportMarket};
    use crate::{
        database::{Copper, Count, DbKey, Faction, ItemId, Timestamp},
        payload::{CachedScan, Scan, ScanKind, VendorPrices},
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

    fn counts(entries: &[(&str, u64)]) -> BTreeMap<DbKey, Count> {
        entries
            .iter()
            .map(|&(key, value)| (DbKey::new(key), Count::new(value).unwrap()))
            .collect()
    }

    fn cached_scan(id: &str, when: u64, values: &[(&str, u64)]) -> CachedScan {
        CachedScan {
            id: id.to_owned(),
            scan: Scan {
                at: at(when),
                market_values: prices(values),
                ..Scan::default()
            },
        }
    }

    fn ids(values: &[u64]) -> BTreeSet<ItemId> {
        values.iter().map(|&id| ItemId::new(id).unwrap()).collect()
    }

    /// The addon unpacks a day's value as `total * 1024 + count`.
    fn day(total: u64, count: u64) -> u64 {
        total * 1024 + count
    }

    fn market_value(total: u64, count: u64) -> DayTotals {
        DayTotals {
            market_value: day(total, count),
            ..DayTotals::default()
        }
    }

    #[test]
    fn scans_add_up_by_day_within_the_window_before_the_newest_scan() {
        let newest = 40 * DAY + 3_600;
        let scans = vec![
            cached_scan("own:1", 25 * DAY + 60, &[("2589", 7), ("4306", 50)]),
            cached_scan("own:2", 26 * DAY + 60, &[("2589", 10)]),
            cached_scan("own:3", 40 * DAY + 60, &[("2589", 30), ("4306", 0)]),
            cached_scan("tsm:4", newest, &[("2589", 12), ("300001", 999)]),
        ];
        let excluded = ids(&[300_001]);

        let mut import = Import::default();
        let market = import
            .market_mut(1, "Whitemane", Faction::Alliance)
            .unwrap();
        let first_day = ImportMarket::first_day_for(Some(at(newest)));
        for scan in &scans {
            market.add_scan(scan, first_day, &excluded, &BTreeSet::new());
        }
        market.finish();

        let market = &import.realms["Whitemane"].markets[&Faction::Alliance];
        assert_eq!(market.last_scan, Some(at(newest)));
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
                        days: BTreeMap::from([
                            (26, market_value(10, 1)),
                            (40, market_value(42, 2))
                        ]),
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
    fn each_value_counts_only_the_scans_that_recorded_it() {
        let full = CachedScan {
            id: "own:1".to_owned(),
            scan: Scan {
                at: at(10 * DAY),
                kind: ScanKind::Full,
                market_values: prices(&[("2589", 12)]),
                buyouts: Some(prices(&[("2589", 10), ("equip:9868:-18", 500)])),
                quantities: Some(counts(&[("2589", 40), ("equip:9868:-18", 1)])),
            },
        };
        let quick = CachedScan {
            id: "own:2".to_owned(),
            scan: Scan {
                at: at(10 * DAY + 3_600),
                kind: ScanKind::Quick,
                buyouts: Some(prices(&[("2589", 8)])),
                quantities: Some(counts(&[("2589", 30)])),
                ..Scan::default()
            },
        };
        let tsm = CachedScan {
            id: "tsm:3".to_owned(),
            scan: Scan {
                at: at(10 * DAY + 7_200),
                market_values: prices(&[("2589", 14)]),
                buyouts: Some(prices(&[("2589", 11)])),
                ..Scan::default()
            },
        };

        let mut market = ImportMarket::default();
        for scan in [&full, &quick, &tsm] {
            market.add_scan(scan, 0, &BTreeSet::new(), &BTreeSet::new());
        }
        market.finish();

        assert_eq!(
            market.items[&DbKey::new("2589")],
            ImportItem {
                latest: at(10 * DAY + 7_200),
                days: BTreeMap::from([(
                    10,
                    DayTotals {
                        market_value: day(12 + 14, 2),
                        buyout: day(10 + 8 + 11, 3),
                        quantity: day(40 + 30, 2),
                    }
                )]),
            }
        );
        assert_eq!(
            market.items[&DbKey::new("equip:9868:-18")].days[&10],
            DayTotals {
                market_value: 0,
                buyout: day(500, 1),
                quantity: day(1, 1),
            }
        );
        assert_eq!(
            market.scans,
            BTreeSet::from([at(10 * DAY), at(10 * DAY + 7_200)])
        );
        assert_eq!(market.quick_scans, BTreeSet::from([at(10 * DAY + 3_600)]));
        assert_eq!(market.last_scan, Some(at(10 * DAY + 7_200)));
    }

    #[test]
    fn grey_items_and_their_variants_are_left_out() {
        let scan = CachedScan {
            id: "own:1".to_owned(),
            scan: Scan {
                at: at(DAY),
                market_values: prices(&[("2589", 12), ("3300", 5), ("equip:3300:7", 6)]),
                ..Scan::default()
            },
        };
        let grey = ids(&[3_300]);

        let mut market = ImportMarket::default();
        market.add_scan(&scan, 0, &BTreeSet::new(), &grey);
        market.set_buyouts(
            Some(BuyoutList {
                at: at(DAY),
                prices: prices(&[("2589", 10), ("3300", 4)]),
            }),
            Some(BuyoutList {
                at: at(DAY - 1),
                prices: prices(&[("equip:3300:7", 6), ("equip:9868:-18", 500)]),
            }),
            &grey,
        );

        assert_eq!(
            market.items.keys().collect::<Vec<_>>(),
            vec![&DbKey::new("2589")]
        );
        assert_eq!(market.item_buyouts.unwrap().prices, prices(&[("2589", 10)]));
        assert_eq!(
            market.variant_buyouts.unwrap().prices,
            prices(&[("equip:9868:-18", 500)])
        );
    }

    #[test]
    fn item_ids_come_from_the_newest_buyouts_and_random_enchant_gear_from_its_own_scan() {
        let mut market = ImportMarket::default();
        market.set_buyouts(
            Some(BuyoutList {
                at: at(200),
                prices: prices(&[("2589", 30)]),
            }),
            Some(BuyoutList {
                at: at(100),
                prices: prices(&[("9868", 3_900), ("equip:9868:-18", 5_000)]),
            }),
            &BTreeSet::new(),
        );

        assert_eq!(
            market.item_buyouts,
            Some(BuyoutList {
                at: at(200),
                prices: prices(&[("2589", 30)]),
            })
        );
        assert_eq!(
            market.variant_buyouts,
            Some(BuyoutList {
                at: at(100),
                prices: prices(&[("9868", 3_900), ("equip:9868:-18", 5_000)]),
            })
        );
    }

    #[test]
    fn one_scan_with_every_buyout_splits_item_ids_from_variants() {
        let mut market = ImportMarket::default();
        market.set_buyouts(
            Some(BuyoutList {
                at: at(300),
                prices: prices(&[("2589", 30), ("9868", 3_900)]),
            }),
            Some(BuyoutList {
                at: at(300),
                prices: prices(&[("9868", 3_900), ("equip:9868:-18", 5_000)]),
            }),
            &BTreeSet::new(),
        );

        assert_eq!(
            market.item_buyouts,
            Some(BuyoutList {
                at: at(300),
                prices: prices(&[("2589", 30), ("9868", 3_900)]),
            })
        );
        assert_eq!(
            market.variant_buyouts,
            Some(BuyoutList {
                at: at(300),
                prices: prices(&[("equip:9868:-18", 5_000)]),
            })
        );
    }

    #[test]
    fn without_a_variant_there_is_no_variant_list() {
        let mut market = ImportMarket::default();
        market.set_buyouts(
            Some(BuyoutList {
                at: at(300),
                prices: prices(&[("2589", 30)]),
            }),
            Some(BuyoutList {
                at: at(300),
                prices: prices(&[("9868", 3_900)]),
            }),
            &BTreeSet::new(),
        );

        assert!(market.item_buyouts.is_some());
        assert_eq!(market.variant_buyouts, None);
    }

    #[test]
    fn the_last_scan_is_the_newest_full_scan_whatever_the_buyouts() {
        let mut market = ImportMarket::default();
        let first_day = ImportMarket::first_day_for(Some(at(300)));
        market.add_scan(
            &cached_scan("own:1", 100, &[("2589", 40)]),
            first_day,
            &BTreeSet::new(),
            &BTreeSet::new(),
        );
        market.add_scan(
            &cached_scan("own:2", 300, &[]),
            first_day,
            &BTreeSet::new(),
            &BTreeSet::new(),
        );
        market.set_buyouts(
            Some(BuyoutList {
                at: at(400),
                prices: prices(&[("2589", 30)]),
            }),
            None,
            &BTreeSet::new(),
        );
        market.finish();

        assert_eq!(market.last_scan, Some(at(300)));
    }

    #[test]
    fn a_realm_name_from_a_second_region_is_dropped() {
        let mut import = Import::default();
        assert!(
            import
                .market_mut(1, "Whitemane", Faction::Alliance)
                .is_some()
        );
        assert!(import.market_mut(3, "Whitemane", Faction::Horde).is_none());
        import.add_vendor_prices(
            &[
                VendorPrices {
                    region: 1,
                    realm: "Whitemane".to_owned(),
                    faction: "Alliance".to_owned(),
                    prices: BTreeMap::from([
                        (ItemId::new(2589).unwrap(), copper(5)),
                        (ItemId::new(3300).unwrap(), copper(1)),
                    ]),
                },
                VendorPrices {
                    region: 3,
                    realm: "Whitemane".to_owned(),
                    faction: "Horde".to_owned(),
                    prices: BTreeMap::from([(ItemId::new(1).unwrap(), copper(1))]),
                },
            ],
            &ids(&[3_300]),
        );

        let whitemane = &import.realms["Whitemane"];
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
