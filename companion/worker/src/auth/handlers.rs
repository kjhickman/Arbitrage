use serde::{Deserialize, Serialize};

use crate::auth::battlenet::{
    AccountSummary, BattleNetTokenSet, ProviderError, TokenExchangeRequest,
    authorization_url_parts, format_authorization_url,
};
use crate::auth::callback::{CallbackValidationError, validate_callback_query};
use crate::auth::completion::{BrowserCompletionRedirect, CompletionPage, completion_page};
use crate::auth::oauth_state::OAuthState;
use crate::auth::origin::PublicOrigin;
use crate::auth::pkce::PkceVerifier;
use crate::auth::session::{
    AuthPhase, AuthSessionRecord, BeginError, BeginMaterial, ConsumeError, ProofError,
};
use crate::auth::types::{
    AttemptId, CallbackSecret, Sha256Digest, Timestamp, TraySecret, WireParseError,
};

pub const BATTLE_NET_AUTHORIZE_ENDPOINT: &str = "https://oauth.battle.net/authorize";
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CallbackHandlerResult {
    pub redirect: BrowserCompletionRedirect,
    pub exchange: Option<TokenExchangeRequest>,
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

pub fn parse_attempt_path_id(raw: &str) -> Result<AttemptId, WireParseError> {
    AttemptId::parse(raw)
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
    match record.phase() {
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
    match record.phase() {
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
    params: &[(&str, &str)],
    now: Timestamp,
) -> Result<(AuthSessionRecord, CallbackHandlerResult), CallbackPrepareError> {
    let callback = validate_callback_query(params).map_err(CallbackPrepareError::InvalidQuery)?;
    let mut record = record.ok_or(CallbackPrepareError::MissingAttempt)?;
    match record.consume_callback(origin, callback, now) {
        Ok(result) => {
            let exchange = record.exchange_material(origin);
            Ok((
                record,
                CallbackHandlerResult {
                    redirect: result.redirect,
                    exchange,
                },
            ))
        }
        Err(ConsumeError::Expired) => Ok((
            record,
            CallbackHandlerResult {
                redirect: BrowserCompletionRedirect::to_completion_page(origin.completion_uri()),
                exchange: None,
            },
        )),
        Err(error) => Err(CallbackPrepareError::Consume(error)),
    }
}

#[derive(Debug, Clone)]
pub enum CallbackExchangeDecision {
    Success {
        account: AccountSummary,
        tokens: BattleNetTokenSet,
    },
    RetryableFailure,
    TerminalFailure,
}

#[must_use]
pub fn decide_callback_exchange(
    exchange: Result<BattleNetTokenSet, ProviderError>,
    identity: Option<Result<AccountSummary, ProviderError>>,
) -> CallbackExchangeDecision {
    match exchange {
        Err(ProviderError::Unavailable) => CallbackExchangeDecision::RetryableFailure,
        Err(_) => CallbackExchangeDecision::TerminalFailure,
        Ok(tokens) => match identity {
            Some(Ok(account)) => CallbackExchangeDecision::Success { account, tokens },
            Some(Err(_)) | None => CallbackExchangeDecision::TerminalFailure,
        },
    }
}

pub fn apply_provider_outcome(
    record: &mut AuthSessionRecord,
    outcome: Result<(AccountSummary, BattleNetTokenSet), ProviderError>,
    now: Timestamp,
) -> Result<(), ProviderError> {
    match outcome {
        Ok((account, tokens)) => {
            record.apply_exchange_success(account, tokens, now);
            Ok(())
        }
        Err(error) => {
            let retryable = matches!(error, ProviderError::Unavailable);
            record.apply_exchange_failure(retryable, now);
            Err(error)
        }
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
    let parts = authorization_url_parts(
        client_id,
        crate::auth::battlenet::BATTLE_NET_SCOPE,
        origin,
        &material.state,
        &material.pkce_verifier,
    );
    BeginResponseBody {
        authorization_url: format_authorization_url(BATTLE_NET_AUTHORIZE_ENDPOINT, &parts),
        expires_at: record.authorize_until().0,
        poll_after_ms: POLL_AFTER_MS,
    }
}

#[must_use]
pub const fn completion_http() -> CompletionPage {
    completion_page()
}

pub fn callback_state_attempt_id(
    params: &[(&str, &str)],
) -> Result<AttemptId, CallbackValidationError> {
    let mut state: Option<&str> = None;
    for &(key, value) in params {
        if key == "state" && state.replace(value).is_some() {
            return Err(CallbackValidationError::DuplicateParameter("state"));
        }
    }
    let state = state.ok_or(CallbackValidationError::MissingState)?;
    OAuthState::parse(state)
        .map(|state| state.attempt_id())
        .map_err(CallbackValidationError::InvalidState)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::battlenet::{
        BattleNetTokenSet, BearerTokenType, FakeBattleNetClient, FakeExchangeOutcome,
    };
    use crate::auth::types::CallbackSecret;

    fn tray() -> TraySecret {
        TraySecret::from_bytes([7; 32])
    }

    fn client_ok() -> FakeBattleNetClient {
        FakeBattleNetClient::new(FakeExchangeOutcome::Success {
            tokens: BattleNetTokenSet {
                access_token: "access-secret".to_owned(),
                token_type: BearerTokenType::Bearer,
                access_expires_at: Timestamp(99_000),
                refresh_token: Some("refresh-secret".to_owned()),
                granted_scopes: crate::auth::battlenet::BATTLE_NET_SCOPE.to_owned(),
            },
            account: AccountSummary {
                id: "42".to_owned(),
                battletag: "Player#42".to_owned(),
            },
        })
    }

    fn finish_exchange(
        record: &mut AuthSessionRecord,
        client: &FakeBattleNetClient,
        request: &TokenExchangeRequest,
        now: Timestamp,
    ) -> Result<(), ProviderError> {
        let outcome = client.exchange(request).and_then(|tokens| {
            let account = client.identity(&tokens.access_token)?;
            Ok((account, tokens))
        });
        apply_provider_outcome(record, outcome, now)
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
        assert!(!result.response.authorization_url.contains("access-secret"));
        assert!(!result.response.authorization_url.contains("refresh-secret"));
        let body = serde_json::to_string(&result.response).unwrap();
        assert!(!body.contains("access-secret"));
        assert!(!body.contains(&tray().sha256().encode()));
        assert_eq!(result.response.expires_at, record.authorize_until().0);
        assert_eq!(result.response.poll_after_ms, POLL_AFTER_MS);
    }

    #[test]
    fn status_and_revoke_hide_tokens_and_require_bearer() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let attempt = AttemptId([1; 16]);
        let (record, _) = begin_attempt(
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
        let state = record
            .begin_idempotent(&tray().sha256())
            .unwrap()
            .state
            .encode();
        let (mut record, prepared) = prepare_callback(
            Some(record),
            &origin,
            &[("code", "one-time-code"), ("state", &state)],
            Timestamp(1_500),
        )
        .unwrap();
        finish_exchange(
            &mut record,
            &client_ok(),
            prepared.exchange.as_ref().unwrap(),
            Timestamp(1_600),
        )
        .unwrap();

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
        assert!(!encoded.contains("access-secret"));
        assert!(!encoded.contains("refresh-secret"));
        assert!(!encoded.contains("one-time-code"));

        assert!(parse_bearer_authorization(None).is_none());
        assert_eq!(
            status_for_capability(Some(&record), attempt, &TraySecret::from_bytes([0; 32])),
            Err(ProofError::Unauthorized)
        );

        let revoked =
            revoke_for_capability(Some(record.clone()), attempt, &tray(), Timestamp(2_000))
                .unwrap();
        assert!(matches!(revoked.phase(), AuthPhase::Revoked { .. }));
        let again =
            revoke_for_capability(Some(revoked), attempt, &tray(), Timestamp(2_100)).unwrap();
        assert!(matches!(again.phase(), AuthPhase::Revoked { .. }));
    }

    #[test]
    fn callback_exchange_success_and_transient_failure_policies() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let attempt = AttemptId([1; 16]);
        let (record, _) = begin_attempt(
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
        let state = record
            .begin_idempotent(&tray().sha256())
            .unwrap()
            .state
            .encode();

        let (mut record, prepared) = prepare_callback(
            Some(record),
            &origin,
            &[("code", "one-time-code"), ("state", &state)],
            Timestamp(1_500),
        )
        .unwrap();
        assert_eq!(prepared.redirect.status, 303);
        assert_eq!(
            prepared.redirect.location,
            "https://auth.example.com/oauth/battlenet/complete"
        );

        let unavailable = FakeBattleNetClient::new(FakeExchangeOutcome::ExchangeFailure(
            ProviderError::Unavailable,
        ));
        assert!(
            finish_exchange(
                &mut record,
                &unavailable,
                prepared.exchange.as_ref().unwrap(),
                Timestamp(1_600),
            )
            .is_err()
        );
        assert!(matches!(record.phase(), AuthPhase::Exchanging { .. }));
        assert_eq!(
            status_for_capability(Some(&record), attempt, &tray()),
            Ok(PublicAttemptStatus::Pending)
        );

        let material = record.exchange_material(&origin).unwrap();
        finish_exchange(&mut record, &client_ok(), &material, Timestamp(1_700)).unwrap();
        assert!(matches!(record.phase(), AuthPhase::Authorized { .. }));
    }

    #[test]
    fn consumed_code_is_not_retried_when_identity_lookup_fails() {
        let tokens = BattleNetTokenSet {
            access_token: "access-secret".to_owned(),
            token_type: BearerTokenType::Bearer,
            access_expires_at: Timestamp(99_000),
            refresh_token: None,
            granted_scopes: "openid".to_owned(),
        };
        assert!(matches!(
            decide_callback_exchange(Err(ProviderError::Unavailable), None),
            CallbackExchangeDecision::RetryableFailure
        ));
        assert!(matches!(
            decide_callback_exchange(Ok(tokens), Some(Err(ProviderError::Unavailable))),
            CallbackExchangeDecision::TerminalFailure
        ));
    }

    #[test]
    fn callback_state_selects_the_attempt_encoded_in_state() {
        let state = crate::auth::oauth_state::OAuthState::new(
            AttemptId([9; 16]),
            CallbackSecret::from_bytes([4; 32]),
        )
        .encode();
        assert_eq!(
            callback_state_attempt_id(&[("code", "abc"), ("state", &state)]).unwrap(),
            AttemptId([9; 16])
        );
        assert!(callback_state_attempt_id(&[("code", "abc")]).is_err());
    }

    #[test]
    fn completion_page_policy_is_no_store_with_csp() {
        let page = completion_http();
        assert_eq!(page.status, 200);
        assert_eq!(page.cache_control, "no-store");
        assert_eq!(
            page.content_security_policy,
            "default-src 'none'; base-uri 'none'; form-action 'none'"
        );
        assert!(!page.body.contains("token"));
    }
}
