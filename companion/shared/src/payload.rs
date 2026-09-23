use std::{collections::BTreeMap, fmt};

use serde_json::{Map, Number, Value};

use crate::{
    SCHEMA_VERSION,
    database::{Copper, Database, DbKey, Faction, ItemHistory, ItemId, Market, Realm, Timestamp},
};

const PAYLOAD: &str = "the payload";
const DATABASE: &str = "the database";

/// The body of a sync request and of the sync response that answers it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncPayload {
    pub database: Database,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PayloadError {
    Syntax(String),
    UnsupportedSchema(Option<u64>),
    Malformed(String),
}

impl fmt::Display for PayloadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Syntax(detail) => write!(formatter, "the payload is not JSON: {detail}"),
            Self::UnsupportedSchema(Some(schema)) => {
                write!(
                    formatter,
                    "the payload is schema {schema}, not {SCHEMA_VERSION}"
                )
            }
            Self::UnsupportedSchema(None) => {
                write!(formatter, "the payload has no schema")
            }
            Self::Malformed(detail) => write!(formatter, "the payload is malformed: {detail}"),
        }
    }
}

impl SyncPayload {
    /// # Errors
    ///
    /// Returns [`PayloadError::Syntax`] when `text` is not JSON,
    /// [`PayloadError::UnsupportedSchema`] when it carries another schema, and
    /// [`PayloadError::Malformed`] when it does not match this schema.
    pub fn from_json(text: &str) -> Result<Self, PayloadError> {
        let root = serde_json::from_str::<Value>(text)
            .map_err(|error| PayloadError::Syntax(error.to_string()))?;
        let root = object(&root, PAYLOAD)?;

        // The schema decides which reader owns the body, so it is read before anything else.
        match root.get("schema").and_then(Value::as_u64) {
            Some(schema) if schema == u64::from(SCHEMA_VERSION) => {}
            other => return Err(PayloadError::UnsupportedSchema(other)),
        }

        reject_unknown(root, &["schema", "database"], PAYLOAD)?;

        Ok(Self {
            database: decode_database(field(root, "database", PAYLOAD)?)?,
        })
    }

    #[must_use]
    pub fn to_json(&self) -> String {
        let mut root = Map::new();
        root.insert("schema".to_owned(), number(u64::from(SCHEMA_VERSION)));
        root.insert("database".to_owned(), encode_database(&self.database));
        Value::Object(root).to_string()
    }
}

fn decode_database(value: &Value) -> Result<Database, PayloadError> {
    let table = object(value, DATABASE)?;
    reject_unknown(table, &["lastReplicateScan", "realms"], DATABASE)?;

    Ok(Database {
        last_replicate_scan: optional_timestamp(table, "lastReplicateScan", DATABASE)?,
        realms: collect(
            table_field(table, "realms", DATABASE)?,
            |name| Some(name.to_owned()),
            decode_realm,
            "realms",
        )?,
    })
}

fn decode_realm(value: &Value, name: &str) -> Result<Realm, PayloadError> {
    let what = format!("realm {name}");
    let table = object(value, &what)?;
    reject_unknown(table, &["markets", "vendorPrices"], &what)?;

    Ok(Realm {
        markets: collect(
            table_field(table, "markets", &what)?,
            Faction::from_name,
            decode_market,
            "markets",
        )?,
        vendor_prices: collect(
            table_field(table, "vendorPrices", &what)?,
            |faction| Some(faction.to_owned()),
            decode_vendor_prices,
            "vendorPrices",
        )?,
    })
}

fn decode_vendor_prices(
    value: &Value,
    faction: &str,
) -> Result<BTreeMap<ItemId, Copper>, PayloadError> {
    let what = format!("vendor prices for {faction}");

    collect(
        object(value, &what)?,
        |key| canonical(key).and_then(ItemId::new),
        |price, _| copper(price, &what),
        &what,
    )
}

fn decode_market(value: &Value, faction: &str) -> Result<Market, PayloadError> {
    let what = format!("the {faction} market");
    let table = object(value, &what)?;
    reject_unknown(table, &["lastScan", "items", "latestBuyouts"], &what)?;

    Ok(Market {
        last_scan: optional_timestamp(table, "lastScan", &what)?,
        items: collect(
            table_field(table, "items", &what)?,
            |key| Some(DbKey::new(key)),
            decode_item,
            "items",
        )?,
        latest_buyouts: collect(
            table_field(table, "latestBuyouts", &what)?,
            |key| Some(DbKey::new(key)),
            |price, _| copper(price, "latestBuyouts"),
            "latestBuyouts",
        )?,
    })
}

fn decode_item(value: &Value, db_key: &str) -> Result<ItemHistory, PayloadError> {
    let what = format!("item {db_key}");
    let table = object(value, &what)?;
    reject_unknown(table, &["scans"], &what)?;

    Ok(ItemHistory {
        scans: collect(
            table_field(table, "scans", &what)?,
            |key| canonical(key).and_then(Timestamp::new),
            |price, _| copper(price, &what),
            &what,
        )?,
    })
}

fn collect<K, V>(
    table: &Map<String, Value>,
    key_of: impl Fn(&str) -> Option<K>,
    value_of: impl Fn(&Value, &str) -> Result<V, PayloadError>,
    what: &str,
) -> Result<BTreeMap<K, V>, PayloadError>
where
    K: Ord,
{
    let mut out = BTreeMap::new();

    for (key, value) in table {
        let parsed = key_of(key).ok_or_else(|| malformed(what, &format!("{key} is not a key")))?;
        out.insert(parsed, value_of(value, key)?);
    }

    Ok(out)
}

/// The encoder rewrites the key from the number, so only a canonical spelling round-trips.
fn canonical(key: &str) -> Option<u64> {
    let value: u64 = key.parse().ok()?;
    (value.to_string() == key).then_some(value)
}

fn optional_timestamp(
    table: &Map<String, Value>,
    name: &str,
    what: &str,
) -> Result<Option<Timestamp>, PayloadError> {
    table
        .get(name)
        .map(|value| {
            value
                .as_u64()
                .and_then(Timestamp::new)
                .ok_or_else(|| malformed(what, &format!("{name} is not an exact timestamp")))
        })
        .transpose()
}

fn copper(value: &Value, what: &str) -> Result<Copper, PayloadError> {
    value
        .as_u64()
        .and_then(Copper::new)
        .ok_or_else(|| malformed(what, "a price is not an exact non-negative integer"))
}

fn object<'a>(value: &'a Value, what: &str) -> Result<&'a Map<String, Value>, PayloadError> {
    value
        .as_object()
        .ok_or_else(|| malformed(what, "the value is not an object"))
}

fn field<'a>(
    table: &'a Map<String, Value>,
    name: &str,
    what: &str,
) -> Result<&'a Value, PayloadError> {
    table
        .get(name)
        .ok_or_else(|| malformed(what, &format!("{name} is missing")))
}

fn table_field<'a>(
    table: &'a Map<String, Value>,
    name: &str,
    what: &str,
) -> Result<&'a Map<String, Value>, PayloadError> {
    object(field(table, name, what)?, name)
}

fn reject_unknown(
    table: &Map<String, Value>,
    known: &[&str],
    what: &str,
) -> Result<(), PayloadError> {
    table
        .keys()
        .find(|key| !known.contains(&key.as_str()))
        .map_or(Ok(()), |key| {
            Err(malformed(what, &format!("{key} is not a known key")))
        })
}

fn malformed(what: &str, detail: &str) -> PayloadError {
    PayloadError::Malformed(format!("{what}: {detail}"))
}

fn encode_database(database: &Database) -> Value {
    let mut table = Map::new();

    if let Some(last_replicate_scan) = database.last_replicate_scan {
        table.insert(
            "lastReplicateScan".to_owned(),
            number(last_replicate_scan.get()),
        );
    }
    table.insert(
        "realms".to_owned(),
        encode_map(&database.realms, Clone::clone, encode_realm),
    );

    Value::Object(table)
}

fn encode_realm(realm: &Realm) -> Value {
    let mut table = Map::new();

    table.insert(
        "markets".to_owned(),
        encode_map(
            &realm.markets,
            |faction| faction.name().to_owned(),
            encode_market,
        ),
    );
    table.insert(
        "vendorPrices".to_owned(),
        encode_map(&realm.vendor_prices, Clone::clone, |prices| {
            encode_map(
                prices,
                |item| item.get().to_string(),
                |price| number(price.get()),
            )
        }),
    );

    Value::Object(table)
}

fn encode_market(market: &Market) -> Value {
    let mut table = Map::new();

    if let Some(last_scan) = market.last_scan {
        table.insert("lastScan".to_owned(), number(last_scan.get()));
    }
    table.insert(
        "items".to_owned(),
        encode_map(&market.items, |key| key.as_str().to_owned(), encode_item),
    );
    table.insert(
        "latestBuyouts".to_owned(),
        encode_map(
            &market.latest_buyouts,
            |key| key.as_str().to_owned(),
            |price| number(price.get()),
        ),
    );

    Value::Object(table)
}

fn encode_item(history: &ItemHistory) -> Value {
    let mut table = Map::new();

    table.insert(
        "scans".to_owned(),
        encode_map(
            &history.scans,
            |at| at.get().to_string(),
            |price| number(price.get()),
        ),
    );

    Value::Object(table)
}

fn encode_map<K, V>(
    source: &BTreeMap<K, V>,
    key_of: impl Fn(&K) -> String,
    value_of: impl Fn(&V) -> Value,
) -> Value {
    Value::Object(
        source
            .iter()
            .map(|(key, value)| (key_of(key), value_of(value)))
            .collect(),
    )
}

fn number(value: u64) -> Value {
    Value::Number(Number::from(value))
}

#[cfg(test)]
mod tests {
    use super::{PayloadError, SyncPayload};
    use crate::database::{
        Copper, Database, DbKey, Faction, ItemHistory, ItemId, Market, Realm, Timestamp,
    };
    use std::collections::BTreeMap;

    fn sample() -> SyncPayload {
        let market = Market {
            last_scan: Timestamp::new(1_700_000_100),
            items: BTreeMap::from([(
                DbKey::new("2589"),
                ItemHistory {
                    scans: BTreeMap::from([(
                        Timestamp::new(1_700_000_100).unwrap(),
                        Copper::new(1_234).unwrap(),
                    )]),
                },
            )]),
            latest_buyouts: BTreeMap::from([(DbKey::new("2589"), Copper::new(1_234).unwrap())]),
        };

        let realm = Realm {
            markets: BTreeMap::from([(Faction::Alliance, market)]),
            vendor_prices: BTreeMap::from([(
                "Alliance".to_owned(),
                BTreeMap::from([(ItemId::new(2_589).unwrap(), Copper::new(100).unwrap())]),
            )]),
        };

        SyncPayload {
            database: Database {
                last_replicate_scan: Timestamp::new(1_700_000_000),
                realms: BTreeMap::from([("Whitemane".to_owned(), realm)]),
            },
        }
    }

    const SAMPLE_JSON: &str = concat!(
        r#"{"database":{"lastReplicateScan":1700000000,"realms":{"Whitemane":{"markets":"#,
        r#"{"Alliance":{"items":{"2589":{"scans":{"1700000100":1234}}},"#,
        r#""lastScan":1700000100,"latestBuyouts":{"2589":1234}}},"#,
        r#""vendorPrices":{"Alliance":{"2589":100}}}}},"schema":1}"#
    );

    #[test]
    fn encodes_the_literal_document_and_reads_it_back() {
        let payload = sample();

        assert_eq!(payload.to_json(), SAMPLE_JSON);
        assert_eq!(SyncPayload::from_json(SAMPLE_JSON), Ok(payload));
    }

    #[test]
    fn an_empty_database_round_trips() {
        let empty = SyncPayload::default();

        assert_eq!(empty.to_json(), r#"{"database":{"realms":{}},"schema":1}"#);
        assert_eq!(SyncPayload::from_json(&empty.to_json()), Ok(empty));
    }

    #[test]
    fn a_future_schema_is_rejected_before_the_body() {
        assert_eq!(
            SyncPayload::from_json(r#"{"schema":2,"database":"not even an object"}"#),
            Err(PayloadError::UnsupportedSchema(Some(2)))
        );
        assert_eq!(
            SyncPayload::from_json(r#"{"database":{"realms":{}}}"#),
            Err(PayloadError::UnsupportedSchema(None))
        );
        assert_eq!(
            SyncPayload::from_json(r#"{"schema":"1","database":{"realms":{}}}"#),
            Err(PayloadError::UnsupportedSchema(None))
        );
    }

    #[test]
    fn only_canonical_decimal_map_keys_are_accepted() {
        for spelling in ["02589", "+2589", " 2589", "2589.0", "0x2589"] {
            assert!(
                matches!(
                    SyncPayload::from_json(&vendor_price_document(spelling, "100")),
                    Err(PayloadError::Malformed(_))
                ),
                "{spelling} should not be a vendor price key"
            );
        }

        for spelling in ["01700000100", "+1700000100"] {
            assert!(
                matches!(
                    SyncPayload::from_json(&scan_document(spelling, "1234")),
                    Err(PayloadError::Malformed(_))
                ),
                "{spelling} should not be a scan key"
            );
        }

        assert!(SyncPayload::from_json(&vendor_price_document("2589", "100")).is_ok());
        assert!(SyncPayload::from_json(&scan_document("1700000100", "1234")).is_ok());
    }

    #[test]
    fn keys_and_values_past_the_exact_integer_limit_are_rejected() {
        let past = (1_u64 << 53) + 1;
        let cases = [
            vendor_price_document(&past.to_string(), "100"),
            vendor_price_document("2589", &past.to_string()),
            scan_document(&past.to_string(), "1234"),
            scan_document("1700000100", &past.to_string()),
        ];

        for document in cases {
            assert!(
                matches!(
                    SyncPayload::from_json(&document),
                    Err(PayloadError::Malformed(_))
                ),
                "{document} should be rejected"
            );
        }
    }

    #[test]
    fn non_integer_values_and_unknown_keys_are_rejected() {
        assert!(matches!(
            SyncPayload::from_json(&scan_document("1700000100", "12.5")),
            Err(PayloadError::Malformed(_))
        ));
        assert!(matches!(
            SyncPayload::from_json(&scan_document("1700000100", "-1")),
            Err(PayloadError::Malformed(_))
        ));
        assert!(matches!(
            SyncPayload::from_json(r#"{"schema":1,"database":{"realms":{},"extra":1}}"#),
            Err(PayloadError::Malformed(_))
        ));
        assert!(matches!(
            SyncPayload::from_json("not json"),
            Err(PayloadError::Syntax(_))
        ));
    }

    fn vendor_price_document(key: &str, price: &str) -> String {
        format!(
            r#"{{"schema":1,"database":{{"realms":{{"Whitemane":{{"markets":{{}},"vendorPrices":{{"Alliance":{{"{key}":{price}}}}}}}}}}}}}"#
        )
    }

    fn scan_document(key: &str, price: &str) -> String {
        format!(
            r#"{{"schema":1,"database":{{"realms":{{"Whitemane":{{"markets":{{"Alliance":{{"items":{{"2589":{{"scans":{{"{key}":{price}}}}}}},"latestBuyouts":{{}}}}}},"vendorPrices":{{}}}}}}}}}}"#
        )
    }
}
