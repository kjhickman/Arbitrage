use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::{
    database::{Copper, DbKey, Faction, ItemId, Timestamp},
    payload::{CachedScan, VendorPrices},
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
    pub last_scan: Option<Timestamp>,
    /// The newest scan's buyouts whole, for addons from before the buyout lists.
    pub latest_buyouts: BTreeMap<DbKey, Copper>,
    /// Buyouts by item ID, from the newest scan with buyouts.
    pub item_buyouts: Option<BuyoutList>,
    /// Random-enchant gear, from the newest scan that saw it. When that's an older scan than the
    /// item list's, it also holds the gear's item IDs, which the newer scan couldn't see.
    pub variant_buyouts: Option<BuyoutList>,
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

    /// Adds merged vendor prices, keeping the region each realm name was first seen with.
    pub fn add_vendor_prices(&mut self, vendor_prices: &[VendorPrices]) {
        for entry in vendor_prices {
            if let Some(realm) = self.realm_in(entry.region, &entry.realm) {
                realm
                    .vendor_prices
                    .insert(entry.faction.clone(), entry.prices.clone());
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

fn is_variant(key: &DbKey) -> bool {
    key.as_str().starts_with("equip:")
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

    /// Sets the synced buyout lists and derives the legacy `latest_buyouts` and `last_scan`.
    pub fn set_buyouts(&mut self, items: Option<BuyoutList>, variants: Option<BuyoutList>) {
        let mut variants = variants.filter(|list| list.prices.keys().any(is_variant));
        let newest = items.iter().chain(&variants).max_by_key(|list| list.at);
        if let Some(newest) = newest {
            self.last_scan = Some(newest.at);
        }
        self.latest_buyouts = newest.map(|list| list.prices.clone()).unwrap_or_default();

        // When one scan saw both, the legacy list holds all of it, and the item list already holds
        // that scan's item IDs.
        if let (Some(items), Some(variants)) = (&items, &mut variants)
            && items.at == variants.at
        {
            self.latest_buyouts.extend(items.prices.clone());
            variants.prices.retain(|key, _| is_variant(key));
        }
        self.item_buyouts = items;
        self.variant_buyouts = variants;
    }

    /// Folds one cached scan into this market's daily totals and `latest` timestamps.
    pub fn add_scan(
        &mut self,
        scan: &CachedScan,
        first_day: u64,
        excluded_random_suffix: &BTreeSet<ItemId>,
    ) {
        self.scans.insert(scan.at);
        let is_tsm = scan.id.starts_with("tsm:");
        let day = scan.at.get() / DAY;

        for (key, copper) in scan.values.iter().filter(|(_, copper)| copper.get() > 0) {
            if is_tsm
                && !excluded_random_suffix.is_empty()
                && key
                    .as_str()
                    .parse::<u64>()
                    .ok()
                    .and_then(ItemId::new)
                    .is_some_and(|id| excluded_random_suffix.contains(&id))
            {
                continue;
            }
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

    /// Fills `last_scan` from the newest scan when no buyout list set it.
    pub fn finish(&mut self) {
        if self.last_scan.is_none() {
            self.last_scan = self.scans.iter().next_back().copied();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{BuyoutList, DAY, Import, ImportItem, ImportMarket};
    use crate::{
        database::{Copper, DbKey, Faction, ItemId, Timestamp},
        payload::{CachedScan, VendorPrices},
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

    fn cached_scan(id: &str, when: u64, values: &[(&str, u64)]) -> CachedScan {
        CachedScan {
            id: id.to_owned(),
            at: at(when),
            values: prices(values),
        }
    }

    /// The addon unpacks a day as `total * 1024 + count`.
    fn day(total: u64, count: u64) -> u64 {
        total * 1024 + count
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
        let excluded = BTreeSet::from([ItemId::new(300_001).unwrap()]);

        let mut import = Import::default();
        let market = import
            .market_mut(1, "Whitemane", Faction::Alliance)
            .unwrap();
        let first_day = ImportMarket::first_day_for(Some(at(newest)));
        market.set_buyouts(
            Some(BuyoutList {
                at: at(newest),
                prices: prices(&[("2589", 9)]),
            }),
            None,
        );
        for scan in &scans {
            market.add_scan(scan, first_day, &excluded);
        }
        market.finish();

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
        );
        market.finish();

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
        assert_eq!(market.latest_buyouts, prices(&[("2589", 30)]));
        assert_eq!(market.last_scan, Some(at(200)));
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
        );
        market.finish();

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
        assert_eq!(
            market.latest_buyouts,
            prices(&[("2589", 30), ("9868", 3_900), ("equip:9868:-18", 5_000)])
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
        );
        market.finish();

        assert!(market.item_buyouts.is_some());
        assert_eq!(market.variant_buyouts, None);
    }

    #[test]
    fn without_any_buyouts_the_newest_scan_is_the_last_scan() {
        let mut market = ImportMarket::default();
        let first_day = ImportMarket::first_day_for(Some(at(300)));
        market.add_scan(
            &cached_scan("own:1", 100, &[("2589", 40)]),
            first_day,
            &BTreeSet::new(),
        );
        market.add_scan(&cached_scan("own:2", 300, &[]), first_day, &BTreeSet::new());
        market.finish();

        assert_eq!(market.last_scan, Some(at(300)));
        assert!(market.latest_buyouts.is_empty());
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
        import.add_vendor_prices(&[
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
        ]);

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
