use std::{
    thread,
    time::{Duration, Instant},
};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use ureq::Agent;

const AUTHORIZE_PREFIX: &str = "https://oauth.battle.net/authorize?";
const SIGN_IN_LIMIT: Duration = Duration::from_mins(10);

#[derive(Clone)]
pub struct Session {
    attempt_id: String,
    tray_secret: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignedInAccount {
    pub battletag: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignInFailure {
    Worker(String),
    Denied,
    Expired,
    Failed,
    Browser,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resume {
    SignedIn { battletag: String },
    Forget,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionCodecError {
    EmptyField,
    InvalidJson,
}

#[derive(Serialize, Deserialize)]
struct StoredSession {
    attempt_id: String,
    tray_secret: String,
}

pub fn start(agent: &Agent, worker_url: &str) -> Result<(Session, SignedInAccount), SignInFailure> {
    let session = Session::generate()?;
    let started = begin(agent, worker_url, &session)?;
    if !started.authorization_url.starts_with(AUTHORIZE_PREFIX) {
        return Err(SignInFailure::Worker(
            "Worker returned an unexpected Battle.net address.".to_owned(),
        ));
    }
    open::that(&started.authorization_url).map_err(|_| SignInFailure::Browser)?;

    let poll_after = Duration::from_millis(started.poll_after_ms.max(1_000));
    let deadline = Instant::now() + SIGN_IN_LIMIT;
    while Instant::now() < deadline {
        thread::sleep(poll_after);
        match status(agent, worker_url, &session)? {
            AttemptStatus::Pending => {}
            AttemptStatus::SignedIn { account } => {
                return Ok((
                    session,
                    SignedInAccount {
                        battletag: account.battletag,
                    },
                ));
            }
            AttemptStatus::Denied => return Err(SignInFailure::Denied),
            AttemptStatus::Expired => return Err(SignInFailure::Expired),
            AttemptStatus::Failed => return Err(SignInFailure::Failed),
        }
    }
    Err(SignInFailure::Expired)
}

pub fn sign_out(agent: &Agent, worker_url: &str, session: &Session) -> Result<(), SignInFailure> {
    let response = agent
        .delete(endpoint(worker_url, &attempt_path(&session.attempt_id)))
        .header("authorization", &bearer(&session.tray_secret))
        .call()
        .map_err(|error| SignInFailure::Worker(error.to_string()))?;
    if response.status().as_u16() == 204 || response.status().is_success() {
        Ok(())
    } else {
        Err(SignInFailure::Worker(format!(
            "Sign-out returned HTTP {}.",
            response.status()
        )))
    }
}

pub fn resume(agent: &Agent, worker_url: &str, session: &Session) -> Resume {
    match agent
        .get(endpoint(worker_url, &attempt_path(&session.attempt_id)))
        .header("authorization", &bearer(&session.tray_secret))
        .call()
    {
        Ok(mut response) => {
            let status = response.status().as_u16();
            let body = response.body_mut().read_to_string().unwrap_or_default();
            decide_resume(status, &body)
        }
        Err(ureq::Error::StatusCode(status)) => decide_resume(status, ""),
        Err(_) => Resume::Unavailable,
    }
}

pub fn decide_resume(status: u16, body: &str) -> Resume {
    match status {
        200 => match serde_json::from_str::<AttemptStatus>(body) {
            Ok(AttemptStatus::SignedIn { account }) => Resume::SignedIn {
                battletag: account.battletag,
            },
            Ok(
                AttemptStatus::Pending
                | AttemptStatus::Denied
                | AttemptStatus::Expired
                | AttemptStatus::Failed,
            )
            | Err(_) => Resume::Forget,
        },
        401 | 404 => Resume::Forget,
        _ => Resume::Unavailable,
    }
}

/// Encodes a session as the keychain JSON payload.
///
/// # Errors
///
/// Returns [`SessionCodecError::EmptyField`] when either field is empty, or
/// [`SessionCodecError::InvalidJson`] when encoding fails.
pub fn encode_session(session: &Session) -> Result<String, SessionCodecError> {
    if session.attempt_id.is_empty() || session.tray_secret.is_empty() {
        return Err(SessionCodecError::EmptyField);
    }
    serde_json::to_string(&StoredSession {
        attempt_id: session.attempt_id.clone(),
        tray_secret: session.tray_secret.clone(),
    })
    .map_err(|_| SessionCodecError::InvalidJson)
}

/// Decodes a keychain JSON payload into a session.
///
/// # Errors
///
/// Returns [`SessionCodecError::InvalidJson`] when the payload is not valid JSON,
/// or [`SessionCodecError::EmptyField`] when either field is empty.
pub fn decode_session(json: &str) -> Result<Session, SessionCodecError> {
    let stored: StoredSession =
        serde_json::from_str(json).map_err(|_| SessionCodecError::InvalidJson)?;
    Session::from_parts(stored.attempt_id, stored.tray_secret)
}

impl Session {
    /// Builds a session from stored parts.
    ///
    /// # Errors
    ///
    /// Returns [`SessionCodecError::EmptyField`] when either field is empty.
    pub fn from_parts(attempt_id: String, tray_secret: String) -> Result<Self, SessionCodecError> {
        if attempt_id.is_empty() || tray_secret.is_empty() {
            return Err(SessionCodecError::EmptyField);
        }
        Ok(Self {
            attempt_id,
            tray_secret,
        })
    }

    fn generate() -> Result<Self, SignInFailure> {
        Self::from_parts(
            URL_SAFE_NO_PAD.encode(random_bytes::<16>()?),
            URL_SAFE_NO_PAD.encode(random_bytes::<32>()?),
        )
        .map_err(|_| SignInFailure::Worker("Could not create a sign-in session.".to_owned()))
    }

    pub fn authorization(&self) -> String {
        bearer(&self.tray_secret)
    }

    pub fn sync_path(&self) -> String {
        format!("v1/auth/battlenet/attempts/{}/sync", self.attempt_id)
    }
}

#[derive(Deserialize)]
struct BeginResponse {
    authorization_url: String,
    poll_after_ms: u64,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum AttemptStatus {
    Pending,
    SignedIn { account: AccountBody },
    Denied,
    Expired,
    Failed,
}

#[derive(Debug, Deserialize)]
struct AccountBody {
    battletag: String,
}

fn begin(
    agent: &Agent,
    worker_url: &str,
    session: &Session,
) -> Result<BeginResponse, SignInFailure> {
    let secret = URL_SAFE_NO_PAD
        .decode(&session.tray_secret)
        .map_err(|_| SignInFailure::Worker("Could not encode the sign-in secret.".to_owned()))?;
    let body = serde_json::json!({
        "tray_key_sha256": URL_SAFE_NO_PAD.encode(Sha256::digest(secret))
    });
    let mut response = agent
        .post(endpoint(worker_url, &attempt_path(&session.attempt_id)))
        .header("content-type", "application/json")
        .send_json(&body)
        .map_err(|error| SignInFailure::Worker(error.to_string()))?;
    response
        .body_mut()
        .read_json()
        .map_err(|error| SignInFailure::Worker(error.to_string()))
}

fn status(
    agent: &Agent,
    worker_url: &str,
    session: &Session,
) -> Result<AttemptStatus, SignInFailure> {
    match agent
        .get(endpoint(worker_url, &attempt_path(&session.attempt_id)))
        .header("authorization", &bearer(&session.tray_secret))
        .call()
    {
        Ok(mut response) => {
            let code = response.status().as_u16();
            if matches!(code, 401 | 404) {
                return Err(SignInFailure::Failed);
            }
            let body = response
                .body_mut()
                .read_to_string()
                .map_err(|error| SignInFailure::Worker(error.to_string()))?;
            serde_json::from_str(&body).map_err(|error| SignInFailure::Worker(error.to_string()))
        }
        Err(ureq::Error::StatusCode(401 | 404)) => Err(SignInFailure::Failed),
        Err(error) => Err(SignInFailure::Worker(error.to_string())),
    }
}

fn attempt_path(attempt_id: &str) -> String {
    format!("v1/auth/battlenet/attempts/{attempt_id}")
}

pub fn endpoint(worker_url: &str, path: &str) -> String {
    format!(
        "{}/{}",
        worker_url.trim_end_matches('/'),
        path.trim_start_matches('/')
    )
}

fn bearer(tray_secret: &str) -> String {
    format!("Bearer {tray_secret}")
}

fn random_bytes<const N: usize>() -> Result<[u8; N], SignInFailure> {
    let mut bytes = [0_u8; N];
    getrandom::getrandom(&mut bytes).map_err(|_| {
        SignInFailure::Worker("The system random number generator is unavailable.".to_owned())
    })?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joins_the_worker_origin_to_the_attempt_path() {
        assert_eq!(
            endpoint("http://127.0.0.1:8787/", "v1/auth/battlenet/attempts/abc"),
            "http://127.0.0.1:8787/v1/auth/battlenet/attempts/abc"
        );
    }

    #[test]
    fn reads_a_signed_in_account_without_tokens() {
        let status: AttemptStatus = serde_json::from_str(
            r#"{"status":"signed_in","account":{"id":"42","battletag":"Player#42"}}"#,
        )
        .unwrap();
        match status {
            AttemptStatus::SignedIn { account } => assert_eq!(account.battletag, "Player#42"),
            other => panic!("expected signed in, got {other:?}"),
        }
    }

    #[test]
    fn decide_resume_keeps_a_signed_in_attempt() {
        assert_eq!(
            decide_resume(
                200,
                r#"{"status":"signed_in","account":{"id":"42","battletag":"Player#42"}}"#,
            ),
            Resume::SignedIn {
                battletag: "Player#42".to_owned(),
            }
        );
    }

    #[test]
    fn decide_resume_forgets_terminal_and_pending_attempts() {
        for body in [
            r#"{"status":"pending"}"#,
            r#"{"status":"denied"}"#,
            r#"{"status":"expired"}"#,
            r#"{"status":"failed"}"#,
        ] {
            assert_eq!(decide_resume(200, body), Resume::Forget);
        }
    }

    #[test]
    fn decide_resume_forgets_missing_or_unauthorized_attempts() {
        assert_eq!(decide_resume(401, ""), Resume::Forget);
        assert_eq!(decide_resume(404, ""), Resume::Forget);
    }

    #[test]
    fn decide_resume_marks_worker_failures_unavailable() {
        assert_eq!(decide_resume(500, ""), Resume::Unavailable);
        assert_eq!(decide_resume(503, ""), Resume::Unavailable);
    }

    #[test]
    fn decide_resume_forgets_a_non_json_success_body() {
        assert_eq!(decide_resume(200, "not-json"), Resume::Forget);
    }

    #[test]
    fn session_json_round_trips_literal_parts() {
        let session =
            Session::from_parts("attempt-literal".to_owned(), "secret-literal".to_owned()).unwrap();
        let encoded = encode_session(&session).unwrap();
        assert_eq!(
            encoded,
            r#"{"attempt_id":"attempt-literal","tray_secret":"secret-literal"}"#
        );
        let decoded = decode_session(&encoded).unwrap();
        assert_eq!(encode_session(&decoded).unwrap(), encoded);
    }

    #[test]
    fn session_json_rejects_empty_fields() {
        assert!(matches!(
            decode_session(r#"{"attempt_id":"","tray_secret":"secret"}"#),
            Err(SessionCodecError::EmptyField)
        ));
        assert!(matches!(
            decode_session(r#"{"attempt_id":"attempt","tray_secret":""}"#),
            Err(SessionCodecError::EmptyField)
        ));
        assert!(matches!(
            Session::from_parts(String::new(), "secret".to_owned()),
            Err(SessionCodecError::EmptyField)
        ));
    }
}
