pub mod database;
pub mod merge;
pub mod payload;

pub use crate::{
    database::{Copper, Database, DbKey, Faction, ItemHistory, ItemId, Market, Realm, Timestamp},
    merge::merge,
    payload::{PayloadError, SyncPayload},
};

/// The one version tag. The Lua `__version` field and the JSON `schema` field both carry it.
pub const SCHEMA_VERSION: u32 = 1;
