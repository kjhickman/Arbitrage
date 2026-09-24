use serde::{Deserialize, Serialize};

use crate::auth::battlenet::{TokenExchangeRequest, format_authorization_url};
use crate::auth::callback::{CallbackValidationError, validate_callback_query};
use crate::auth::origin::PublicOrigin;
use crate::auth::pkce::PkceVerifier;
use crate::auth::session::{
    AuthPhase, AuthSessionRecord, BeginError, BeginMaterial, ConsumeError, ProofError,
};
use crate::auth::types::{AttemptId, CallbackSecret, Sha256Digest, Timestamp, TraySecret};

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
    pub expires_at: u64,
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
    Sha256Digest::parse(&body.tray_key_sha256).ok()
}

pub fn parse_bearer_authorization(header: Option<&str>) -> Option<TraySecret> {
    let token = header?.strip_prefix("Bearer ")?;
    if token.is_empty() || token.as_bytes().iter().any(u8::is_ascii_whitespace) {
        return None;
    }
    TraySecret::parse_bearer_token(token).ok()
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
    now: Timestamp,
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
            let response = begin_response(&record, &material, origin, client_id);
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
            let response = begin_response(&record, &material, origin, client_id);
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
        AuthPhase::Denied { .. } => PublicAttemptStatus::Denied,
        AuthPhase::Expired { .. } => PublicAttemptStatus::Expired,
        AuthPhase::Failed { .. } | AuthPhase::Revoked { .. } => PublicAttemptStatus::Failed,
    }
}

pub fn status_for_capability(
    record: Option<&AuthSessionRecord>,
    attempt_id: AttemptId,
    tray_secret: &TraySecret,
) -> Result<PublicAttemptStatus, ProofError> {
    let record = record.ok_or(ProofError::Unauthorized)?;
    record.prove(attempt_id, tray_secret)?;
    Ok(public_status(record))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignedInError {
    Unauthorized,
    NotSignedIn,
}

pub fn signed_in_account_id(
    record: Option<&AuthSessionRecord>,
    attempt_id: AttemptId,
    tray_secret: &TraySecret,
) -> Result<String, SignedInError> {
    let record = record.ok_or(SignedInError::Unauthorized)?;
    record
        .prove(attempt_id, tray_secret)
        .map_err(|_| SignedInError::Unauthorized)?;
    match &record.phase {
        AuthPhase::Authorized { account, .. } => Ok(account.id.clone()),
        _ => Err(SignedInError::NotSignedIn),
    }
}

pub fn revoke_for_capability(
    record: Option<AuthSessionRecord>,
    attempt_id: AttemptId,
    tray_secret: &TraySecret,
    now: Timestamp,
) -> Result<AuthSessionRecord, ProofError> {
    let mut record = record.ok_or(ProofError::Unauthorized)?;
    record.revoke(attempt_id, tray_secret, now)?;
    Ok(record)
}

pub fn prepare_callback(
    record: Option<AuthSessionRecord>,
    origin: &PublicOrigin,
    params: &[(impl AsRef<str>, impl AsRef<str>)],
    now: Timestamp,
) -> Result<(AuthSessionRecord, Option<TokenExchangeRequest>), CallbackPrepareError> {
    let callback = validate_callback_query(params).map_err(CallbackPrepareError::InvalidQuery)?;
    let mut record = record.ok_or(CallbackPrepareError::MissingAttempt)?;
    match record.consume_callback(callback, now) {
        Ok(()) => {
            let exchange = record.exchange_material(origin);
            Ok((record, exchange))
        }
        Err(ConsumeError::Expired) => Ok((record, None)),
        Err(error) => Err(CallbackPrepareError::Consume(error)),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CallbackPrepareError {
    InvalidQuery(CallbackValidationError),
    MissingAttempt,
    Consume(ConsumeError),
}

fn begin_response(
    record: &AuthSessionRecord,
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
        expires_at: record.authorize_until.0,
        poll_after_ms: POLL_AFTER_MS,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::battlenet::{AccountSummary, ProviderError};
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
            Timestamp(1_000),
        )
        .unwrap()
        .0
    }

    fn exchanging(
        origin: &PublicOrigin,
        attempt: AttemptId,
    ) -> (AuthSessionRecord, Option<TokenExchangeRequest>) {
        let record = begun(origin, attempt);
        let state = record
            .begin_idempotent(&tray().sha256())
            .unwrap()
            .state
            .encode();
        prepare_callback(
            Some(record),
            origin,
            &[("code", "one-time-code"), ("state", state.as_str())],
            Timestamp(1_500),
        )
        .unwrap()
    }

    #[test]
    fn begin_returns_https_authorize_url_with_s256_and_no_secrets() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let attempt = AttemptId([1; 16]);
        let (record, result) = begin_attempt(
            None,
            attempt,
            tray().sha256(),
            CallbackSecret::from_bytes([2; 32]),
            PkceVerifier::from_entropy([3; 32]),
            &origin,
            "client-id",
            Timestamp(1_000),
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
        assert_eq!(result.response.expires_at, record.authorize_until.0);
        assert_eq!(result.response.poll_after_ms, POLL_AFTER_MS);
    }

    #[test]
    fn status_and_revoke_hide_tokens_and_require_bearer() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let attempt = AttemptId([1; 16]);
        let (mut record, exchange) = exchanging(&origin, attempt);
        assert!(exchange.is_some());
        record.apply_exchange_outcome(Ok(account()), Timestamp(1_600));

        let status = status_for_capability(Some(&record), attempt, &tray()).unwrap();
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
        assert_eq!(
            status_for_capability(Some(&record), attempt, &TraySecret::from_bytes([0; 32])),
            Err(ProofError::Unauthorized)
        );

        let revoked =
            revoke_for_capability(Some(record.clone()), attempt, &tray(), Timestamp(2_000))
                .unwrap();
        assert!(matches!(revoked.phase, AuthPhase::Revoked { .. }));
        let again =
            revoke_for_capability(Some(revoked), attempt, &tray(), Timestamp(2_100)).unwrap();
        assert!(matches!(again.phase, AuthPhase::Revoked { .. }));
    }

    #[test]
    fn callback_exchange_success_and_transient_failure_policies() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let attempt = AttemptId([1; 16]);
        let (mut record, exchange) = exchanging(&origin, attempt);
        assert_eq!(exchange, record.exchange_material(&origin));

        record.apply_exchange_outcome(Err(ProviderError::Unavailable), Timestamp(1_600));
        assert!(matches!(record.phase, AuthPhase::Exchanging { .. }));
        assert_eq!(
            status_for_capability(Some(&record), attempt, &tray()),
            Ok(PublicAttemptStatus::Pending)
        );

        assert!(record.exchange_material(&origin).is_some());
        record.apply_exchange_outcome(Ok(account()), Timestamp(1_700));
        assert!(matches!(record.phase, AuthPhase::Authorized { .. }));
    }

    #[test]
    fn a_terminal_provider_failure_fails_the_attempt() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let attempt = AttemptId([1; 16]);
        let (mut record, _) = exchanging(&origin, attempt);
        record.apply_exchange_outcome(Err(ProviderError::UnexpectedResponse), Timestamp(1_600));
        assert_eq!(
            status_for_capability(Some(&record), attempt, &tray()),
            Ok(PublicAttemptStatus::Failed)
        );
        assert!(record.exchange_material(&origin).is_none());
    }

    #[test]
    fn an_expired_callback_redirects_without_an_exchange() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let record = begun(&origin, AttemptId([1; 16]));
        let state = record
            .begin_idempotent(&tray().sha256())
            .unwrap()
            .state
            .encode();
        let (record, exchange) = prepare_callback(
            Some(record),
            &origin,
            &[("code", "late-code"), ("state", state.as_str())],
            Timestamp(1_000 + AUTHORIZE_TTL_MS + 1),
        )
        .unwrap();
        assert!(exchange.is_none());
        assert!(matches!(record.phase, AuthPhase::Expired { .. }));
    }
}
