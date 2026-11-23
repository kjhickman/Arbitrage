use std::{
    collections::{BTreeMap, BTreeSet},
    env, fs, io,
    path::PathBuf,
};

use arbitrage_shared::{
    BuyoutList, BuyoutUpdate, CachedScan, Faction, ImportMarket, ItemId, MarketSyncResponse,
    RegionSales, Timestamp,
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{saved_variables::replace, settings};

/// Version 2 holds scans with their kind and every value they recorded.
const CACHE_VERSION: &str = "v2";
const OLDER_CACHE_VERSIONS: [&str; 1] = ["v1"];
const META_FILE: &str = "meta.json";
const SCANS_DIR: &str = "scans";
const REGIONS_DIR: &str = "regions";

/// Persistent per-account cache of synced scans and buyouts so sync only transfers deltas.
#[derive(Debug, Clone)]
pub struct Cache {
    root: PathBuf,
}

impl Cache {
    pub fn for_account(account_id: &str) -> Self {
        let base = settings::app_data_directory()
            .unwrap_or_else(|| env::temp_dir().join("Arbitrage Companion"))
            .join("cache");
        // Older caches hold scans this version can't read, so the first sync downloads them again.
        for version in OLDER_CACHE_VERSIONS {
            let _ = fs::remove_dir_all(base.join(version));
        }
        Self::in_directory(base.join(CACHE_VERSION).join(short_hash(account_id)))
    }

    pub const fn in_directory(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn market(&self, region: u32, realm: &str, market: Faction) -> MarketCache {
        let key = format!("{region}/{}/{realm}", market.name());
        let dir = self.root.join(short_hash(&key));
        MarketCache::load(dir)
    }

    /// The region's newest sales snapshot; anything unreadable is downloaded again.
    pub fn region_sales(&self, region: u32) -> Option<RegionSales> {
        fs::read(self.region_path(region))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<RegionSales>(&bytes).ok())
            .filter(|sales| sales.region == region)
    }

    pub fn put_region_sales(&self, sales: &RegionSales) -> io::Result<()> {
        let path = self.region_path(sales.region);
        fs::create_dir_all(self.root.join(REGIONS_DIR))?;
        let bytes = serde_json::to_vec(sales).map_err(io::Error::other)?;
        replace(&path, &bytes)
    }

    fn region_path(&self, region: u32) -> PathBuf {
        self.root.join(REGIONS_DIR).join(format!("{region}.json"))
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct MarketMeta {
    scans: BTreeMap<String, Timestamp>,
    item_buyouts: Option<BuyoutList>,
    variant_buyouts: Option<BuyoutList>,
    excluded_random_suffix: BTreeSet<ItemId>,
}

/// On-disk scan cache for one `(region, realm, faction)` market.
#[derive(Debug)]
pub struct MarketCache {
    dir: PathBuf,
    meta: MarketMeta,
}

impl MarketCache {
    /// A missing or corrupt scan file surfaces in `stream_into_import`, which evicts it.
    fn load(dir: PathBuf) -> Self {
        let meta = fs::read(dir.join(META_FILE))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<MarketMeta>(&bytes).ok())
            .unwrap_or_default();
        Self { dir, meta }
    }

    pub fn have_scans(&self) -> Vec<String> {
        self.meta.scans.keys().cloned().collect()
    }

    pub fn have_item_buyouts_at(&self) -> Option<Timestamp> {
        self.meta.item_buyouts.as_ref().map(|list| list.at)
    }

    pub fn have_variant_buyouts_at(&self) -> Option<Timestamp> {
        self.meta.variant_buyouts.as_ref().map(|list| list.at)
    }

    /// Saves one scan immediately (for example, right after uploading it so the server does not
    /// have to send it back).
    pub fn put_scan(&mut self, scan: &CachedScan) -> io::Result<()> {
        self.write_scan_file(scan)?;
        self.meta.scans.insert(scan.id.clone(), scan.scan.at);
        self.save_meta()
    }

    /// Persists newly downloaded scans, drops scans no longer in `active_scans`, and updates
    /// buyout snapshots and dynamic random-suffix exclusions.
    pub fn apply_delta(&mut self, delta: &MarketSyncResponse) -> io::Result<()> {
        for scan in &delta.scans {
            self.write_scan_file(scan)?;
            self.meta.scans.insert(scan.id.clone(), scan.scan.at);
        }

        let active: BTreeSet<&str> = delta.active_scans.iter().map(String::as_str).collect();
        let removed: Vec<String> = self
            .meta
            .scans
            .keys()
            .filter(|id| !active.contains(id.as_str()))
            .cloned()
            .collect();
        for id in removed {
            self.meta.scans.remove(&id);
            let _ = fs::remove_file(self.scan_path(&id));
        }

        apply_buyout_update(&mut self.meta.item_buyouts, &delta.item_buyouts);
        apply_buyout_update(&mut self.meta.variant_buyouts, &delta.variant_buyouts);
        self.meta.excluded_random_suffix = delta.excluded_random_suffix.iter().copied().collect();

        self.save_meta()
    }

    /// Streams cached scan files one at a time into `target` so the full 30-day history never sits
    /// in memory at once, leaving out grey items.
    pub fn stream_into_import(
        &mut self,
        target: &mut ImportMarket,
        grey: &BTreeSet<ItemId>,
    ) -> io::Result<()> {
        let newest = self.meta.scans.values().copied().max();
        let first_day = ImportMarket::first_day_for(newest);
        target.set_buyouts(
            self.meta.item_buyouts.clone(),
            self.meta.variant_buyouts.clone(),
            grey,
        );

        let ids: Vec<String> = self.meta.scans.keys().cloned().collect();
        for id in ids {
            let scan = fs::read(self.scan_path(&id)).and_then(|bytes| {
                serde_json::from_slice::<CachedScan>(&bytes).map_err(io::Error::other)
            });
            match scan {
                Ok(scan) => {
                    target.add_scan(&scan, first_day, &self.meta.excluded_random_suffix, grey);
                }
                Err(error) => {
                    self.evict(&id);
                    return Err(error);
                }
            }
        }
        target.finish();
        Ok(())
    }

    fn evict(&mut self, id: &str) {
        self.meta.scans.remove(id);
        let _ = fs::remove_file(self.scan_path(id));
        let _ = self.save_meta();
    }

    fn scan_path(&self, id: &str) -> PathBuf {
        self.dir.join(SCANS_DIR).join(scan_file_name(id))
    }

    fn write_scan_file(&self, scan: &CachedScan) -> io::Result<()> {
        let scans_dir = self.dir.join(SCANS_DIR);
        fs::create_dir_all(&scans_dir)?;
        let bytes = serde_json::to_vec(scan).map_err(io::Error::other)?;
        replace(&scans_dir.join(scan_file_name(&scan.id)), &bytes)
    }

    fn save_meta(&self) -> io::Result<()> {
        fs::create_dir_all(&self.dir)?;
        let bytes = serde_json::to_vec(&self.meta).map_err(io::Error::other)?;
        replace(&self.dir.join(META_FILE), &bytes)
    }
}

fn apply_buyout_update(target: &mut Option<BuyoutList>, update: &BuyoutUpdate) {
    match update {
        BuyoutUpdate::Unchanged => {}
        BuyoutUpdate::Clear => *target = None,
        BuyoutUpdate::Replace(list) => *target = Some(list.clone()),
    }
}

fn scan_file_name(id: &str) -> String {
    format!("{}.json", short_hash(id))
}

/// A filename-safe name for a key: 128 bits of its SHA-256.
fn short_hash(input: &str) -> String {
    URL_SAFE_NO_PAD.encode(&Sha256::digest(input.as_bytes())[..16])
}

#[cfg(test)]
mod tests {
    use super::Cache;
    use crate::saved_variables::temp;
    use arbitrage_shared::{
        BuyoutList, BuyoutUpdate, CachedScan, Copper, Count, DbKey, Faction, ImportMarket, ItemId,
        MarketSyncResponse, RegionSales, Sale, Scan, Timestamp,
    };
    use std::{
        collections::{BTreeMap, BTreeSet},
        fs,
    };

    fn at(seconds: u64) -> Timestamp {
        Timestamp::new(seconds).unwrap()
    }

    fn copper(value: u64) -> Copper {
        Copper::new(value).unwrap()
    }

    fn scan(id: &str, when: u64, values: &[(&str, u64)]) -> CachedScan {
        CachedScan {
            id: id.to_owned(),
            scan: Scan {
                at: at(when),
                market_values: values
                    .iter()
                    .map(|&(key, value)| (DbKey::new(key), copper(value)))
                    .collect(),
                ..Scan::default()
            },
        }
    }

    #[test]
    fn cache_persists_deltas_prunes_retired_scans_and_streams_into_import() {
        let dir = temp::Dir::new("cache-round-trip");
        let cache = Cache::in_directory(dir.path().to_path_buf());

        let mut market = cache.market(1, "PvP", Faction::Horde);
        market
            .put_scan(&scan("own:1", 100, &[("2589", 10)]))
            .expect("put_scan should write");

        let delta = MarketSyncResponse {
            region: 1,
            realm: "PvP".to_owned(),
            market: Faction::Horde,
            upload: vec![],
            active_scans: vec!["own:1".to_owned(), "tsm:200".to_owned()],
            scans: vec![scan("tsm:200", 200, &[("2589", 20), ("300001", 999)])],
            more_scans: false,
            item_buyouts: BuyoutUpdate::Replace(BuyoutList {
                at: at(200),
                prices: BTreeMap::from([(DbKey::new("2589"), copper(18))]),
            }),
            variant_buyouts: BuyoutUpdate::Replace(BuyoutList {
                at: at(100),
                prices: BTreeMap::from([
                    (DbKey::new("300001"), copper(450)),
                    (DbKey::new("equip:300001:-18"), copper(500)),
                ]),
            }),
            excluded_random_suffix: vec![ItemId::new(300_001).unwrap()],
        };
        market.apply_delta(&delta).expect("delta should apply");

        // Reload from disk and prune "own:1" while keeping buyouts unchanged.
        let mut reloaded = cache.market(1, "PvP", Faction::Horde);
        assert_eq!(reloaded.have_scans(), vec!["own:1", "tsm:200"]);
        assert_eq!(reloaded.have_item_buyouts_at(), Some(at(200)));
        assert_eq!(reloaded.have_variant_buyouts_at(), Some(at(100)));

        let prune = MarketSyncResponse {
            region: 1,
            realm: "PvP".to_owned(),
            market: Faction::Horde,
            upload: vec![],
            active_scans: vec!["tsm:200".to_owned()],
            scans: vec![],
            more_scans: false,
            item_buyouts: BuyoutUpdate::Unchanged,
            variant_buyouts: BuyoutUpdate::Unchanged,
            excluded_random_suffix: vec![ItemId::new(300_001).unwrap()],
        };
        reloaded.apply_delta(&prune).expect("prune should apply");
        assert_eq!(reloaded.have_scans(), vec!["tsm:200"]);

        let mut import_market = ImportMarket::default();
        reloaded
            .stream_into_import(&mut import_market, &BTreeSet::new())
            .expect("stream into import should succeed");
        assert_eq!(import_market.last_scan, Some(at(200)));
        assert!(import_market.items.contains_key(&DbKey::new("2589")));
        assert!(!import_market.items.contains_key(&DbKey::new("300001")));
        assert_eq!(
            import_market.variant_buyouts.as_ref().map(|b| b.at),
            Some(at(100))
        );
    }

    #[test]
    fn missing_or_corrupt_scan_files_are_evicted_so_the_next_sync_recovers_them() {
        let dir = temp::Dir::new("cache-heal");
        let cache = Cache::in_directory(dir.path().to_path_buf());
        let mut market = cache.market(1, "PvP", Faction::Horde);
        market
            .put_scan(&scan("tsm:100", 100, &[("2589", 10)]))
            .expect("put_scan should write");

        // Corrupt the scan file on disk.
        let path = market.scan_path("tsm:100");
        fs::write(&path, b"{not json").expect("corrupt file");

        let mut import_market = ImportMarket::default();
        assert!(
            market
                .stream_into_import(&mut import_market, &BTreeSet::new())
                .is_err()
        );

        // Reloading no longer claims to have the evicted scan.
        let reloaded = cache.market(1, "PvP", Faction::Horde);
        assert_eq!(reloaded.have_scans(), Vec::<String>::new());
    }

    #[test]
    fn region_sales_round_trip_and_unreadable_ones_are_downloaded_again() {
        let dir = temp::Dir::new("cache-regions");
        let cache = Cache::in_directory(dir.path().to_path_buf());
        let sales = RegionSales {
            region: 1,
            at: at(500),
            items: BTreeMap::from([(
                ItemId::new(785).unwrap(),
                Sale(
                    copper(40),
                    Count::new(887).unwrap(),
                    Count::new(10).unwrap(),
                ),
            )]),
        };

        assert_eq!(cache.region_sales(1), None);
        cache.put_region_sales(&sales).expect("sales should write");
        assert_eq!(cache.region_sales(1), Some(sales));
        assert_eq!(cache.region_sales(3), None);

        fs::write(dir.path().join("regions").join("1.json"), b"{not json").unwrap();
        assert_eq!(cache.region_sales(1), None);
    }
}
