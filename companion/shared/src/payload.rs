use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    SCHEMA_VERSION,
    database::{Copper, DbKey, Faction, ItemId, Timestamp},
};

/// The body of a sync request and of the sync response that answers it.
///
/// An upload carries the account's own scans for every market it knows; a response carries the
/// combined scans for the markets the worker chose to return.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SyncPayload {
    pub markets: Vec<MarketScans>,
    pub vendor_prices: Vec<VendorPrices>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct MarketScans {
    pub region: u32,
    pub realm: String,
    pub market: Faction,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_played: Option<Timestamp>,
    pub scans: Vec<Scan>,
}

/// One full scan: the market value it computed per item, and its minimum buyouts when known.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Scan {
    pub at: Timestamp,
    pub values: BTreeMap<DbKey, Copper>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub buyouts: Option<BTreeMap<DbKey, Copper>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VendorPrices {
    pub region: u32,
    pub realm: String,
    pub faction: String,
    pub prices: BTreeMap<ItemId, Copper>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PayloadError {
    Syntax,
    UnsupportedSchema(Option<u64>),
    Malformed,
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

        serde_json::from_value(Value::Object(table)).map_err(|_| PayloadError::Malformed)
    }

    #[must_use]
    pub fn to_json(&self) -> String {
        let mut root = serde_json::to_value(self).unwrap_or_else(|error| unreachable!("{error}"));
        if let Value::Object(table) = &mut root {
            table.insert("schema".to_owned(), Value::from(SCHEMA_VERSION));
        }
        root.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::{MarketScans, PayloadError, Scan, SyncPayload, VendorPrices};
    use crate::database::{Copper, DbKey, Faction, ItemId, Timestamp};
    use std::collections::BTreeMap;

    fn sample() -> SyncPayload {
        SyncPayload {
            markets: vec![MarketScans {
                region: 1,
                realm: "Whitemane".to_owned(),
                market: Faction::Alliance,
                last_played: Timestamp::new(1_700_000_000),
                scans: vec![Scan {
                    at: Timestamp::new(1_700_000_100).unwrap(),
                    values: BTreeMap::from([(DbKey::new("2589"), Copper::new(1_234).unwrap())]),
                    buyouts: Some(BTreeMap::from([(
                        DbKey::new("2589"),
                        Copper::new(1_100).unwrap(),
                    )])),
                }],
            }],
            vendor_prices: vec![VendorPrices {
                region: 1,
                realm: "Whitemane".to_owned(),
                faction: "Alliance".to_owned(),
                prices: BTreeMap::from([(ItemId::new(2_589).unwrap(), Copper::new(100).unwrap())]),
            }],
        }
    }

    const SAMPLE_JSON: &str = concat!(
        r#"{"markets":[{"lastPlayed":1700000000,"market":"Alliance","realm":"Whitemane","region":1,"#,
        r#""scans":[{"at":1700000100,"buyouts":{"2589":1100},"values":{"2589":1234}}]}],"#,
        r#""schema":2,"vendorPrices":[{"faction":"Alliance","prices":{"2589":100},"#,
        r#""realm":"Whitemane","region":1}]}"#
    );

    #[test]
    fn encodes_the_literal_document_and_reads_it_back() {
        let payload = sample();

        assert_eq!(payload.to_json(), SAMPLE_JSON);
        assert_eq!(SyncPayload::from_json(SAMPLE_JSON), Ok(payload));
    }

    #[test]
    fn an_empty_payload_round_trips() {
        let empty = SyncPayload::default();

        assert_eq!(
            empty.to_json(),
            r#"{"markets":[],"schema":2,"vendorPrices":[]}"#
        );
        assert_eq!(SyncPayload::from_json(&empty.to_json()), Ok(empty));
    }

    #[test]
    fn another_schema_is_rejected_before_the_body() {
        assert_eq!(
            SyncPayload::from_json(r#"{"schema":1,"database":"not even an object"}"#),
            Err(PayloadError::UnsupportedSchema(Some(1)))
        );
        assert_eq!(
            SyncPayload::from_json(r#"{"markets":[],"vendorPrices":[]}"#),
            Err(PayloadError::UnsupportedSchema(None))
        );
        assert_eq!(
            SyncPayload::from_json(r#"{"schema":"2","markets":[],"vendorPrices":[]}"#),
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

        assert!(SyncPayload::from_json(&vendor_price_document("2589", "100")).is_ok());
    }

    #[test]
    fn values_past_the_exact_integer_limit_are_rejected() {
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
            SyncPayload::from_json(r#"{"schema":2,"markets":[],"vendorPrices":[],"extra":1}"#),
            Err(PayloadError::Malformed)
        ));
        assert!(matches!(
            SyncPayload::from_json(
                r#"{"schema":2,"markets":[{"region":1,"realm":"Whitemane","market":"alliance","scans":[]}],"vendorPrices":[]}"#
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
            r#"{{"schema":2,"markets":[],"vendorPrices":[{{"region":1,"realm":"Whitemane","faction":"Alliance","prices":{{"{key}":{price}}}}}]}}"#
        )
    }

    fn scan_document(at: &str, price: &str) -> String {
        format!(
            r#"{{"schema":2,"markets":[{{"region":1,"realm":"Whitemane","market":"Alliance","scans":[{{"at":{at},"values":{{"2589":{price}}}}}]}}],"vendorPrices":[]}}"#
        )
    }
}
