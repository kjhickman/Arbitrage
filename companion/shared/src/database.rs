use std::collections::BTreeMap;

/// Lua numbers and JSON numbers both land in a double, so larger integers are not exact.
const MAX_EXACT: u64 = 1 << 53;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Timestamp(u64);

impl Timestamp {
    #[must_use]
    pub const fn new(value: u64) -> Option<Self> {
        if value <= MAX_EXACT {
            Some(Self(value))
        } else {
            None
        }
    }

    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Copper(u64);

impl Copper {
    #[must_use]
    pub const fn new(value: u64) -> Option<Self> {
        if value <= MAX_EXACT {
            Some(Self(value))
        } else {
            None
        }
    }

    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct ItemId(u64);

impl ItemId {
    #[must_use]
    pub const fn new(value: u64) -> Option<Self> {
        if value <= MAX_EXACT {
            Some(Self(value))
        } else {
            None
        }
    }

    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct DbKey(String);

impl DbKey {
    #[must_use]
    pub fn new(key: impl Into<String>) -> Self {
        Self(key.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Faction {
    Alliance,
    Horde,
    Neutral,
    Unknown,
}

impl Faction {
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Alliance => "Alliance",
            Self::Horde => "Horde",
            Self::Neutral => "Neutral",
            Self::Unknown => "Unknown",
        }
    }

    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "Alliance" => Some(Self::Alliance),
            "Horde" => Some(Self::Horde),
            "Neutral" => Some(Self::Neutral),
            "Unknown" => Some(Self::Unknown),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Database {
    pub last_replicate_scan: Option<Timestamp>,
    pub realms: BTreeMap<String, Realm>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Realm {
    pub markets: BTreeMap<Faction, Market>,
    pub vendor_prices: BTreeMap<String, BTreeMap<ItemId, Copper>>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Market {
    pub last_scan: Option<Timestamp>,
    pub items: BTreeMap<DbKey, ItemHistory>,
    pub latest_buyouts: BTreeMap<DbKey, Copper>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ItemHistory {
    pub scans: BTreeMap<Timestamp, Copper>,
}

#[cfg(test)]
mod tests {
    use super::{Copper, Faction, ItemId, Timestamp};

    #[test]
    fn the_newtypes_stop_at_the_exact_integer_limit() {
        assert_eq!(Copper::new(1 << 53).map(Copper::get), Some(1 << 53));
        assert_eq!(Copper::new((1 << 53) + 1), None);
        assert_eq!(Timestamp::new((1 << 53) + 1), None);
        assert_eq!(ItemId::new((1 << 53) + 1), None);
    }

    #[test]
    fn faction_names_round_trip() {
        for faction in [
            Faction::Alliance,
            Faction::Horde,
            Faction::Neutral,
            Faction::Unknown,
        ] {
            assert_eq!(Faction::from_name(faction.name()), Some(faction));
        }

        assert_eq!(Faction::from_name("alliance"), None);
    }
}
