pub mod database;
pub mod import;
pub mod payload;
pub mod pivot;

pub use crate::{
    database::{Copper, Count, Database, DbKey, Faction, ItemId, Market, Realm, Timestamp},
    import::{BuyoutList, DayTotals, Import, ImportItem, ImportMarket, ImportRealm},
    payload::{
        BuyoutUpdate, CachedScan, MarketScans, MarketSyncRequest, MarketSyncResponse,
        OwnScanSummary, PayloadError, RegionSales, RegionSyncRequest, Sale, Scan, ScanKind,
        ScanUploadRequest, SyncRequest, SyncResponse, VendorPrices, scan_id,
    },
    pivot::LocalDatabase,
};

/// The `SavedVariables` `ARBITRAGE_DATABASE.__version` written by the addon: each market's scans
/// by time, each holding its values as text.
pub const SCHEMA_VERSION: u32 = 3;

/// The older saved database the companion still reads: each item's market values by scan time,
/// with buyouts for the latest scan only.
pub const ITEM_SCHEMA_VERSION: u32 = 2;

/// The import's Lua `__version`. Version 5 holds a list of numbers per item: when it was last
/// seen, then each day's totals of market value, buyout, and quantity.
pub const IMPORT_VERSION: u32 = 5;

/// The JSON `schema` version spoken by the companion and worker sync endpoints.
pub const SYNC_SCHEMA_VERSION: u32 = 4;
