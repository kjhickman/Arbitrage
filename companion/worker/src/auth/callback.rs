use crate::auth::oauth_state::{OAuthState, OAuthStateError};
use crate::auth::types::AuthorizationCode;

const MAX_CODE_LEN: usize = 256;
const MAX_ERROR_LEN: usize = 64;
const MAX_STATE_LEN: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ValidatedCallback {
    Code {
        code: AuthorizationCode,
        state: OAuthState,
    },
    Denied {
        state: OAuthState,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CallbackValidationError {
    DuplicateParameter(&'static str),
    MissingState,
    MissingOutcome,
    AmbiguousOutcome,
    OversizedValue(&'static str),
    InvalidState(OAuthStateError),
}

impl ValidatedCallback {
    #[must_use]
    pub const fn state(&self) -> &OAuthState {
        match self {
            Self::Code { state, .. } | Self::Denied { state } => state,
        }
    }
}

pub fn validate_callback_query(
    params: &[(impl AsRef<str>, impl AsRef<str>)],
) -> Result<ValidatedCallback, CallbackValidationError> {
    let mut code: Option<&str> = None;
    let mut error: Option<&str> = None;
    let mut state: Option<&str> = None;

    for (key, value) in params {
        let value = value.as_ref();
        match key.as_ref() {
            "code" if code.replace(value).is_some() => {
                return Err(CallbackValidationError::DuplicateParameter("code"));
            }
            "code" => {
                code = Some(value);
            }
            "error" if error.replace(value).is_some() => {
                return Err(CallbackValidationError::DuplicateParameter("error"));
            }
            "error" => {
                error = Some(value);
            }
            "state" if state.replace(value).is_some() => {
                return Err(CallbackValidationError::DuplicateParameter("state"));
            }
            "state" => {
                state = Some(value);
            }
            _ => {}
        }
    }

    let state_raw = state.ok_or(CallbackValidationError::MissingState)?;
    if state_raw.len() > MAX_STATE_LEN {
        return Err(CallbackValidationError::OversizedValue("state"));
    }
    let state = OAuthState::parse(state_raw).map_err(CallbackValidationError::InvalidState)?;

    match (code, error) {
        (Some(code), None) => {
            if code.is_empty() || code.len() > MAX_CODE_LEN {
                return Err(CallbackValidationError::OversizedValue("code"));
            }
            Ok(ValidatedCallback::Code {
                code: AuthorizationCode::new(code.to_owned()),
                state,
            })
        }
        (None, Some(error)) => {
            if error.is_empty() || error.len() > MAX_ERROR_LEN {
                return Err(CallbackValidationError::OversizedValue("error"));
            }
            Ok(ValidatedCallback::Denied { state })
        }
        (Some(_), Some(_)) => Err(CallbackValidationError::AmbiguousOutcome),
        (None, None) => Err(CallbackValidationError::MissingOutcome),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::types::{AttemptId, CallbackSecret};

    fn sample_state() -> String {
        OAuthState::new(AttemptId([3; 16]), CallbackSecret::from_bytes([4; 32])).encode()
    }

    #[test]
    fn accepts_code_xor_error_with_state() {
        let state = sample_state();
        let code = validate_callback_query(&[("code", "abc"), ("state", &state)]).unwrap();
        match code {
            ValidatedCallback::Code { code, .. } => assert_eq!(code.as_str(), "abc"),
            ValidatedCallback::Denied { .. } => panic!("expected code"),
        }

        let denied =
            validate_callback_query(&[("error", "access_denied"), ("state", &state)]).unwrap();
        assert!(matches!(denied, ValidatedCallback::Denied { .. }));
    }

    #[test]
    fn rejects_duplicates_ambiguity_and_missing_pieces() {
        let state = sample_state();
        assert_eq!(
            validate_callback_query(&[("code", "a"), ("code", "b"), ("state", &state)]),
            Err(CallbackValidationError::DuplicateParameter("code"))
        );
        assert_eq!(
            validate_callback_query(&[("code", "a"), ("error", "x"), ("state", &state)]),
            Err(CallbackValidationError::AmbiguousOutcome)
        );
        assert_eq!(
            validate_callback_query(&[("code", "a")]),
            Err(CallbackValidationError::MissingState)
        );
        assert_eq!(
            validate_callback_query(&[("state", &state)]),
            Err(CallbackValidationError::MissingOutcome)
        );
    }
}
