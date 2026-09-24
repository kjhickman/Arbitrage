use serde::{Deserialize, Serialize};

use crate::auth::battlenet::{AccountSummary, ProviderError, TokenExchangeRequest};
use crate::auth::callback::ValidatedCallback;
use crate::auth::oauth_state::OAuthState;
use crate::auth::origin::PublicOrigin;
use crate::auth::pkce::PkceVerifier;
use crate::auth::types::{
    AttemptId, AuthorizationCode, CallbackSecret, Sha256Digest, Timestamp, TraySecret,
    secrets_equal,
};

pub const SCHEMA_VERSION: u8 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AuthSessionRecord {
    pub(crate) schema_version: u8,
    pub(crate) attempt_id: AttemptId,
    pub(crate) tray_key_sha256: Sha256Digest,
    pub(crate) callback_key_sha256: Sha256Digest,
    pub(crate) oauth_state: Option<OAuthState>,
    pub(crate) pkce_verifier: Option<PkceVerifier>,
    pub(crate) created_at: Timestamp,
    pub(crate) authorize_until: Timestamp,
    pub(crate) phase: AuthPhase,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum AuthPhase {
    Pending,
    Exchanging {
        authorization_code: AuthorizationCode,
        received_at: Timestamp,
    },
    Authorized {
        account: AccountSummary,
        authorized_at: Timestamp,
    },
    Denied {
        at: Timestamp,
    },
    Failed {
        at: Timestamp,
    },
    Expired {
        at: Timestamp,
    },
    Revoked {
        at: Timestamp,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BeginMaterial {
    pub state: OAuthState,
    pub pkce_verifier: PkceVerifier,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BeginError {
    ConflictingTrayKey,
    NotPending,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConsumeError {
    WrongAttempt,
    InvalidCallbackSecret,
    Expired,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProofError {
    Unauthorized,
}

impl AuthSessionRecord {
    pub fn begin(
        attempt_id: AttemptId,
        tray_key_sha256: Sha256Digest,
        callback_secret: CallbackSecret,
        pkce_verifier: PkceVerifier,
        now: Timestamp,
        authorize_for_ms: u64,
    ) -> (Self, BeginMaterial) {
        let state = OAuthState::new(attempt_id, callback_secret);
        let record = Self {
            schema_version: SCHEMA_VERSION,
            attempt_id,
            tray_key_sha256,
            callback_key_sha256: callback_secret.sha256(),
            oauth_state: Some(state.clone()),
            pkce_verifier: Some(pkce_verifier.clone()),
            created_at: now,
            authorize_until: Timestamp(now.0.saturating_add(authorize_for_ms)),
            phase: AuthPhase::Pending,
        };
        (
            record,
            BeginMaterial {
                state,
                pkce_verifier,
            },
        )
    }

    pub fn begin_idempotent(
        &self,
        tray_key_sha256: &Sha256Digest,
    ) -> Result<BeginMaterial, BeginError> {
        if !matches!(self.phase, AuthPhase::Pending) {
            return Err(BeginError::NotPending);
        }
        if !secrets_equal(&self.tray_key_sha256, tray_key_sha256) {
            return Err(BeginError::ConflictingTrayKey);
        }
        let state = self.oauth_state.clone().ok_or(BeginError::NotPending)?;
        let pkce_verifier = self.pkce_verifier.clone().ok_or(BeginError::NotPending)?;
        Ok(BeginMaterial {
            state,
            pkce_verifier,
        })
    }

    pub fn prove(&self, attempt_id: AttemptId, tray_secret: &TraySecret) -> Result<(), ProofError> {
        if attempt_id == self.attempt_id
            && secrets_equal(&tray_secret.sha256(), &self.tray_key_sha256)
        {
            Ok(())
        } else {
            Err(ProofError::Unauthorized)
        }
    }

    pub fn consume_callback(
        &mut self,
        callback: ValidatedCallback,
        now: Timestamp,
    ) -> Result<(), ConsumeError> {
        if now.0 > self.authorize_until.0 {
            if matches!(self.phase, AuthPhase::Pending) {
                self.oauth_state = None;
                self.pkce_verifier = None;
                self.phase = AuthPhase::Expired { at: now };
            }
            return Err(ConsumeError::Expired);
        }

        let (state, outcome_code) = match callback {
            ValidatedCallback::Code { code, state } => (state, Some(code)),
            ValidatedCallback::Denied { state, .. } => (state, None),
        };

        if state.attempt_id() != self.attempt_id {
            return Err(ConsumeError::WrongAttempt);
        }
        if !secrets_equal(&state.callback_secret().sha256(), &self.callback_key_sha256) {
            return Err(ConsumeError::InvalidCallbackSecret);
        }

        if matches!(self.phase, AuthPhase::Pending) {
            self.oauth_state = None;
            if let Some(code) = outcome_code {
                // Persist Exchanging before any provider HTTP so a crash after code
                // consumption cannot accept another code or invent success.
                self.phase = AuthPhase::Exchanging {
                    authorization_code: code,
                    received_at: now,
                };
            } else {
                self.pkce_verifier = None;
                self.phase = AuthPhase::Denied { at: now };
            }
        }
        Ok(())
    }

    pub fn exchange_material(&self, origin: &PublicOrigin) -> Option<TokenExchangeRequest> {
        match &self.phase {
            AuthPhase::Exchanging {
                authorization_code, ..
            } => {
                let verifier = self.pkce_verifier.as_ref()?;
                Some(TokenExchangeRequest {
                    code: authorization_code.clone(),
                    redirect_uri: origin.redirect_uri(),
                    code_verifier: verifier.as_str().to_owned(),
                })
            }
            _ => None,
        }
    }

    /// Leaves the attempt exchanging when the provider was unavailable, so a retry can reuse the code.
    pub fn apply_exchange_outcome(
        &mut self,
        outcome: Result<AccountSummary, ProviderError>,
        now: Timestamp,
    ) {
        if !matches!(self.phase, AuthPhase::Exchanging { .. })
            || matches!(outcome, Err(ProviderError::Unavailable))
        {
            return;
        }
        self.pkce_verifier = None;
        self.phase = outcome.map_or(AuthPhase::Failed { at: now }, |account| {
            AuthPhase::Authorized {
                account,
                authorized_at: now,
            }
        });
    }

    pub fn revoke(
        &mut self,
        attempt_id: AttemptId,
        tray_secret: &TraySecret,
        now: Timestamp,
    ) -> Result<(), ProofError> {
        self.prove(attempt_id, tray_secret)?;
        self.oauth_state = None;
        self.pkce_verifier = None;
        self.phase = AuthPhase::Revoked { at: now };
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::callback::validate_callback_query;
    use crate::auth::pkce::PkceVerifier;
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

    #[test]
    fn pending_code_callback_enters_exchanging() {
        let (_origin, mut record, material, _) = fixture();
        let state = material.state.encode();
        let callback =
            validate_callback_query(&[("code", "one-time-code"), ("state", &state)]).unwrap();
        record.consume_callback(callback, Timestamp(1_500)).unwrap();
        assert!(matches!(record.phase, AuthPhase::Exchanging { .. }));
        assert_eq!(record.attempt_id, AttemptId([1; 16]));
        assert_eq!(record.schema_version, SCHEMA_VERSION);
        assert_eq!(record.created_at, Timestamp(1_000));
        match &record.phase {
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
            record.begin_idempotent(&TraySecret::from_bytes([7; 32]).sha256()),
            Err(BeginError::NotPending)
        );
    }

    #[test]
    fn exchanging_is_required_before_provider_exchange_and_replay_stays_inert() {
        let (origin, mut record, material, _) = fixture();
        let state = material.state.encode();
        let callback =
            validate_callback_query(&[("code", "one-time-code"), ("state", &state)]).unwrap();
        record.consume_callback(callback, Timestamp(1_500)).unwrap();

        let exchange = record.exchange_material(&origin).unwrap();
        assert_eq!(exchange.code.as_str(), "one-time-code");
        assert_eq!(exchange.redirect_uri, origin.redirect_uri());
        assert_eq!(exchange.code_verifier, material.pkce_verifier.as_str());

        record.apply_exchange_outcome(
            Ok(AccountSummary {
                id: "9".to_owned(),
                battletag: "Name#9".to_owned(),
            }),
            Timestamp(1_600),
        );
        match &record.phase {
            AuthPhase::Authorized {
                account,
                authorized_at,
            } => {
                assert_eq!(account.battletag, "Name#9");
                assert_eq!(*authorized_at, Timestamp(1_600));
            }
            other => panic!("expected authorized, got {other:?}"),
        }

        let replay = validate_callback_query(&[("code", "other-code"), ("state", &state)]).unwrap();
        record.consume_callback(replay, Timestamp(1_700)).unwrap();
        assert!(matches!(record.phase, AuthPhase::Authorized { .. }));
        assert!(record.exchange_material(&origin).is_none());
    }

    #[test]
    fn crash_after_code_consumption_fails_closed() {
        let (origin, mut record, material, _) = fixture();
        let state = material.state.encode();
        let callback =
            validate_callback_query(&[("code", "one-time-code"), ("state", &state)]).unwrap();
        record.consume_callback(callback, Timestamp(1_500)).unwrap();
        record.apply_exchange_outcome(Err(ProviderError::UnexpectedResponse), Timestamp(1_501));
        match &record.phase {
            AuthPhase::Failed { at } => assert_eq!(*at, Timestamp(1_501)),
            other => panic!("expected failed, got {other:?}"),
        }
        assert!(record.exchange_material(&origin).is_none());
    }

    #[test]
    fn provider_denial_and_bad_proofs() {
        let (_origin, mut record, material, _tray) = fixture();
        let state = material.state.encode();
        let denied =
            validate_callback_query(&[("error", "access_denied"), ("state", &state)]).unwrap();
        record.consume_callback(denied, Timestamp(1_500)).unwrap();
        match &record.phase {
            AuthPhase::Denied { at } => assert_eq!(*at, Timestamp(1_500)),
            other => panic!("expected denied, got {other:?}"),
        }

        let (_origin2, mut record2, _, tray2) = fixture();
        assert!(record2.prove(AttemptId([1; 16]), &tray2).is_ok());
        assert_eq!(
            record2.prove(AttemptId([1; 16]), &TraySecret::from_bytes([0; 32])),
            Err(ProofError::Unauthorized)
        );
        record2
            .revoke(AttemptId([1; 16]), &tray2, Timestamp(2_000))
            .unwrap();
        match &record2.phase {
            AuthPhase::Revoked { at } => assert_eq!(*at, Timestamp(2_000)),
            other => panic!("expected revoked, got {other:?}"),
        }
    }

    #[test]
    fn transient_exchange_failure_keeps_the_attempt_retryable() {
        let (origin, mut record, material, _) = fixture();
        let state = material.state.encode();
        let callback =
            validate_callback_query(&[("code", "one-time-code"), ("state", &state)]).unwrap();
        record.consume_callback(callback, Timestamp(1_500)).unwrap();
        record.apply_exchange_outcome(Err(ProviderError::Unavailable), Timestamp(1_600));
        assert!(matches!(record.phase, AuthPhase::Exchanging { .. }));
        assert_eq!(
            record.exchange_material(&origin).unwrap().code.as_str(),
            "one-time-code"
        );

        record.apply_exchange_outcome(Err(ProviderError::InvalidGrant), Timestamp(1_700));
        match &record.phase {
            AuthPhase::Failed { at } => assert_eq!(*at, Timestamp(1_700)),
            other => panic!("expected failed, got {other:?}"),
        }
        assert!(record.exchange_material(&origin).is_none());
    }

    #[test]
    fn idempotent_begin_rejects_conflicting_tray_key() {
        let (_origin, record, material, tray) = fixture();
        let again = record.begin_idempotent(&tray.sha256()).unwrap();
        assert_eq!(again.state.encode(), material.state.encode());
        assert_eq!(
            record.begin_idempotent(&TraySecret::from_bytes([0; 32]).sha256()),
            Err(BeginError::ConflictingTrayKey)
        );
    }

    #[test]
    fn expired_pending_callback_fails_closed_to_expired() {
        let (_origin, mut record, material, _) = fixture();
        let state = material.state.encode();
        let callback =
            validate_callback_query(&[("code", "one-time-code"), ("state", &state)]).unwrap();
        assert_eq!(
            record.consume_callback(callback, Timestamp(70_000)),
            Err(ConsumeError::Expired)
        );
        match &record.phase {
            AuthPhase::Expired { at } => assert_eq!(*at, Timestamp(70_000)),
            other => panic!("expected expired, got {other:?}"),
        }
    }
}
