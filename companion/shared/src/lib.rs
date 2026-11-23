pub mod database;
pub mod import;
pub mod payload;
pub mod pivot;

pub use crate::{
    database::{Copper, Database, DbKey, Faction, ItemHistory, ItemId, Market, Realm, Timestamp},
    import::{BuyoutList, Import, ImportItem, ImportMarket, ImportRealm},
    payload::{
        BuyoutUpdate, CachedScan, MarketScans, MarketSyncRequest, MarketSyncResponse,
        OwnScanSummary, PayloadError, Scan, ScanUploadRequest, SyncRequest, SyncResponse,
        VendorPrices, scan_id,
    },
    pivot::LocalDatabase,
};

/// The `SavedVariables` `ARBITRAGE_DATABASE.__version` written by the addon.
pub const SCHEMA_VERSION: u32 = 2;

/// The import's Lua `__version`, which moved past [`SCHEMA_VERSION`] when it began holding day
/// totals instead of scans.
pub const IMPORT_VERSION: u32 = 3;

/// The JSON `schema` version spoken by the companion and worker sync endpoints.
pub const SYNC_SCHEMA_VERSION: u32 = 3;
