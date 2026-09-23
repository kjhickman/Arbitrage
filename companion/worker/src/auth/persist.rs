use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};

use crate::auth::battlenet::{AccountSummary, BattleNetTokenSet, BearerTokenType};
use crate::auth::oauth_state::OAuthState;
use crate::auth::pkce::PkceVerifier;
use crate::auth::session::{AuthPhase, AuthSessionRecord, PersistedParts, SCHEMA_VERSION};
use crate::auth::types::{AttemptId, AuthorizationCode, CallbackSecret, Sha256Digest, Timestamp};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PersistError {
    Malformed,
    UnsupportedSchemaVersion,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WireRecord {
    schema_version: u8,
    attempt_id: String,
    tray_key_sha256: String,
    callback_key_sha256: String,
    oauth_state: Option<WireOAuthState>,
    pkce_verifier: Option<String>,
    created_at: u64,
    authorize_until: u64,
    phase: WirePhase,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WireOAuthState {
    attempt_id: String,
    callback_secret: String,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", deny_unknown_fields)]
enum WirePhase {
    #[serde(rename = "pending")]
    Pending,
    #[serde(rename = "exchanging")]
    Exchanging {
        authorization_code: String,
        received_at: u64,
    },
    #[serde(rename = "authorized")]
    Authorized {
        account: WireAccount,
        tokens: WireTokens,
        authorized_at: u64,
    },
    #[serde(rename = "denied")]
    Denied { at: u64 },
    #[serde(rename = "failed")]
    Failed { retryable: bool, at: u64 },
    #[serde(rename = "expired")]
    Expired { at: u64 },
    #[serde(rename = "revoked")]
    Revoked { at: u64 },
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WireAccount {
    id: String,
    battletag: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WireTokens {
    access_token: String,
    token_type: String,
    access_expires_at: u64,
    refresh_token: Option<String>,
    granted_scopes: String,
}

pub fn encode(record: &AuthSessionRecord) -> Result<Vec<u8>, PersistError> {
    let wire = WireRecord {
        schema_version: record.schema_version(),
        attempt_id: encode_bytes(&record.attempt_id().0),
        tray_key_sha256: encode_bytes(&record.tray_key_sha256().0),
        callback_key_sha256: encode_bytes(&record.callback_key_sha256().0),
        oauth_state: record.oauth_state().map(|state| WireOAuthState {
            attempt_id: encode_bytes(&state.attempt_id().0),
            callback_secret: encode_bytes(state.callback_secret().as_bytes()),
        }),
        pkce_verifier: record
            .pkce_verifier()
            .map(|verifier| verifier.as_str().to_owned()),
        created_at: record.created_at().0,
        authorize_until: record.authorize_until().0,
        phase: encode_phase(record.phase()),
    };
    serde_json::to_vec(&wire).map_err(|_| PersistError::Malformed)
}

pub fn decode(bytes: &[u8]) -> Result<AuthSessionRecord, PersistError> {
    let wire: WireRecord = serde_json::from_slice(bytes).map_err(|_| PersistError::Malformed)?;
    if wire.schema_version != SCHEMA_VERSION {
        return Err(PersistError::UnsupportedSchemaVersion);
    }

    let attempt_id = AttemptId(decode_fixed(&wire.attempt_id)?);
    let tray_key_sha256 = Sha256Digest(decode_fixed(&wire.tray_key_sha256)?);
    let callback_key_sha256 = Sha256Digest(decode_fixed(&wire.callback_key_sha256)?);
    let oauth_state = wire
        .oauth_state
        .map(|state| {
            Ok(OAuthState::new(
                AttemptId(decode_fixed(&state.attempt_id)?),
                CallbackSecret::from_bytes(decode_fixed(&state.callback_secret)?),
            ))
        })
        .transpose()?;
    let pkce_verifier = wire
        .pkce_verifier
        .map(PkceVerifier::from_persisted)
        .transpose()?;
    let phase = decode_phase(wire.phase)?;
    let parts = PersistedParts {
        schema_version: wire.schema_version,
        attempt_id,
        tray_key_sha256,
        callback_key_sha256,
        oauth_state,
        pkce_verifier,
        created_at: Timestamp(wire.created_at),
        authorize_until: Timestamp(wire.authorize_until),
        phase,
    };
    validate_persisted(&parts)?;
    Ok(AuthSessionRecord::from_persisted(parts))
}

fn validate_persisted(parts: &PersistedParts) -> Result<(), PersistError> {
    if let Some(state) = &parts.oauth_state
        && (state.attempt_id() != parts.attempt_id
            || !crate::auth::types::secrets_equal(
                &state.callback_secret().sha256(),
                &parts.callback_key_sha256,
            ))
    {
        return Err(PersistError::Malformed);
    }

    match &parts.phase {
        AuthPhase::Pending => {
            if parts.oauth_state.is_none() || parts.pkce_verifier.is_none() {
                return Err(PersistError::Malformed);
            }
        }
        AuthPhase::Exchanging {
            authorization_code, ..
        } => {
            if parts.oauth_state.is_some()
                || parts.pkce_verifier.is_none()
                || authorization_code.as_str().is_empty()
            {
                return Err(PersistError::Malformed);
            }
        }
        AuthPhase::Authorized { tokens, .. } => {
            if parts.pkce_verifier.is_some()
                || parts.oauth_state.is_some()
                || tokens.access_token.is_empty()
            {
                return Err(PersistError::Malformed);
            }
        }
        AuthPhase::Denied { .. }
        | AuthPhase::Failed { .. }
        | AuthPhase::Expired { .. }
        | AuthPhase::Revoked { .. } => {
            if parts.pkce_verifier.is_some() || parts.oauth_state.is_some() {
                return Err(PersistError::Malformed);
            }
        }
    }
    Ok(())
}

fn encode_phase(phase: &AuthPhase) -> WirePhase {
    match phase {
        AuthPhase::Pending => WirePhase::Pending,
        AuthPhase::Exchanging {
            authorization_code,
            received_at,
        } => WirePhase::Exchanging {
            authorization_code: authorization_code.as_str().to_owned(),
            received_at: received_at.0,
        },
        AuthPhase::Authorized {
            account,
            tokens,
            authorized_at,
        } => WirePhase::Authorized {
            account: WireAccount {
                id: account.id.clone(),
                battletag: account.battletag.clone(),
            },
            tokens: WireTokens {
                access_token: tokens.access_token.clone(),
                token_type: match tokens.token_type {
                    BearerTokenType::Bearer => "bearer".to_owned(),
                },
                access_expires_at: tokens.access_expires_at.0,
                refresh_token: tokens.refresh_token.clone(),
                granted_scopes: tokens.granted_scopes.clone(),
            },
            authorized_at: authorized_at.0,
        },
        AuthPhase::Denied { at } => WirePhase::Denied { at: at.0 },
        AuthPhase::Failed { retryable, at } => WirePhase::Failed {
            retryable: *retryable,
            at: at.0,
        },
        AuthPhase::Expired { at } => WirePhase::Expired { at: at.0 },
        AuthPhase::Revoked { at } => WirePhase::Revoked { at: at.0 },
    }
}

fn decode_phase(phase: WirePhase) -> Result<AuthPhase, PersistError> {
    Ok(match phase {
        WirePhase::Pending => AuthPhase::Pending,
        WirePhase::Exchanging {
            authorization_code,
            received_at,
        } => AuthPhase::Exchanging {
            authorization_code: AuthorizationCode::new(authorization_code),
            received_at: Timestamp(received_at),
        },
        WirePhase::Authorized {
            account,
            tokens,
            authorized_at,
        } => {
            let token_type = match tokens.token_type.as_str() {
                "bearer" => BearerTokenType::Bearer,
                _ => return Err(PersistError::Malformed),
            };
            AuthPhase::Authorized {
                account: AccountSummary {
                    id: account.id,
                    battletag: account.battletag,
                },
                tokens: BattleNetTokenSet {
                    access_token: tokens.access_token,
                    token_type,
                    access_expires_at: Timestamp(tokens.access_expires_at),
                    refresh_token: tokens.refresh_token,
                    granted_scopes: tokens.granted_scopes,
                },
                authorized_at: Timestamp(authorized_at),
            }
        }
        WirePhase::Denied { at } => AuthPhase::Denied { at: Timestamp(at) },
        WirePhase::Failed { retryable, at } => AuthPhase::Failed {
            retryable,
            at: Timestamp(at),
        },
        WirePhase::Expired { at } => AuthPhase::Expired { at: Timestamp(at) },
        WirePhase::Revoked { at } => AuthPhase::Revoked { at: Timestamp(at) },
    })
}

fn encode_bytes(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

fn decode_fixed<const N: usize>(value: &str) -> Result<[u8; N], PersistError> {
    let decoded = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| PersistError::Malformed)?;
    decoded
        .as_slice()
        .try_into()
        .map_err(|_| PersistError::Malformed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::callback::validate_callback_query;
    use crate::auth::origin::PublicOrigin;
    use crate::auth::session::BeginMaterial;
    use crate::auth::types::TraySecret;

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
        origin: &PublicOrigin,
        mut record: AuthSessionRecord,
        material: &BeginMaterial,
    ) -> AuthSessionRecord {
        let state = material.state.encode();
        let callback =
            validate_callback_query(&[("code", "one-time-code"), ("state", &state)]).unwrap();
        record
            .consume_callback(origin, callback, Timestamp(1_500))
            .unwrap();
        record
    }

    #[test]
    fn round_trips_pending_with_literal_verifier() {
        let (_origin, record, material, tray) = fixture();
        let bytes = record.encode().unwrap();
        let decoded = AuthSessionRecord::decode(&bytes).unwrap();

        assert!(matches!(decoded.phase(), AuthPhase::Pending));
        assert_eq!(decoded.attempt_id(), AttemptId([1; 16]));
        assert_eq!(decoded.schema_version(), SCHEMA_VERSION);
        assert_eq!(decoded.created_at(), Timestamp(1_000));
        assert_eq!(decoded.authorize_until(), Timestamp(61_000));
        assert_eq!(decoded.tray_key_sha256(), &tray.sha256());
        assert_eq!(
            decoded.pkce_verifier().map(PkceVerifier::as_str),
            Some(material.pkce_verifier.as_str())
        );
        assert_eq!(
            decoded.oauth_state().map(OAuthState::encode),
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
        let record = into_exchanging(&origin, record, &material);
        let bytes = record.encode().unwrap();
        let mut decoded = AuthSessionRecord::decode(&bytes).unwrap();

        match decoded.phase() {
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
            decoded.pkce_verifier().map(PkceVerifier::as_str),
            Some(material.pkce_verifier.as_str())
        );
        assert!(decoded.oauth_state().is_none());

        let exchange = decoded.exchange_material(&origin).unwrap();
        assert_eq!(exchange.code.as_str(), "one-time-code");
        assert_eq!(exchange.code_verifier, material.pkce_verifier.as_str());

        decoded.apply_exchange_failure(true, Timestamp(1_600));
        assert!(matches!(decoded.phase(), AuthPhase::Exchanging { .. }));
        assert_eq!(
            decoded.exchange_material(&origin).unwrap().code.as_str(),
            "one-time-code"
        );
        assert_eq!(
            decoded.pkce_verifier().map(PkceVerifier::as_str),
            Some(material.pkce_verifier.as_str())
        );
    }

    #[test]
    fn round_trips_authorized_with_account_and_token_presence() {
        let (origin, record, material, _) = fixture();
        let mut record = into_exchanging(&origin, record, &material);
        record.apply_exchange_success(
            AccountSummary {
                id: "42".to_owned(),
                battletag: "Player#42".to_owned(),
            },
            BattleNetTokenSet {
                access_token: "access-secret".to_owned(),
                token_type: BearerTokenType::Bearer,
                access_expires_at: Timestamp(99_000),
                refresh_token: Some("refresh-secret".to_owned()),
                granted_scopes: "openid".to_owned(),
            },
            Timestamp(1_600),
        );

        let bytes = record.encode().unwrap();
        let decoded = AuthSessionRecord::decode(&bytes).unwrap();
        match decoded.phase() {
            AuthPhase::Authorized {
                account,
                tokens,
                authorized_at,
            } => {
                assert_eq!(account.id, "42");
                assert_eq!(account.battletag, "Player#42");
                assert_eq!(*authorized_at, Timestamp(1_600));
                assert_eq!(tokens.access_expires_at, Timestamp(99_000));
                assert_eq!(tokens.granted_scopes, "openid");
                assert_eq!(tokens.token_type, BearerTokenType::Bearer);
                assert!(!tokens.access_token.is_empty());
                assert_eq!(tokens.access_token, "access-secret");
                assert_eq!(tokens.refresh_token.as_deref(), Some("refresh-secret"));
            }
            other => panic!("expected authorized, got {other:?}"),
        }
        assert!(decoded.pkce_verifier().is_none());
        assert!(decoded.oauth_state().is_none());
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
        denied
            .consume_callback(&origin, callback, Timestamp(1_500))
            .unwrap();
        let denied = AuthSessionRecord::decode(&denied.encode().unwrap()).unwrap();
        match denied.phase() {
            AuthPhase::Denied { at } => assert_eq!(*at, Timestamp(1_500)),
            other => panic!("expected denied, got {other:?}"),
        }
        assert!(denied.pkce_verifier().is_none());

        let mut failed = into_exchanging(&origin, pending.clone(), &material);
        failed.apply_exchange_failure(false, Timestamp(1_700));
        let failed = AuthSessionRecord::decode(&failed.encode().unwrap()).unwrap();
        match failed.phase() {
            AuthPhase::Failed { retryable, at } => {
                assert!(!(*retryable));
                assert_eq!(*at, Timestamp(1_700));
            }
            other => panic!("expected failed, got {other:?}"),
        }
        assert!(failed.pkce_verifier().is_none());
        assert!(failed.exchange_material(&origin).is_none());

        let mut expired = pending.clone();
        let callback =
            validate_callback_query(&[("code", "late-code"), ("state", &state)]).unwrap();
        assert_eq!(
            expired.consume_callback(&origin, callback, Timestamp(70_000)),
            Err(crate::auth::session::ConsumeError::Expired)
        );
        let expired = AuthSessionRecord::decode(&expired.encode().unwrap()).unwrap();
        match expired.phase() {
            AuthPhase::Expired { at } => assert_eq!(*at, Timestamp(70_000)),
            other => panic!("expected expired, got {other:?}"),
        }

        let mut revoked = pending;
        revoked
            .revoke(AttemptId([1; 16]), &tray, Timestamp(2_000))
            .unwrap();
        let revoked = AuthSessionRecord::decode(&revoked.encode().unwrap()).unwrap();
        match revoked.phase() {
            AuthPhase::Revoked { at } => assert_eq!(*at, Timestamp(2_000)),
            other => panic!("expected revoked, got {other:?}"),
        }
        assert!(revoked.pkce_verifier().is_none());
        assert!(revoked.oauth_state().is_none());
    }

    #[test]
    fn rejects_unknown_schema_versions_and_truncated_payloads() {
        let (_origin, record, material, _) = fixture();
        let mut bytes = record.encode().unwrap();
        let json = String::from_utf8(bytes.clone()).unwrap();
        assert!(json.contains("\"schema_version\":1"));
        let bumped = json.replacen("\"schema_version\":1", "\"schema_version\":2", 1);
        assert_eq!(
            AuthSessionRecord::decode(bumped.as_bytes()).unwrap_err(),
            PersistError::UnsupportedSchemaVersion
        );

        assert!(!bytes.is_empty());
        bytes.truncate(bytes.len() / 2);
        assert_eq!(
            AuthSessionRecord::decode(&bytes).unwrap_err(),
            PersistError::Malformed
        );
        assert_eq!(
            AuthSessionRecord::decode(b"").unwrap_err(),
            PersistError::Malformed
        );
        assert_eq!(
            AuthSessionRecord::decode(b"{").unwrap_err(),
            PersistError::Malformed
        );

        let exchanging = into_exchanging(&fixture().0, fixture().1, &material);
        let mut value: serde_json::Value =
            serde_json::from_slice(&exchanging.encode().unwrap()).unwrap();
        value["pkce_verifier"] = serde_json::Value::Null;
        assert_eq!(
            AuthSessionRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap_err(),
            PersistError::Malformed
        );

        let exchanging = into_exchanging(&fixture().0, fixture().1, &material);
        let debug = format!("{exchanging:?}");
        assert!(!debug.contains("one-time-code"));
        assert!(!debug.contains(material.pkce_verifier.as_str()));
    }
}
