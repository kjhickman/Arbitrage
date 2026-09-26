pub mod database;
pub mod payload;
pub mod pivot;

pub use crate::{
    database::{Copper, Database, DbKey, Faction, ItemHistory, ItemId, Market, Realm, Timestamp},
    payload::{MarketScans, PayloadError, Scan, SyncPayload, VendorPrices},
};

/// The one version tag. The Lua `__version` field and the JSON `schema` field both carry it.
pub const SCHEMA_VERSION: u32 = 2;
