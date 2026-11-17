pub mod database;
pub mod import;
pub mod payload;
pub mod pivot;

pub use crate::{
    database::{Copper, Database, DbKey, Faction, ItemHistory, ItemId, Market, Realm, Timestamp},
    import::{Import, ImportItem, ImportMarket, ImportRealm},
    payload::{MarketScans, PayloadError, Scan, SyncPayload, VendorPrices},
};

/// The one version tag. The Lua `__version` field and the JSON `schema` field both carry it.
pub const SCHEMA_VERSION: u32 = 2;

/// The import's Lua `__version`, which moved past [`SCHEMA_VERSION`] when it began holding day
/// totals instead of scans.
pub const IMPORT_VERSION: u32 = 3;
