use std::{
    fmt, thread,
    time::{Duration, Instant},
};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use ureq::Agent;

const AUTHORIZE_PREFIX: &str = "https://oauth.battle.net/authorize?";
const SIGN_IN_LIMIT: Duration = Duration::from_mins(10);

#[derive(Clone, Serialize, Deserialize)]
pub struct Session {
    attempt_id: String,
    tray_secret: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resume {
    SignedIn { account: Account },
    Forget,
    Unavailable,
}

#[derive(Debug)]
pub enum Error {
    Random(getrandom::Error),
    Unreachable,
    Status(u16),
    UnexpectedResponse,
    UntrustedAuthorizationUrl,
    Browser,
    Denied,
    Expired,
    Failed,
    /// The worker no longer recognizes the attempt, or the secret no longer proves it.
    Forgotten,
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Random(error) => write!(formatter, "Couldn't generate a sign-in key ({error})."),
            Self::Unreachable => formatter.write_str("Couldn't reach the Arbitrage server."),
            Self::Status(status) => {
                write!(formatter, "The Arbitrage server returned HTTP {status}.")
            }
            Self::UnexpectedResponse => {
                formatter.write_str("The Arbitrage server returned an unexpected response.")
            }
            Self::UntrustedAuthorizationUrl => {
                formatter.write_str("The Arbitrage server sent an unexpected sign-in link.")
            }
            Self::Browser => formatter.write_str("Couldn't open your web browser."),
            Self::Denied => formatter.write_str("Battle.net sign-in was cancelled."),
            Self::Expired => formatter.write_str("Sign-in timed out. Try again."),
            Self::Failed => formatter.write_str("Battle.net couldn't complete the sign-in."),
            Self::Forgotten => formatter.write_str("This sign-in is no longer valid. Try again."),
        }
    }
}

/// Runs the browser sign-in and returns the new session with the signed-in account.
///
/// # Errors
///
/// Returns an [`Error`] naming the step that failed or how Battle.net ended the attempt.
pub fn start(agent: &Agent, worker_url: &str) -> Result<(Session, Account), Error> {
    let (session, tray_key_sha256) = Session::generate()?;
    let started = begin(agent, worker_url, &session, &tray_key_sha256)?;
    if !started.authorization_url.starts_with(AUTHORIZE_PREFIX) {
        return Err(Error::UntrustedAuthorizationUrl);
    }
    open::that(&started.authorization_url).map_err(|_| Error::Browser)?;

    let poll_after = Duration::from_millis(started.poll_after_ms.max(1_000));
    let deadline = Instant::now() + SIGN_IN_LIMIT;
    while Instant::now() < deadline {
        thread::sleep(poll_after);
        match status(agent, worker_url, &session)? {
            AttemptStatus::Pending => {}
            AttemptStatus::SignedIn { account } => return Ok((session, account)),
            AttemptStatus::Denied => return Err(Error::Denied),
            AttemptStatus::Expired => return Err(Error::Expired),
            AttemptStatus::Failed => return Err(Error::Failed),
        }
    }
    Err(Error::Expired)
}

/// Revokes the session on the worker.
///
/// # Errors
///
/// Returns [`Error::Forgotten`] when the worker already has no such session, or another
/// [`Error`] when the request fails.
pub fn sign_out(agent: &Agent, worker_url: &str, session: &Session) -> Result<(), Error> {
    agent
        .delete(endpoint(worker_url, &session.attempt_path()))
        .header("authorization", &session.authorization())
        .call()
        .map(drop)
        .map_err(|error| request_error(&error))
}

pub fn resume(agent: &Agent, worker_url: &str, session: &Session) -> Resume {
    match agent
        .get(endpoint(worker_url, &session.attempt_path()))
        .header("authorization", &session.authorization())
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

fn decide_resume(status: u16, body: &str) -> Resume {
    match status {
        200 => match serde_json::from_str::<AttemptStatus>(body) {
            Ok(AttemptStatus::SignedIn { account }) => Resume::SignedIn { account },
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

/// Decodes a keychain JSON payload, rejecting a session with an empty field.
pub fn decode_session(json: &str) -> Option<Session> {
    serde_json::from_str::<Session>(json)
        .ok()
        .filter(|session| !session.attempt_id.is_empty() && !session.tray_secret.is_empty())
}

impl Session {
    /// Returns a fresh session with the SHA-256 of its tray secret, which is what the worker
    /// stores.
    fn generate() -> Result<(Self, String), Error> {
        let tray_secret = random_bytes::<32>()?;
        let session = Self {
            attempt_id: URL_SAFE_NO_PAD.encode(random_bytes::<16>()?),
            tray_secret: URL_SAFE_NO_PAD.encode(tray_secret),
        };
        Ok((session, URL_SAFE_NO_PAD.encode(Sha256::digest(tray_secret))))
    }

    pub fn authorization(&self) -> String {
        format!("Bearer {}", self.tray_secret)
    }

    fn attempt_path(&self) -> String {
        format!("v1/auth/battlenet/attempts/{}", self.attempt_id)
    }

    pub fn sync_path(&self) -> String {
        format!("{}/sync", self.attempt_path())
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
    SignedIn { account: Account },
    Denied,
    Expired,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Account {
    pub id: String,
    pub battletag: String,
}

fn begin(
    agent: &Agent,
    worker_url: &str,
    session: &Session,
    tray_key_sha256: &str,
) -> Result<BeginResponse, Error> {
    let body = serde_json::json!({ "tray_key_sha256": tray_key_sha256 });
    agent
        .post(endpoint(worker_url, &session.attempt_path()))
        .header("content-type", "application/json")
        .send_json(&body)
        .map_err(|error| request_error(&error))?
        .body_mut()
        .read_json()
        .map_err(|_| Error::UnexpectedResponse)
}

fn status(agent: &Agent, worker_url: &str, session: &Session) -> Result<AttemptStatus, Error> {
    let body = agent
        .get(endpoint(worker_url, &session.attempt_path()))
        .header("authorization", &session.authorization())
        .call()
        .map_err(|error| request_error(&error))?
        .body_mut()
        .read_to_string()
        .map_err(|_| Error::UnexpectedResponse)?;
    serde_json::from_str(&body).map_err(|_| Error::UnexpectedResponse)
}

const fn request_error(error: &ureq::Error) -> Error {
    match *error {
        ureq::Error::StatusCode(401 | 404) => Error::Forgotten,
        ureq::Error::StatusCode(status) => Error::Status(status),
        _ => Error::Unreachable,
    }
}

pub fn endpoint(worker_url: &str, path: &str) -> String {
    format!(
        "{}/{}",
        worker_url.trim_end_matches('/'),
        path.trim_start_matches('/')
    )
}

fn random_bytes<const N: usize>() -> Result<[u8; N], Error> {
    let mut bytes = [0_u8; N];
    getrandom::getrandom(&mut bytes).map_err(Error::Random)?;
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
            AttemptStatus::SignedIn { account } => assert_eq!(
                account,
                Account {
                    id: "42".to_owned(),
                    battletag: "Player#42".to_owned(),
                }
            ),
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
                account: Account {
                    id: "42".to_owned(),
                    battletag: "Player#42".to_owned(),
                },
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
    fn missing_or_unauthorized_attempts_are_forgotten_not_failed_requests() {
        assert!(matches!(
            request_error(&ureq::Error::StatusCode(401)),
            Error::Forgotten
        ));
        assert!(matches!(
            request_error(&ureq::Error::StatusCode(404)),
            Error::Forgotten
        ));
        assert!(matches!(
            request_error(&ureq::Error::StatusCode(409)),
            Error::Status(409)
        ));
        assert!(matches!(
            request_error(&ureq::Error::ConnectionFailed),
            Error::Unreachable
        ));
    }

    #[test]
    fn session_json_round_trips_literal_parts() {
        let stored = r#"{"attempt_id":"attempt-literal","tray_secret":"secret-literal"}"#;
        let session = decode_session(stored).unwrap();
        assert_eq!(session.attempt_id, "attempt-literal");
        assert_eq!(session.tray_secret, "secret-literal");
        assert_eq!(serde_json::to_string(&session).unwrap(), stored);
    }

    #[test]
    fn session_json_rejects_empty_fields_and_bad_json() {
        assert!(decode_session(r#"{"attempt_id":"","tray_secret":"secret"}"#).is_none());
        assert!(decode_session(r#"{"attempt_id":"attempt","tray_secret":""}"#).is_none());
        assert!(decode_session("not-json").is_none());
    }

    #[test]
    fn generated_sessions_have_both_parts() {
        let (session, tray_key_sha256) = Session::generate().unwrap();
        assert_eq!(session.attempt_id.len(), 22);
        assert_eq!(session.tray_secret.len(), 43);
        assert_eq!(
            tray_key_sha256,
            URL_SAFE_NO_PAD.encode(Sha256::digest(
                URL_SAFE_NO_PAD.decode(&session.tray_secret).unwrap()
            ))
        );
        assert_eq!(
            session.sync_path(),
            format!("v1/auth/battlenet/attempts/{}/sync", session.attempt_id)
        );
    }
}
