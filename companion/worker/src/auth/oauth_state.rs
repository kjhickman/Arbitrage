use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};

use crate::auth::types::{AttemptId, CallbackSecret};

const STATE_VERSION: &str = "v1";

#[derive(Clone, PartialEq, Eq)]
pub struct OAuthState {
    attempt_id: AttemptId,
    callback_secret: CallbackSecret,
}

impl OAuthState {
    #[must_use]
    pub const fn new(attempt_id: AttemptId, callback_secret: CallbackSecret) -> Self {
        Self {
            attempt_id,
            callback_secret,
        }
    }

    #[must_use]
    pub const fn attempt_id(&self) -> AttemptId {
        self.attempt_id
    }

    #[must_use]
    pub const fn callback_secret(&self) -> &CallbackSecret {
        &self.callback_secret
    }

    #[must_use]
    pub fn encode(&self) -> String {
        format!(
            "{STATE_VERSION}.{}.{}",
            URL_SAFE_NO_PAD.encode(self.attempt_id.0),
            URL_SAFE_NO_PAD.encode(self.callback_secret.as_bytes())
        )
    }

    pub fn parse(raw: &str) -> Result<Self, OAuthStateError> {
        let mut parts = raw.split('.');
        let version = parts.next().ok_or(OAuthStateError::Malformed)?;
        let attempt_b64 = parts.next().ok_or(OAuthStateError::Malformed)?;
        let secret_b64 = parts.next().ok_or(OAuthStateError::Malformed)?;
        if parts.next().is_some() {
            return Err(OAuthStateError::Malformed);
        }
        if version != STATE_VERSION {
            return Err(OAuthStateError::UnsupportedVersion);
        }

        let attempt_bytes = URL_SAFE_NO_PAD
            .decode(attempt_b64)
            .map_err(|_| OAuthStateError::Malformed)?;
        let secret_bytes = URL_SAFE_NO_PAD
            .decode(secret_b64)
            .map_err(|_| OAuthStateError::Malformed)?;

        let attempt_id = AttemptId(
            attempt_bytes
                .as_slice()
                .try_into()
                .map_err(|_| OAuthStateError::Malformed)?,
        );
        let callback_secret = CallbackSecret::from_bytes(
            secret_bytes
                .as_slice()
                .try_into()
                .map_err(|_| OAuthStateError::Malformed)?,
        );

        Ok(Self::new(attempt_id, callback_secret))
    }
}

impl std::fmt::Debug for OAuthState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OAuthState")
            .field("attempt_id", &self.attempt_id)
            .field("callback_secret", &self.callback_secret)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OAuthStateError {
    Malformed,
    UnsupportedVersion,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_v1_state() {
        let state = OAuthState::new(AttemptId([1; 16]), CallbackSecret::from_bytes([2; 32]));
        let encoded = state.encode();
        assert!(encoded.starts_with("v1."));
        let parsed = OAuthState::parse(&encoded).unwrap();
        assert_eq!(parsed.attempt_id(), AttemptId([1; 16]));
        assert_eq!(parsed.callback_secret().as_bytes(), &[2; 32]);
    }

    #[test]
    fn rejects_malformed_and_wrong_version() {
        assert_eq!(
            OAuthState::parse("v2.aa.bb"),
            Err(OAuthStateError::UnsupportedVersion)
        );
        assert_eq!(
            OAuthState::parse("v1.only"),
            Err(OAuthStateError::Malformed)
        );
        assert_eq!(
            OAuthState::parse("v1.!!!.!!!"),
            Err(OAuthStateError::Malformed)
        );
    }
}
