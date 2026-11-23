use std::collections::BTreeMap;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::{
    SYNC_SCHEMA_VERSION,
    database::{Copper, DbKey, Faction, ItemId, Timestamp},
    import::BuyoutList,
};

/// One realm/faction market's local scans pivoted from `Arbitrage.lua`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketScans {
    pub region: u32,
    pub realm: String,
    pub market: Faction,
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

/// Names a scan by its time and market values, so the same scan from two uploads is one row.
///
/// Buyouts are not part of the name, because the addon drops them from all but its latest scan.
#[must_use]
pub fn scan_id(scan: &Scan) -> String {
    let values =
        serde_json::to_string(&scan.values).unwrap_or_else(|error| unreachable!("{error}"));
    let named = format!("{}:{values}", scan.at.get());
    URL_SAFE_NO_PAD.encode(Sha256::digest(named.as_bytes()))
}

/// One scan stored in the companion's local cache and downloaded incrementally from the worker.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CachedScan {
    pub id: String,
    pub at: Timestamp,
    pub values: BTreeMap<DbKey, Copper>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VendorPrices {
    pub region: u32,
    pub realm: String,
    pub faction: String,
    pub prices: BTreeMap<ItemId, Copper>,
}

/// Summary of one local scan in `Arbitrage.lua`, sent before uploading its prices.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct OwnScanSummary {
    pub at: Timestamp,
    #[serde(default)]
    pub has_buyouts: bool,
}

/// What the companion already holds for one market when asking the worker to sync.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct MarketSyncRequest {
    pub region: u32,
    pub realm: String,
    pub market: Faction,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_played: Option<Timestamp>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub own_scans: Vec<OwnScanSummary>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub have_scans: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub have_item_buyouts_at: Option<Timestamp>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub have_variant_buyouts_at: Option<Timestamp>,
}

/// Request body for `POST /v1/auth/battlenet/attempts/:id/sync`.
///
/// It alone carries a `schema`, so companions that speak an older sync are told to update.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncRequest {
    pub markets: Vec<MarketSyncRequest>,
    pub vendor_prices: Vec<VendorPrices>,
}

/// Change to one buyout list since the timestamp the companion already cached.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BuyoutUpdate {
    #[default]
    Unchanged,
    Clear,
    Replace(BuyoutList),
}

impl BuyoutUpdate {
    #[must_use]
    pub const fn is_unchanged(&self) -> bool {
        matches!(self, Self::Unchanged)
    }
}

/// Incremental sync delta for one market returned by the worker.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct MarketSyncResponse {
    pub region: u32,
    pub realm: String,
    pub market: Faction,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub upload: Vec<Timestamp>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub active_scans: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub scans: Vec<CachedScan>,
    #[serde(default)]
    pub more_scans: bool,
    #[serde(default, skip_serializing_if = "BuyoutUpdate::is_unchanged")]
    pub item_buyouts: BuyoutUpdate,
    #[serde(default, skip_serializing_if = "BuyoutUpdate::is_unchanged")]
    pub variant_buyouts: BuyoutUpdate,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub excluded_random_suffix: Vec<ItemId>,
}

/// Response body for `POST /v1/auth/battlenet/attempts/:id/sync`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SyncResponse {
    pub markets: Vec<MarketSyncResponse>,
    pub vendor_prices: Vec<VendorPrices>,
}

/// Request body for `POST /v1/auth/battlenet/attempts/:id/sync/scan` (one scan at a time).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ScanUploadRequest {
    pub region: u32,
    pub realm: String,
    pub market: Faction,
    pub scan: Scan,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PayloadError {
    Syntax,
    UnsupportedSchema(Option<u64>),
    Malformed,
}

fn classify_json_error(error: &serde_json::Error) -> PayloadError {
    if error.is_syntax() || error.is_eof() {
        PayloadError::Syntax
    } else {
        PayloadError::Malformed
    }
}

#[derive(Deserialize)]
struct SchemaProbe {
    schema: Option<Value>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireSyncRequestRef<'a> {
    schema: u32,
    markets: &'a [MarketSyncRequest],
    vendor_prices: &'a [VendorPrices],
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct WireSyncRequest {
    #[expect(
        dead_code,
        reason = "validated by the schema probe before deserializing"
    )]
    schema: u32,
    markets: Vec<MarketSyncRequest>,
    vendor_prices: Vec<VendorPrices>,
}

impl SyncRequest {
    /// # Errors
    ///
    /// Returns [`PayloadError::Syntax`] when `text` is not JSON,
    /// [`PayloadError::UnsupportedSchema`] when it carries another schema, and
    /// [`PayloadError::Malformed`] when it does not match this schema.
    pub fn from_json(text: &str) -> Result<Self, PayloadError> {
        // The schema decides which reader owns the body, so it is read before anything else.
        let probe: SchemaProbe =
            serde_json::from_str(text).map_err(|error| classify_json_error(&error))?;
        match probe.schema.as_ref().and_then(Value::as_u64) {
            Some(schema) if schema == u64::from(SYNC_SCHEMA_VERSION) => {}
            other => return Err(PayloadError::UnsupportedSchema(other)),
        }

        let wire: WireSyncRequest =
            serde_json::from_str(text).map_err(|error| classify_json_error(&error))?;
        Ok(Self {
            markets: wire.markets,
            vendor_prices: wire.vendor_prices,
        })
    }

    #[must_use]
    pub fn to_json(&self) -> String {
        serde_json::to_string(&WireSyncRequestRef {
            schema: SYNC_SCHEMA_VERSION,
            markets: &self.markets,
            vendor_prices: &self.vendor_prices,
        })
        .unwrap_or_else(|error| unreachable!("{error}"))
    }
}

#[cfg(test)]
mod tests {
    use super::{
        BuyoutUpdate, CachedScan, MarketSyncRequest, MarketSyncResponse, OwnScanSummary,
        PayloadError, Scan, SyncRequest, SyncResponse, VendorPrices, scan_id,
    };
    use crate::{
        database::{Copper, DbKey, Faction, ItemId, Timestamp},
        import::BuyoutList,
    };
    use std::collections::BTreeMap;

    const NOW: u64 = 1_700_000_000;

    fn scan(at: u64, values: &[(&str, u64)], buyouts: Option<&[(&str, u64)]>) -> Scan {
        let prices = |entries: &[(&str, u64)]| {
            entries
                .iter()
                .map(|&(key, value)| (DbKey::new(key), Copper::new(value).unwrap()))
                .collect::<BTreeMap<_, _>>()
        };
        Scan {
            at: Timestamp::new(at).unwrap(),
            values: prices(values),
            buyouts: buyouts.map(prices),
        }
    }

    #[test]
    fn the_same_scan_gets_the_same_id_whatever_its_buyouts() {
        let bare = scan(NOW, &[("2589", 10), ("4306", 20)], None);
        let priced = scan(NOW, &[("2589", 10), ("4306", 20)], Some(&[("2589", 9)]));

        assert_eq!(scan_id(&bare), scan_id(&priced));
        assert_eq!(scan_id(&bare).len(), 43);
    }

    #[test]
    fn a_different_time_or_value_gets_a_different_id() {
        let original = scan(NOW, &[("2589", 10)], None);

        assert_ne!(
            scan_id(&original),
            scan_id(&scan(NOW + 1, &[("2589", 10)], None))
        );
        assert_ne!(
            scan_id(&original),
            scan_id(&scan(NOW, &[("2589", 11)], None))
        );
        assert_ne!(
            scan_id(&original),
            scan_id(&scan(NOW, &[("2590", 10)], None))
        );
    }

    #[test]
    fn sync_request_round_trips() {
        let request = SyncRequest {
            markets: vec![MarketSyncRequest {
                region: 1,
                realm: "PvP".to_owned(),
                market: Faction::Horde,
                last_played: Timestamp::new(1_700_000_000),
                own_scans: vec![OwnScanSummary {
                    at: Timestamp::new(1_700_000_100).unwrap(),
                    has_buyouts: true,
                }],
                have_scans: vec!["tsm:1700000000".to_owned()],
                have_item_buyouts_at: Timestamp::new(1_700_000_000),
                have_variant_buyouts_at: Timestamp::new(1_699_990_000),
            }],
            vendor_prices: vec![VendorPrices {
                region: 1,
                realm: "PvP".to_owned(),
                faction: "Horde".to_owned(),
                prices: BTreeMap::from([(ItemId::new(2_589).unwrap(), Copper::new(100).unwrap())]),
            }],
        };

        let json = request.to_json();
        assert!(json.contains(r#""schema":3"#));
        assert_eq!(SyncRequest::from_json(&json), Ok(request));
    }

    #[test]
    fn sync_response_round_trips_with_buyout_updates() {
        let response = SyncResponse {
            markets: vec![MarketSyncResponse {
                region: 1,
                realm: "PvP".to_owned(),
                market: Faction::Horde,
                upload: vec![Timestamp::new(1_700_000_200).unwrap()],
                active_scans: vec!["tsm:1700000100".to_owned()],
                scans: vec![CachedScan {
                    id: "tsm:1700000100".to_owned(),
                    at: Timestamp::new(1_700_000_100).unwrap(),
                    values: BTreeMap::from([(DbKey::new("2589"), Copper::new(1_234).unwrap())]),
                }],
                more_scans: true,
                item_buyouts: BuyoutUpdate::Replace(BuyoutList {
                    at: Timestamp::new(1_700_000_100).unwrap(),
                    prices: BTreeMap::from([(DbKey::new("2589"), Copper::new(1_100).unwrap())]),
                }),
                variant_buyouts: BuyoutUpdate::Clear,
                excluded_random_suffix: vec![ItemId::new(300_001).unwrap()],
            }],
            vendor_prices: vec![],
        };

        let json = serde_json::to_string(&response).unwrap();
        assert_eq!(
            serde_json::from_str::<SyncResponse>(&json).unwrap(),
            response
        );
    }

    #[test]
    fn another_schema_is_rejected_before_the_body() {
        assert_eq!(
            SyncRequest::from_json(r#"{"schema":2,"markets":"not even an array"}"#),
            Err(PayloadError::UnsupportedSchema(Some(2)))
        );
        assert_eq!(
            SyncRequest::from_json(r#"{"markets":[],"vendorPrices":[]}"#),
            Err(PayloadError::UnsupportedSchema(None))
        );
        assert_eq!(
            SyncRequest::from_json(r#"{"schema":"3","markets":[],"vendorPrices":[]}"#),
            Err(PayloadError::UnsupportedSchema(None))
        );
    }

    #[test]
    fn only_canonical_decimal_map_keys_are_accepted() {
        for spelling in ["02589", "+2589", " 2589", "2589.0", "0x2589"] {
            assert!(
                matches!(
                    SyncRequest::from_json(&vendor_price_document(spelling, "100")),
                    Err(PayloadError::Malformed)
                ),
                "{spelling} should not be a vendor price key"
            );
        }

        assert!(SyncRequest::from_json(&vendor_price_document("2589", "100")).is_ok());
    }

    #[test]
    fn values_past_the_exact_integer_limit_are_rejected() {
        let past = (1_u64 << 53) + 1;
        assert!(matches!(
            SyncRequest::from_json(&vendor_price_document(&past.to_string(), "100")),
            Err(PayloadError::Malformed)
        ));
        assert!(matches!(
            SyncRequest::from_json(&vendor_price_document("2589", &past.to_string())),
            Err(PayloadError::Malformed)
        ));
    }

    #[test]
    fn non_integer_values_unknown_keys_and_syntax_errors_are_classified() {
        assert_eq!(
            SyncRequest::from_json(&vendor_price_document("2589", "12.5")),
            Err(PayloadError::Malformed)
        );
        assert_eq!(
            SyncRequest::from_json(&vendor_price_document("2589", "-1")),
            Err(PayloadError::Malformed)
        );
        assert_eq!(
            SyncRequest::from_json(r#"{"schema":3,"markets":[],"vendorPrices":[],"extra":1}"#),
            Err(PayloadError::Malformed)
        );
        assert_eq!(SyncRequest::from_json("[]"), Err(PayloadError::Malformed));
        assert_eq!(
            SyncRequest::from_json("not json"),
            Err(PayloadError::Syntax)
        );
    }

    fn vendor_price_document(key: &str, price: &str) -> String {
        format!(
            r#"{{"schema":3,"markets":[],"vendorPrices":[{{"region":1,"realm":"Whitemane","faction":"Alliance","prices":{{"{key}":{price}}}}}]}}"#
        )
    }
}
