use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{SCHEMA_VERSION, database::Database};

/// The body of a sync request and of the sync response that answers it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncPayload {
    pub database: Database,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PayloadError {
    Syntax,
    UnsupportedSchema(Option<u64>),
    Malformed,
}

#[derive(Serialize)]
struct WireOut<'a> {
    database: &'a Database,
    schema: u32,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireIn {
    database: Database,
}

impl SyncPayload {
    /// # Errors
    ///
    /// Returns [`PayloadError::Syntax`] when `text` is not JSON,
    /// [`PayloadError::UnsupportedSchema`] when it carries another schema, and
    /// [`PayloadError::Malformed`] when it does not match this schema.
    pub fn from_json(text: &str) -> Result<Self, PayloadError> {
        let root: Value = serde_json::from_str(text).map_err(|_| PayloadError::Syntax)?;
        let Value::Object(mut table) = root else {
            return Err(PayloadError::Malformed);
        };

        // The schema decides which reader owns the body, so it is read before anything else.
        match table.remove("schema").as_ref().and_then(Value::as_u64) {
            Some(schema) if schema == u64::from(SCHEMA_VERSION) => {}
            other => return Err(PayloadError::UnsupportedSchema(other)),
        }

        let wire = serde_json::from_value::<WireIn>(Value::Object(table))
            .map_err(|_| PayloadError::Malformed)?;
        Ok(Self {
            database: wire.database,
        })
    }

    #[must_use]
    pub fn to_json(&self) -> String {
        serde_json::to_string(&WireOut {
            database: &self.database,
            schema: SCHEMA_VERSION,
        })
        .unwrap_or_else(|error| unreachable!("{error}"))
    }
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
                    Err(PayloadError::Malformed)
                ),
                "{spelling} should not be a vendor price key"
            );
        }

        for spelling in ["01700000100", "+1700000100"] {
            assert!(
                matches!(
                    SyncPayload::from_json(&scan_document(spelling, "1234")),
                    Err(PayloadError::Malformed)
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
                    Err(PayloadError::Malformed)
                ),
                "{document} should be rejected"
            );
        }
    }

    #[test]
    fn non_integer_values_and_unknown_keys_are_rejected() {
        assert!(matches!(
            SyncPayload::from_json(&scan_document("1700000100", "12.5")),
            Err(PayloadError::Malformed)
        ));
        assert!(matches!(
            SyncPayload::from_json(&scan_document("1700000100", "-1")),
            Err(PayloadError::Malformed)
        ));
        assert!(matches!(
            SyncPayload::from_json(r#"{"schema":1,"database":{"realms":{},"extra":1}}"#),
            Err(PayloadError::Malformed)
        ));
        assert!(matches!(
            SyncPayload::from_json(
                r#"{"schema":1,"database":{"realms":{"Whitemane":{"markets":{"alliance":{"items":{},"latestBuyouts":{}}},"vendorPrices":{}}}}}"#
            ),
            Err(PayloadError::Malformed)
        ));
        assert!(matches!(
            SyncPayload::from_json("not json"),
            Err(PayloadError::Syntax)
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
