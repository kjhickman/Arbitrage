use std::{collections::BTreeMap, fmt};

use serde::{Deserialize, Deserializer, Serialize, Serializer, de};

use crate::payload::Scan;

/// Lua numbers and JSON numbers both land in a double, so larger integers are not exact.
const MAX_EXACT: u64 = 1 << 53;

macro_rules! exact_u64_newtype {
    ($name:ident) => {
        #[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord)]
        pub struct $name(u64);

        impl $name {
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

        impl Serialize for $name {
            fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_u64(self.0)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                Ok(Self(exact_u64(deserializer)?))
            }
        }
    };
}

exact_u64_newtype!(Timestamp);
exact_u64_newtype!(Copper);
exact_u64_newtype!(ItemId);
exact_u64_newtype!(Count);

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
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

    /// Whether the key names a random-enchant variant, `equip:<itemId>:<variantId>`.
    #[must_use]
    pub fn is_variant(&self) -> bool {
        self.0.starts_with("equip:")
    }

    /// The item ID a key prices: the key itself, or a variant's item.
    #[must_use]
    pub fn item_id(&self) -> Option<ItemId> {
        let digits = match self.0.strip_prefix("equip:") {
            Some(rest) => rest.split_once(':')?.0,
            None => self.as_str(),
        };
        if digits.is_empty()
            || digits.starts_with('0')
            || !digits.bytes().all(|b| b.is_ascii_digit())
        {
            return None;
        }
        digits.parse().ok().and_then(ItemId::new)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
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
    /// The number `GetCurrentRegion()` returns, since realm names repeat across regions.
    pub region: u32,
    pub markets: BTreeMap<Faction, Market>,
    pub vendor_prices: BTreeMap<String, BTreeMap<ItemId, Copper>>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Market {
    pub last_played: Option<Timestamp>,
    /// Oldest first.
    pub scans: Vec<Scan>,
}

fn exact_u64<'de, D: Deserializer<'de>>(deserializer: D) -> Result<u64, D::Error> {
    struct Exact;

    impl de::Visitor<'_> for Exact {
        type Value = u64;

        fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("an exact non-negative integer")
        }

        fn visit_u64<E: de::Error>(self, value: u64) -> Result<u64, E> {
            if value <= MAX_EXACT {
                Ok(value)
            } else {
                Err(E::custom("an exact non-negative integer"))
            }
        }

        fn visit_str<E: de::Error>(self, text: &str) -> Result<u64, E> {
            let value = text
                .parse::<u64>()
                .map_err(|_| E::custom("an exact non-negative integer"))?;
            if text == value.to_string() && value <= MAX_EXACT {
                Ok(value)
            } else {
                Err(E::custom("an exact non-negative integer"))
            }
        }
    }

    deserializer.deserialize_any(Exact)
}

#[cfg(test)]
mod tests {
    use super::{Copper, DbKey, Faction, ItemId, Timestamp};

    #[test]
    fn the_newtypes_stop_at_the_exact_integer_limit() {
        assert_eq!(Copper::new(1 << 53).map(Copper::get), Some(1 << 53));
        assert_eq!(Copper::new((1 << 53) + 1), None);
        assert_eq!(Timestamp::new((1 << 53) + 1), None);
        assert_eq!(ItemId::new((1 << 53) + 1), None);
    }

    #[test]
    fn keys_name_their_item_id() {
        assert_eq!(DbKey::new("2589").item_id(), ItemId::new(2_589));
        assert_eq!(DbKey::new("equip:9868:-18").item_id(), ItemId::new(9_868));
        for unnamed in [
            "",
            "0",
            "02589",
            "+2589",
            "equip:",
            "equip:9868",
            "equip:x:1",
            "bad",
        ] {
            assert_eq!(DbKey::new(unnamed).item_id(), None, "{unnamed}");
        }
        assert!(DbKey::new("equip:9868:-18").is_variant());
        assert!(!DbKey::new("9868").is_variant());
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
