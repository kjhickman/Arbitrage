use serde::{Deserialize, Serialize};

use crate::auth::battlenet::format_authorization_url;
use crate::auth::origin::PublicOrigin;
use crate::auth::pkce::PkceVerifier;
use crate::auth::session::{AuthPhase, AuthSessionRecord, BeginError, BeginMaterial};
use crate::auth::types::{AttemptId, CallbackSecret, Sha256Digest, TraySecret, UnixMillis};

pub const AUTHORIZE_TTL_MS: u64 = 10 * 60 * 1_000;
pub const POLL_AFTER_MS: u64 = 1_000;
pub const AUTH_SESSIONS_BINDING: &str = "AUTH_SESSIONS";
pub const RECORD_STORAGE_KEY: &str = "record";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BeginRequestBody {
    pub tray_key_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BeginResponseBody {
    pub authorization_url: String,
    pub poll_after_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum PublicAttemptStatus {
    Pending,
    SignedIn { account: PublicAccount },
    Denied,
    Expired,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublicAccount {
    pub id: String,
    pub battletag: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BeginResult {
    pub created: bool,
    pub response: BeginResponseBody,
}

pub fn parse_begin_body(bytes: &[u8]) -> Option<Sha256Digest> {
    let body: BeginRequestBody = serde_json::from_slice(bytes).ok()?;
    Sha256Digest::parse(&body.tray_key_sha256)
}

pub fn parse_bearer_authorization(header: Option<&str>) -> Option<TraySecret> {
    let token = header?.strip_prefix("Bearer ")?;
    if token.is_empty() || token.as_bytes().iter().any(u8::is_ascii_whitespace) {
        return None;
    }
    TraySecret::parse_bearer_token(token)
}

#[allow(clippy::too_many_arguments)]
pub fn begin_attempt(
    existing: Option<AuthSessionRecord>,
    attempt_id: AttemptId,
    tray_key_sha256: Sha256Digest,
    callback_secret: CallbackSecret,
    pkce_verifier: PkceVerifier,
    origin: &PublicOrigin,
    client_id: &str,
    now: UnixMillis,
) -> Result<(AuthSessionRecord, BeginResult), BeginError> {
    match existing {
        None => {
            let (record, material) = AuthSessionRecord::begin(
                attempt_id,
                tray_key_sha256,
                callback_secret,
                pkce_verifier,
                now,
                AUTHORIZE_TTL_MS,
            );
            let response = begin_response(&material, origin, client_id);
            Ok((
                record,
                BeginResult {
                    created: true,
                    response,
                },
            ))
        }
        Some(record) => {
            let material = record.begin_idempotent(&tray_key_sha256)?;
            let response = begin_response(&material, origin, client_id);
            Ok((
                record,
                BeginResult {
                    created: false,
                    response,
                },
            ))
        }
    }
}

pub fn public_status(record: &AuthSessionRecord) -> PublicAttemptStatus {
    match &record.phase {
        AuthPhase::Pending | AuthPhase::Exchanging { .. } => PublicAttemptStatus::Pending,
        AuthPhase::Authorized { account, .. } => PublicAttemptStatus::SignedIn {
            account: PublicAccount {
                id: account.id.clone(),
                battletag: account.battletag.clone(),
            },
        },
        AuthPhase::Denied => PublicAttemptStatus::Denied,
        AuthPhase::Expired => PublicAttemptStatus::Expired,
        AuthPhase::Failed | AuthPhase::Revoked => PublicAttemptStatus::Failed,
    }
}

fn begin_response(
    material: &BeginMaterial,
    origin: &PublicOrigin,
    client_id: &str,
) -> BeginResponseBody {
    BeginResponseBody {
        authorization_url: format_authorization_url(
            client_id,
            origin,
            &material.state,
            &material.pkce_verifier,
        ),
        poll_after_ms: POLL_AFTER_MS,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::battlenet::{AccountSummary, ProviderError};
    use crate::auth::callback::validate_callback_query;
    use crate::auth::types::CallbackSecret;

    fn tray() -> TraySecret {
        TraySecret::from_bytes([7; 32])
    }

    fn account() -> AccountSummary {
        AccountSummary {
            id: "42".to_owned(),
            battletag: "Player#42".to_owned(),
        }
    }

    fn begun(origin: &PublicOrigin, attempt: AttemptId) -> AuthSessionRecord {
        begin_attempt(
            None,
            attempt,
            tray().sha256(),
            CallbackSecret::from_bytes([2; 32]),
            PkceVerifier::from_entropy([3; 32]),
            origin,
            "client-id",
            UnixMillis(1_000),
        )
        .unwrap()
        .0
    }

    fn exchanging(origin: &PublicOrigin, attempt: AttemptId) -> AuthSessionRecord {
        let mut record = begun(origin, attempt);
        let state = record
            .begin_idempotent(&tray().sha256())
            .unwrap()
            .state
            .encode();
        let callback =
            validate_callback_query(&[("code", "one-time-code"), ("state", state.as_str())])
                .unwrap();
        record
            .consume_callback(callback, UnixMillis(1_500))
            .unwrap();
        record
    }

    #[test]
    fn begin_returns_https_authorize_url_with_s256_and_no_secrets() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let attempt = AttemptId([1; 16]);
        let (_, result) = begin_attempt(
            None,
            attempt,
            tray().sha256(),
            CallbackSecret::from_bytes([2; 32]),
            PkceVerifier::from_entropy([3; 32]),
            &origin,
            "client-id",
            UnixMillis(1_000),
        )
        .unwrap();
        assert!(result.created);
        assert!(
            result
                .response
                .authorization_url
                .starts_with("https://oauth.battle.net/authorize?")
        );
        assert!(
            result
                .response
                .authorization_url
                .contains("code_challenge_method=S256")
        );
        assert!(result.response.authorization_url.contains("state="));
        let body = serde_json::to_string(&result.response).unwrap();
        assert!(!body.contains(&tray().sha256().encode()));
        assert_eq!(result.response.poll_after_ms, POLL_AFTER_MS);
    }

    #[test]
    fn status_and_revoke_hide_tokens_and_require_bearer() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let attempt = AttemptId([1; 16]);
        let mut record = exchanging(&origin, attempt);
        record.apply_exchange_outcome(Ok(account()));

        record.prove(attempt, &tray()).unwrap();
        let status = public_status(&record);
        let encoded = serde_json::to_string(&status).unwrap();
        assert_eq!(
            status,
            PublicAttemptStatus::SignedIn {
                account: PublicAccount {
                    id: "42".to_owned(),
                    battletag: "Player#42".to_owned(),
                }
            }
        );
        assert!(!encoded.contains("one-time-code"));

        assert!(parse_bearer_authorization(None).is_none());
        assert!(
            record
                .prove(attempt, &TraySecret::from_bytes([0; 32]))
                .is_err()
        );

        let mut revoked = record.clone();
        revoked.revoke(attempt, &tray()).unwrap();
        assert!(matches!(revoked.phase, AuthPhase::Revoked));
        revoked.revoke(attempt, &tray()).unwrap();
        assert!(matches!(revoked.phase, AuthPhase::Revoked));
    }

    #[test]
    fn callback_exchange_success_and_transient_failure_policies() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let mut record = exchanging(&origin, AttemptId([1; 16]));
        let exchange = record.exchange_material(&origin);
        assert!(exchange.is_some());

        record.apply_exchange_outcome(Err(ProviderError::Unavailable));
        assert!(matches!(record.phase, AuthPhase::Exchanging { .. }));
        assert_eq!(public_status(&record), PublicAttemptStatus::Pending);

        assert!(record.exchange_material(&origin).is_some());
        record.apply_exchange_outcome(Ok(account()));
        assert!(matches!(record.phase, AuthPhase::Authorized { .. }));
    }

    #[test]
    fn a_terminal_provider_failure_fails_the_attempt() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let mut record = exchanging(&origin, AttemptId([1; 16]));
        record.apply_exchange_outcome(Err(ProviderError::UnexpectedResponse));
        assert_eq!(public_status(&record), PublicAttemptStatus::Failed);
        assert!(record.exchange_material(&origin).is_none());
    }

    #[test]
    fn an_expired_callback_redirects_without_an_exchange() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let mut record = begun(&origin, AttemptId([1; 16]));
        let state = record
            .begin_idempotent(&tray().sha256())
            .unwrap()
            .state
            .encode();
        let callback =
            validate_callback_query(&[("code", "late-code"), ("state", state.as_str())]).unwrap();
        assert_eq!(
            record.consume_callback(callback, UnixMillis(1_000 + AUTHORIZE_TTL_MS + 1)),
            Err(crate::auth::session::ConsumeError::Expired)
        );
        assert!(record.exchange_material(&origin).is_none());
        assert!(matches!(record.phase, AuthPhase::Expired));
    }
}
