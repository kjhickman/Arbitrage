use crate::auth::session::{AuthPhase, AuthSessionRecord, SCHEMA_VERSION};
use crate::auth::types::secrets_equal;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PersistError {
    Malformed,
    UnsupportedSchemaVersion,
}

pub fn encode(record: &AuthSessionRecord) -> Result<Vec<u8>, PersistError> {
    serde_json::to_vec(record).map_err(|_| PersistError::Malformed)
}

pub fn decode(bytes: &[u8]) -> Result<AuthSessionRecord, PersistError> {
    let record: AuthSessionRecord =
        serde_json::from_slice(bytes).map_err(|_| PersistError::Malformed)?;
    if record.schema_version != SCHEMA_VERSION {
        return Err(PersistError::UnsupportedSchemaVersion);
    }
    validate_persisted(&record)?;
    Ok(record)
}

fn validate_persisted(record: &AuthSessionRecord) -> Result<(), PersistError> {
    if let Some(state) = &record.oauth_state
        && (state.attempt_id() != record.attempt_id
            || !secrets_equal(
                &state.callback_secret().sha256(),
                &record.callback_key_sha256,
            ))
    {
        return Err(PersistError::Malformed);
    }

    match &record.phase {
        AuthPhase::Pending => {
            if record.oauth_state.is_none() || record.pkce_verifier.is_none() {
                return Err(PersistError::Malformed);
            }
        }
        AuthPhase::Exchanging {
            authorization_code, ..
        } => {
            if record.oauth_state.is_some()
                || record.pkce_verifier.is_none()
                || authorization_code.as_str().is_empty()
            {
                return Err(PersistError::Malformed);
            }
        }
        AuthPhase::Authorized { account, .. } => {
            if record.pkce_verifier.is_some()
                || record.oauth_state.is_some()
                || account.id.is_empty()
                || account.battletag.is_empty()
            {
                return Err(PersistError::Malformed);
            }
        }
        AuthPhase::Denied { .. }
        | AuthPhase::Failed { .. }
        | AuthPhase::Expired { .. }
        | AuthPhase::Revoked { .. } => {
            if record.pkce_verifier.is_some() || record.oauth_state.is_some() {
                return Err(PersistError::Malformed);
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::battlenet::{AccountSummary, ProviderError};
    use crate::auth::callback::validate_callback_query;
    use crate::auth::oauth_state::OAuthState;
    use crate::auth::origin::PublicOrigin;
    use crate::auth::pkce::PkceVerifier;
    use crate::auth::session::BeginMaterial;
    use crate::auth::types::{AttemptId, CallbackSecret, Timestamp, TraySecret};

    const STORED_PENDING: &str = concat!(
        r#"{"schema_version":1,"attempt_id":"AQEBAQEBAQEBAQEBAQEBAQ","#,
        r#""tray_key_sha256":"S7Bvjk46dxXSAdVz0KpCN2LlXavWGiwCJ4-lbMbSlOA","#,
        r#""callback_key_sha256":"dYd7tB05O1-4RVzmDs2N2gAdBjFklrFN-n-JVlbuyko","#,
        r#""oauth_state":{"attempt_id":"AQEBAQEBAQEBAQEBAQEBAQ","#,
        r#""callback_secret":"AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI"},"#,
        r#""pkce_verifier":"AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM","#,
        r#""created_at":1000,"authorize_until":61000,"phase":{"kind":"pending"}}"#
    );
    const STORED_EXCHANGING: &str = concat!(
        r#"{"schema_version":1,"attempt_id":"AQEBAQEBAQEBAQEBAQEBAQ","#,
        r#""tray_key_sha256":"S7Bvjk46dxXSAdVz0KpCN2LlXavWGiwCJ4-lbMbSlOA","#,
        r#""callback_key_sha256":"dYd7tB05O1-4RVzmDs2N2gAdBjFklrFN-n-JVlbuyko","#,
        r#""oauth_state":null,"pkce_verifier":"AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM","#,
        r#""created_at":1000,"authorize_until":61000,"#,
        r#""phase":{"kind":"exchanging","authorization_code":"one-time-code","received_at":1500}}"#
    );
    const STORED_AUTHORIZED: &str = concat!(
        r#"{"schema_version":1,"attempt_id":"AQEBAQEBAQEBAQEBAQEBAQ","#,
        r#""tray_key_sha256":"S7Bvjk46dxXSAdVz0KpCN2LlXavWGiwCJ4-lbMbSlOA","#,
        r#""callback_key_sha256":"dYd7tB05O1-4RVzmDs2N2gAdBjFklrFN-n-JVlbuyko","#,
        r#""oauth_state":null,"pkce_verifier":null,"created_at":1000,"authorize_until":61000,"#,
        r#""phase":{"kind":"authorized","account":{"id":"42","battletag":"Player#42"},"#,
        r#""authorized_at":1600}}"#
    );
    const STORED_REVOKED: &str = concat!(
        r#"{"schema_version":1,"attempt_id":"AQEBAQEBAQEBAQEBAQEBAQ","#,
        r#""tray_key_sha256":"S7Bvjk46dxXSAdVz0KpCN2LlXavWGiwCJ4-lbMbSlOA","#,
        r#""callback_key_sha256":"dYd7tB05O1-4RVzmDs2N2gAdBjFklrFN-n-JVlbuyko","#,
        r#""oauth_state":null,"pkce_verifier":null,"created_at":1000,"authorize_until":61000,"#,
        r#""phase":{"kind":"revoked","at":2000}}"#
    );

    fn fixture() -> (PublicOrigin, AuthSessionRecord, BeginMaterial, TraySecret) {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let tray = TraySecret::from_bytes([7; 32]);
        let (record, material) = AuthSessionRecord::begin(
            AttemptId([1; 16]),
            tray.sha256(),
            CallbackSecret::from_bytes([2; 32]),
            PkceVerifier::from_entropy([3; 32]),
            Timestamp(1_000),
            60_000,
        );
        (origin, record, material, tray)
    }

    fn into_exchanging(
        mut record: AuthSessionRecord,
        material: &BeginMaterial,
    ) -> AuthSessionRecord {
        let state = material.state.encode();
        let callback =
            validate_callback_query(&[("code", "one-time-code"), ("state", &state)]).unwrap();
        record.consume_callback(callback, Timestamp(1_500)).unwrap();
        record
    }

    fn encoded(record: &AuthSessionRecord) -> String {
        String::from_utf8(encode(record).unwrap()).unwrap()
    }

    #[test]
    fn stored_records_decode_and_encode_to_the_same_bytes() {
        let (_origin, pending, material, tray) = fixture();
        let mut authorized = into_exchanging(pending.clone(), &material);
        authorized.apply_exchange_outcome(
            Ok(AccountSummary {
                id: "42".to_owned(),
                battletag: "Player#42".to_owned(),
            }),
            Timestamp(1_600),
        );
        let mut revoked = pending.clone();
        revoked
            .revoke(AttemptId([1; 16]), &tray, Timestamp(2_000))
            .unwrap();

        assert_eq!(encoded(&pending), STORED_PENDING);
        assert_eq!(
            encoded(&into_exchanging(pending, &material)),
            STORED_EXCHANGING
        );
        assert_eq!(encoded(&authorized), STORED_AUTHORIZED);
        assert_eq!(encoded(&revoked), STORED_REVOKED);

        for stored in [
            STORED_PENDING,
            STORED_EXCHANGING,
            STORED_AUTHORIZED,
            STORED_REVOKED,
        ] {
            assert_eq!(encoded(&decode(stored.as_bytes()).unwrap()), stored);
        }
    }

    #[test]
    fn round_trips_pending_with_literal_verifier() {
        let (_origin, record, material, tray) = fixture();
        let bytes = encode(&record).unwrap();
        let decoded = decode(&bytes).unwrap();

        assert!(matches!(decoded.phase, AuthPhase::Pending));
        assert_eq!(decoded.attempt_id, AttemptId([1; 16]));
        assert_eq!(decoded.schema_version, SCHEMA_VERSION);
        assert_eq!(decoded.created_at, Timestamp(1_000));
        assert_eq!(decoded.authorize_until, Timestamp(61_000));
        assert_eq!(decoded.tray_key_sha256, tray.sha256());
        assert_eq!(
            decoded.pkce_verifier.as_ref().map(PkceVerifier::as_str),
            Some(material.pkce_verifier.as_str())
        );
        assert_eq!(
            decoded.oauth_state.as_ref().map(OAuthState::encode),
            Some(material.state.encode())
        );
        let again = decoded.begin_idempotent(&tray.sha256()).unwrap();
        assert_eq!(
            again.pkce_verifier.as_str(),
            material.pkce_verifier.as_str()
        );
        assert_eq!(again.state.encode(), material.state.encode());
    }

    #[test]
    fn round_trips_exchanging_preserves_code_and_verifier_for_retry() {
        let (origin, record, material, _) = fixture();
        let record = into_exchanging(record, &material);
        let bytes = encode(&record).unwrap();
        let mut decoded = decode(&bytes).unwrap();

        match &decoded.phase {
            AuthPhase::Exchanging {
                authorization_code,
                received_at,
            } => {
                assert_eq!(authorization_code.as_str(), "one-time-code");
                assert_eq!(*received_at, Timestamp(1_500));
            }
            other => panic!("expected exchanging, got {other:?}"),
        }
        assert_eq!(
            decoded.pkce_verifier.as_ref().map(PkceVerifier::as_str),
            Some(material.pkce_verifier.as_str())
        );
        assert!(decoded.oauth_state.is_none());

        let exchange = decoded.exchange_material(&origin).unwrap();
        assert_eq!(exchange.code.as_str(), "one-time-code");
        assert_eq!(exchange.code_verifier, material.pkce_verifier.as_str());

        decoded.apply_exchange_outcome(Err(ProviderError::Unavailable), Timestamp(1_600));
        assert!(matches!(decoded.phase, AuthPhase::Exchanging { .. }));
        assert_eq!(
            decoded.exchange_material(&origin).unwrap().code.as_str(),
            "one-time-code"
        );
        assert_eq!(
            decoded.pkce_verifier.as_ref().map(PkceVerifier::as_str),
            Some(material.pkce_verifier.as_str())
        );
    }

    #[test]
    fn round_trips_authorized_with_account_and_token_presence() {
        let (origin, record, material, _) = fixture();
        let mut record = into_exchanging(record, &material);
        record.apply_exchange_outcome(
            Ok(AccountSummary {
                id: "42".to_owned(),
                battletag: "Player#42".to_owned(),
            }),
            Timestamp(1_600),
        );

        let bytes = encode(&record).unwrap();
        let decoded = decode(&bytes).unwrap();
        match &decoded.phase {
            AuthPhase::Authorized {
                account,
                authorized_at,
            } => {
                assert_eq!(account.id, "42");
                assert_eq!(account.battletag, "Player#42");
                assert_eq!(*authorized_at, Timestamp(1_600));
            }
            other => panic!("expected authorized, got {other:?}"),
        }
        let stored = String::from_utf8(bytes).unwrap();
        assert!(!stored.contains("access_token"));
        assert!(!stored.contains("refresh_token"));
        assert!(decoded.pkce_verifier.is_none());
        assert!(decoded.oauth_state.is_none());
        assert!(decoded.exchange_material(&origin).is_none());

        let debug = format!("{decoded:?}");
        assert!(!debug.contains("access-secret"));
        assert!(!debug.contains("refresh-secret"));
        assert!(!debug.contains("one-time-code"));
        assert!(!debug.contains(material.pkce_verifier.as_str()));
    }

    #[test]
    fn round_trips_denied_failed_expired_and_revoked() {
        let (origin, pending, material, tray) = fixture();

        let mut denied = pending.clone();
        let state = material.state.encode();
        let callback =
            validate_callback_query(&[("error", "access_denied"), ("state", &state)]).unwrap();
        denied.consume_callback(callback, Timestamp(1_500)).unwrap();
        let denied = decode(&encode(&denied).unwrap()).unwrap();
        match &denied.phase {
            AuthPhase::Denied { at } => assert_eq!(*at, Timestamp(1_500)),
            other => panic!("expected denied, got {other:?}"),
        }
        assert!(denied.pkce_verifier.is_none());

        let mut failed = into_exchanging(pending.clone(), &material);
        failed.apply_exchange_outcome(Err(ProviderError::InvalidGrant), Timestamp(1_700));
        let failed = decode(&encode(&failed).unwrap()).unwrap();
        match &failed.phase {
            AuthPhase::Failed { at } => assert_eq!(*at, Timestamp(1_700)),
            other => panic!("expected failed, got {other:?}"),
        }
        assert!(failed.pkce_verifier.is_none());
        assert!(failed.exchange_material(&origin).is_none());

        let mut expired = pending.clone();
        let callback =
            validate_callback_query(&[("code", "late-code"), ("state", &state)]).unwrap();
        assert_eq!(
            expired.consume_callback(callback, Timestamp(70_000)),
            Err(crate::auth::session::ConsumeError::Expired)
        );
        let expired = decode(&encode(&expired).unwrap()).unwrap();
        match &expired.phase {
            AuthPhase::Expired { at } => assert_eq!(*at, Timestamp(70_000)),
            other => panic!("expected expired, got {other:?}"),
        }

        let mut revoked = pending;
        revoked
            .revoke(AttemptId([1; 16]), &tray, Timestamp(2_000))
            .unwrap();
        let revoked = decode(&encode(&revoked).unwrap()).unwrap();
        match &revoked.phase {
            AuthPhase::Revoked { at } => assert_eq!(*at, Timestamp(2_000)),
            other => panic!("expected revoked, got {other:?}"),
        }
        assert!(revoked.pkce_verifier.is_none());
        assert!(revoked.oauth_state.is_none());
    }

    #[test]
    fn rejects_unknown_schema_versions_and_truncated_payloads() {
        let (_origin, record, material, _) = fixture();
        let mut bytes = encode(&record).unwrap();
        let json = String::from_utf8(bytes.clone()).unwrap();
        assert!(json.contains("\"schema_version\":1"));
        let bumped = json.replacen("\"schema_version\":1", "\"schema_version\":2", 1);
        assert_eq!(
            decode(bumped.as_bytes()).unwrap_err(),
            PersistError::UnsupportedSchemaVersion
        );

        assert!(!bytes.is_empty());
        bytes.truncate(bytes.len() / 2);
        assert_eq!(decode(&bytes).unwrap_err(), PersistError::Malformed);
        assert_eq!(decode(b"").unwrap_err(), PersistError::Malformed);
        assert_eq!(decode(b"{").unwrap_err(), PersistError::Malformed);

        let exchanging = into_exchanging(fixture().1, &material);
        let mut value: serde_json::Value =
            serde_json::from_slice(&encode(&exchanging).unwrap()).unwrap();
        value["pkce_verifier"] = serde_json::Value::Null;
        assert_eq!(
            decode(&serde_json::to_vec(&value).unwrap()).unwrap_err(),
            PersistError::Malformed
        );

        let mut value: serde_json::Value = serde_json::from_str(STORED_PENDING).unwrap();
        value["pkce_verifier"] = serde_json::Value::from("short");
        assert_eq!(
            decode(&serde_json::to_vec(&value).unwrap()).unwrap_err(),
            PersistError::Malformed
        );
        let mut value: serde_json::Value = serde_json::from_str(STORED_PENDING).unwrap();
        value["extra"] = serde_json::Value::from(1);
        assert_eq!(
            decode(&serde_json::to_vec(&value).unwrap()).unwrap_err(),
            PersistError::Malformed
        );
        let mut value: serde_json::Value = serde_json::from_str(STORED_PENDING).unwrap();
        value["attempt_id"] = serde_json::Value::from("AQE");
        assert_eq!(
            decode(&serde_json::to_vec(&value).unwrap()).unwrap_err(),
            PersistError::Malformed
        );

        let debug = format!("{exchanging:?}");
        assert!(!debug.contains("one-time-code"));
        assert!(!debug.contains(material.pkce_verifier.as_str()));
    }
}
