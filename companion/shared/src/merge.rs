use std::collections::BTreeMap;

use crate::database::{Database, ItemHistory, Market, Realm};

const SCAN_WINDOW_SECONDS: u64 = 30 * 86_400;

/// Joins two databases into one, then prunes the join to the scan window.
///
/// The result does not depend on the argument order.
#[must_use]
pub fn merge(left: &Database, right: &Database) -> Database {
    let mut joined = Database {
        last_replicate_scan: left.last_replicate_scan.max(right.last_replicate_scan),
        realms: union(&left.realms, &right.realms, merge_realm),
    };

    normalize(&mut joined);
    joined
}

fn merge_realm(left: &Realm, right: &Realm) -> Realm {
    Realm {
        markets: union(&left.markets, &right.markets, merge_market),
        vendor_prices: union(&left.vendor_prices, &right.vendor_prices, |left, right| {
            union(left, right, lower)
        }),
    }
}

fn merge_market(left: &Market, right: &Market) -> Market {
    // A buyout map is one snapshot, so the newer scan brings its whole map rather than a blend.
    let newer =
        if (left.last_scan, &left.latest_buyouts) >= (right.last_scan, &right.latest_buyouts) {
            left
        } else {
            right
        };

    Market {
        last_scan: newer.last_scan,
        items: union(&left.items, &right.items, merge_item),
        latest_buyouts: newer.latest_buyouts.clone(),
    }
}

fn merge_item(left: &ItemHistory, right: &ItemHistory) -> ItemHistory {
    ItemHistory {
        scans: union(&left.scans, &right.scans, lower),
    }
}

fn lower<T: Ord + Copy>(left: &T, right: &T) -> T {
    (*left).min(*right)
}

fn union<K, V>(
    left: &BTreeMap<K, V>,
    right: &BTreeMap<K, V>,
    combine: impl Fn(&V, &V) -> V,
) -> BTreeMap<K, V>
where
    K: Ord + Clone,
    V: Clone,
{
    let mut joined = left.clone();

    for (key, value) in right {
        let combined = joined
            .get(key)
            .map_or_else(|| value.clone(), |existing| combine(existing, value));
        joined.insert(key.clone(), combined);
    }

    joined
}

fn normalize(database: &mut Database) {
    for realm in database.realms.values_mut() {
        for market in realm.markets.values_mut() {
            prune_scans(market);
        }

        for prices in realm.vendor_prices.values_mut() {
            prices.retain(|_, price| price.get() > 0);
        }
        realm.vendor_prices.retain(|_, prices| !prices.is_empty());
    }
}

fn prune_scans(market: &mut Market) {
    let Some(last_scan) = market.last_scan else {
        return;
    };
    let cutoff = last_scan.get().saturating_sub(SCAN_WINDOW_SECONDS);

    for history in market.items.values_mut() {
        history.scans.retain(|at, _| at.get() >= cutoff);
    }
    market.items.retain(|_, history| !history.scans.is_empty());
}

#[cfg(test)]
mod tests {
    use super::{SCAN_WINDOW_SECONDS, merge};
    use crate::database::{
        Copper, Database, DbKey, Faction, ItemHistory, ItemId, Market, Realm, Timestamp,
    };
    use std::collections::BTreeMap;

    const DAY: u64 = 86_400;
    const NOW: u64 = 1_700_000_000;

    fn at(seconds: u64) -> Timestamp {
        Timestamp::new(seconds).expect("the timestamp should be in range")
    }

    fn copper(value: u64) -> Copper {
        Copper::new(value).expect("the price should be in range")
    }

    fn history(scans: &[(u64, u64)]) -> ItemHistory {
        ItemHistory {
            scans: scans
                .iter()
                .map(|&(when, price)| (at(when), copper(price)))
                .collect(),
        }
    }

    fn market(
        last_scan: Option<u64>,
        items: Vec<(&str, ItemHistory)>,
        latest_buyouts: &[(&str, u64)],
    ) -> Market {
        Market {
            last_scan: last_scan.map(at),
            items: items
                .into_iter()
                .map(|(key, scans)| (DbKey::new(key), scans))
                .collect(),
            latest_buyouts: latest_buyouts
                .iter()
                .map(|&(key, price)| (DbKey::new(key), copper(price)))
                .collect(),
        }
    }

    fn realm(markets: Vec<(Faction, Market)>, vendor_prices: &[(&str, &[(u64, u64)])]) -> Realm {
        Realm {
            markets: markets.into_iter().collect(),
            vendor_prices: vendor_prices
                .iter()
                .map(|&(faction, prices)| {
                    let prices: BTreeMap<ItemId, Copper> = prices
                        .iter()
                        .map(|&(item, price)| {
                            (
                                ItemId::new(item).expect("the item id should be in range"),
                                copper(price),
                            )
                        })
                        .collect();
                    (faction.to_owned(), prices)
                })
                .collect(),
        }
    }

    fn database(last_replicate_scan: Option<u64>, realms: Vec<(&str, Realm)>) -> Database {
        Database {
            last_replicate_scan: last_replicate_scan.map(at),
            realms: realms
                .into_iter()
                .map(|(name, realm)| (name.to_owned(), realm))
                .collect(),
        }
    }

    fn both_orders(left: &Database, right: &Database, expected: &Database) {
        assert_eq!(&merge(left, right), expected, "left then right");
        assert_eq!(&merge(right, left), expected, "right then left");
    }

    #[test]
    fn a_join_unions_realms_and_takes_the_lower_copper_on_a_collision() {
        let left = database(
            Some(NOW - 10),
            vec![
                (
                    "Whitemane",
                    realm(
                        vec![(
                            Faction::Alliance,
                            market(
                                Some(NOW),
                                vec![("2589", history(&[(NOW - DAY, 1_200), (NOW, 900)]))],
                                &[("2589", 900)],
                            ),
                        )],
                        &[("Alliance", &[(2589, 100), (4306, 0)])],
                    ),
                ),
                (
                    "Faerlina",
                    realm(
                        vec![(Faction::Horde, market(Some(NOW), vec![], &[]))],
                        &[("Horde", &[(2589, 0)])],
                    ),
                ),
            ],
        );

        let right = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![
                        (
                            Faction::Alliance,
                            market(
                                Some(NOW),
                                vec![
                                    ("2589", history(&[(NOW - DAY, 800)])),
                                    ("4306", history(&[(NOW, 0)])),
                                ],
                                &[("2589", 900)],
                            ),
                        ),
                        (
                            Faction::Horde,
                            market(Some(NOW - DAY), vec![], &[("2589", 750)]),
                        ),
                    ],
                    &[("Alliance", &[(2589, 250)]), ("Horde", &[(2589, 60)])],
                ),
            )],
        );

        let expected = database(
            Some(NOW - 10),
            vec![
                (
                    "Faerlina",
                    realm(vec![(Faction::Horde, market(Some(NOW), vec![], &[]))], &[]),
                ),
                (
                    "Whitemane",
                    realm(
                        vec![
                            (
                                Faction::Alliance,
                                market(
                                    Some(NOW),
                                    vec![
                                        ("2589", history(&[(NOW - DAY, 800), (NOW, 900)])),
                                        ("4306", history(&[(NOW, 0)])),
                                    ],
                                    &[("2589", 900)],
                                ),
                            ),
                            (
                                Faction::Horde,
                                market(Some(NOW - DAY), vec![], &[("2589", 750)]),
                            ),
                        ],
                        &[("Alliance", &[(2589, 100)]), ("Horde", &[(2589, 60)])],
                    ),
                ),
            ],
        );

        both_orders(&left, &right, &expected);
    }

    #[test]
    fn the_newer_last_scan_replaces_the_whole_buyout_map() {
        let older = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![(
                        Faction::Alliance,
                        market(Some(NOW - DAY), vec![], &[("2589", 100), ("4306", 200)]),
                    )],
                    &[],
                ),
            )],
        );

        let newer = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![(
                        Faction::Alliance,
                        market(Some(NOW), vec![], &[("2589", 999)]),
                    )],
                    &[],
                ),
            )],
        );

        both_orders(&older, &newer, &newer);
    }

    #[test]
    fn a_tie_on_last_scan_keeps_the_greater_buyout_map_whole() {
        let lesser = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![(
                        Faction::Alliance,
                        market(Some(NOW), vec![], &[("2589", 100)]),
                    )],
                    &[],
                ),
            )],
        );

        let greater = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![(
                        Faction::Alliance,
                        market(Some(NOW), vec![], &[("2589", 100), ("4306", 1)]),
                    )],
                    &[],
                ),
            )],
        );

        both_orders(&lesser, &greater, &greater);
    }

    #[test]
    fn a_missing_last_scan_loses_to_a_present_one() {
        let unscanned = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![(Faction::Alliance, market(None, vec![], &[("2589", 5)]))],
                    &[],
                ),
            )],
        );

        let scanned = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![(
                        Faction::Alliance,
                        market(Some(NOW), vec![], &[("2589", 900)]),
                    )],
                    &[],
                ),
            )],
        );

        both_orders(&unscanned, &scanned, &scanned);
    }

    #[test]
    fn the_thirty_day_cutoff_is_inclusive_and_removes_emptied_items() {
        let cutoff = NOW - SCAN_WINDOW_SECONDS;
        let left = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![(
                        Faction::Alliance,
                        market(
                            Some(NOW),
                            vec![
                                ("2589", history(&[(cutoff, 100), (cutoff - 1, 50)])),
                                ("4306", history(&[(cutoff - 1, 70)])),
                            ],
                            &[],
                        ),
                    )],
                    &[],
                ),
            )],
        );

        let expected = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![(
                        Faction::Alliance,
                        market(Some(NOW), vec![("2589", history(&[(cutoff, 100)]))], &[]),
                    )],
                    &[],
                ),
            )],
        );

        both_orders(&left, &Database::default(), &expected);
    }

    #[test]
    fn a_newer_scan_in_one_market_does_not_prune_another() {
        let old = NOW - 40 * DAY;
        let stale = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![(
                        Faction::Horde,
                        market(Some(old), vec![("2589", history(&[(old, 70)]))], &[]),
                    )],
                    &[],
                ),
            )],
        );

        let fresh = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![(
                        Faction::Alliance,
                        market(Some(NOW), vec![("2589", history(&[(NOW, 90)]))], &[]),
                    )],
                    &[],
                ),
            )],
        );

        let expected = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![
                        (
                            Faction::Alliance,
                            market(Some(NOW), vec![("2589", history(&[(NOW, 90)]))], &[]),
                        ),
                        (
                            Faction::Horde,
                            market(Some(old), vec![("2589", history(&[(old, 70)]))], &[]),
                        ),
                    ],
                    &[],
                ),
            )],
        );

        both_orders(&stale, &fresh, &expected);
    }

    #[test]
    fn a_market_with_no_last_scan_is_never_pruned_by_time() {
        let ancient = database(
            None,
            vec![(
                "Whitemane",
                realm(
                    vec![(
                        Faction::Alliance,
                        market(None, vec![("2589", history(&[(1, 70)]))], &[]),
                    )],
                    &[],
                ),
            )],
        );

        both_orders(&ancient, &Database::default(), &ancient);
    }

    #[test]
    fn merging_a_merged_database_again_changes_nothing() {
        let left = database(
            Some(NOW),
            vec![(
                "Whitemane",
                realm(
                    vec![(
                        Faction::Alliance,
                        market(
                            Some(NOW),
                            vec![("2589", history(&[(NOW - 60 * DAY, 10), (NOW, 90)]))],
                            &[("2589", 90)],
                        ),
                    )],
                    &[("Alliance", &[(2589, 0), (4306, 12)])],
                ),
            )],
        );
        let right = database(
            None,
            vec![(
                "Faerlina",
                realm(vec![(Faction::Horde, market(None, vec![], &[]))], &[]),
            )],
        );

        let merged = merge(&left, &right);

        assert_eq!(merge(&merged, &merged), merged);
        assert_eq!(merge(&merged, &right), merged);
        assert_eq!(merge(&merged, &left), merged);
    }
}
