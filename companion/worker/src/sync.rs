use arbitrage_shared::{Database, PayloadError, SyncPayload, merge};
use worker::{DurableObject, Env, Request, Response, State, durable_object};

pub const ACCOUNT_DATABASES: &str = "ACCOUNT_DATABASES";

const PAYLOAD_STORAGE_KEY: &str = "payload";
pub(crate) const BODY_LIMIT: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApplyError {
    Incoming(PayloadError),
    StoredUnreadable,
}

/// # Errors
///
/// Returns [`ApplyError::Incoming`] when `incoming` fails to parse, and
/// [`ApplyError::StoredUnreadable`] when `stored` is present but unreadable.
pub fn apply_upload(stored: Option<&str>, incoming: &str) -> Result<String, ApplyError> {
    let incoming = SyncPayload::from_json(incoming).map_err(ApplyError::Incoming)?;
    let stored_database = match stored {
        None => Database::default(),
        Some(text) => {
            SyncPayload::from_json(text)
                .map_err(|_| ApplyError::StoredUnreadable)?
                .database
        }
    };
    Ok(SyncPayload {
        database: merge(&stored_database, &incoming.database),
    }
    .to_json())
}

#[must_use]
pub(crate) const fn rejection(error: &ApplyError) -> (&'static str, u16) {
    match error {
        ApplyError::Incoming(PayloadError::UnsupportedSchema(_)) => ("Unprocessable Entity", 422),
        ApplyError::Incoming(_) => ("Bad Request", 400),
        ApplyError::StoredUnreadable => ("Internal Server Error", 500),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountKey(String);

impl AccountKey {
    /// Returns `None` when `raw` is empty, longer than 128 bytes, or contains a
    /// character outside ASCII alphanumerics, `-`, and `_`.
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        let safe = raw
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_');
        ((1..=128).contains(&raw.len()) && safe).then(|| Self(raw.to_owned()))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[durable_object]
pub struct AccountDatabase {
    state: State,
}

impl DurableObject for AccountDatabase {
    fn new(state: State, _env: Env) -> Self {
        Self { state }
    }

    async fn fetch(&self, mut req: Request) -> worker::Result<Response> {
        let path = req.url()?.path().to_owned();
        if req.method() != worker::Method::Post || path != "/internal/sync" {
            return Response::error("Not Found", 404);
        }

        let body = req.bytes().await?;
        let Ok(incoming) = std::str::from_utf8(&body) else {
            return Response::error("Bad Request", 400);
        };

        let stored: Option<String> = self.state.storage().get(PAYLOAD_STORAGE_KEY).await?;
        match apply_upload(stored.as_deref(), incoming) {
            Ok(json) => {
                self.state
                    .storage()
                    .put(PAYLOAD_STORAGE_KEY, json.clone())
                    .await?;
                let mut response = Response::ok(json)?;
                response
                    .headers_mut()
                    .set("Content-Type", "application/json")?;
                response.headers_mut().set("Cache-Control", "no-store")?;
                Ok(response)
            }
            Err(error) => {
                let (message, status) = rejection(&error);
                Response::error(message, status)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{AccountKey, ApplyError, apply_upload, rejection};
    use arbitrage_shared::{
        Copper, Database, DbKey, Faction, ItemHistory, Market, PayloadError, Realm, SyncPayload,
        Timestamp,
    };
    use std::collections::BTreeMap;

    fn stored(name: &str, last_scan: u64, item: &str, price: u64) -> Database {
        let at = Timestamp::new(last_scan).expect("the timestamp should be in range");
        let price = Copper::new(price).expect("the price should be in range");
        let market = Market {
            last_scan: Some(at),
            items: BTreeMap::from([(
                DbKey::new(item),
                ItemHistory {
                    scans: BTreeMap::from([(at, price)]),
                },
            )]),
            latest_buyouts: BTreeMap::from([(DbKey::new(item), price)]),
        };

        Database {
            last_replicate_scan: Some(at),
            realms: BTreeMap::from([(
                name.to_owned(),
                Realm {
                    markets: BTreeMap::from([(Faction::Alliance, market)]),
                    vendor_prices: BTreeMap::new(),
                },
            )]),
        }
    }

    fn payload_json(database: Database) -> String {
        SyncPayload { database }.to_json()
    }

    #[test]
    fn no_stored_payload_keeps_the_uploaded_realm_and_copper() {
        let incoming = payload_json(stored("Whitemane", 1_700_000_100, "2589", 1_234));
        let merged = apply_upload(None, &incoming).expect("upload should succeed");
        let parsed = SyncPayload::from_json(&merged).expect("merged payload should parse");

        assert_eq!(
            parsed.database.realms.keys().collect::<Vec<_>>(),
            vec!["Whitemane"]
        );
        assert_eq!(
            parsed.database.realms["Whitemane"].markets[&Faction::Alliance].latest_buyouts
                [&DbKey::new("2589")],
            Copper::new(1_234).unwrap()
        );
    }

    #[test]
    fn a_second_realm_upload_keeps_both_realms_and_the_first_copper() {
        let first = payload_json(stored("Whitemane", 1_700_000_100, "2589", 1_234));
        let stored_json = apply_upload(None, &first).expect("first upload should succeed");
        let second = payload_json(stored("Faerlina", 1_700_000_000, "4306", 99));
        let merged =
            apply_upload(Some(&stored_json), &second).expect("second upload should succeed");
        let parsed = SyncPayload::from_json(&merged).expect("merged payload should parse");

        assert_eq!(
            parsed.database.realms.keys().collect::<Vec<_>>(),
            vec!["Faerlina", "Whitemane"]
        );
        assert_eq!(
            parsed.database.realms["Whitemane"].markets[&Faction::Alliance].latest_buyouts
                [&DbKey::new("2589")],
            Copper::new(1_234).unwrap()
        );
    }

    #[test]
    fn reapplying_the_success_string_with_the_same_incoming_is_stable() {
        let incoming = payload_json(stored("Whitemane", 1_700_000_100, "2589", 1_234));
        let first = apply_upload(None, &incoming).expect("first upload should succeed");
        let again = apply_upload(Some(&first), &incoming).expect("second upload should succeed");
        let first_db = SyncPayload::from_json(&first)
            .expect("first payload should parse")
            .database;
        let again_db = SyncPayload::from_json(&again)
            .expect("second payload should parse")
            .database;
        assert_eq!(again_db, first_db);
    }

    #[test]
    fn unsupported_schema_is_not_collapsed() {
        assert_eq!(
            apply_upload(None, r#"{"schema":2,"database":{}}"#),
            Err(ApplyError::Incoming(PayloadError::UnsupportedSchema(Some(
                2
            ))))
        );
    }

    #[test]
    fn unreadable_stored_payload_is_not_treated_as_empty() {
        let incoming = payload_json(stored("Whitemane", 1_700_000_100, "2589", 1_234));
        assert_eq!(
            apply_upload(Some("not-json"), &incoming),
            Err(ApplyError::StoredUnreadable)
        );
    }

    #[test]
    fn rejection_maps_each_kind() {
        assert_eq!(
            rejection(&ApplyError::Incoming(PayloadError::Syntax)),
            ("Bad Request", 400)
        );
        assert_eq!(
            rejection(&ApplyError::Incoming(PayloadError::Malformed)),
            ("Bad Request", 400)
        );
        assert_eq!(
            rejection(&ApplyError::Incoming(PayloadError::UnsupportedSchema(
                Some(2)
            ))),
            ("Unprocessable Entity", 422)
        );
        assert_eq!(
            rejection(&ApplyError::StoredUnreadable),
            ("Internal Server Error", 500)
        );
    }

    #[test]
    fn account_key_accepts_safe_names_only() {
        assert_eq!(AccountKey::parse("42").unwrap().as_str(), "42");
        assert!(AccountKey::parse("").is_none());
        assert!(AccountKey::parse("a/b").is_none());
        assert!(AccountKey::parse(&"a".repeat(129)).is_none());
    }
}
