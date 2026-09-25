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

/// Runs the browser sign-in and returns the new session with the signed-in account.
pub fn start(agent: &Agent, worker_url: &str) -> Option<(Session, Account)> {
    let session = Session::generate()?;
    let started = begin(agent, worker_url, &session)?;
    if !started.authorization_url.starts_with(AUTHORIZE_PREFIX) {
        return None;
    }
    open::that(&started.authorization_url).ok()?;

    let poll_after = Duration::from_millis(started.poll_after_ms.max(1_000));
    let deadline = Instant::now() + SIGN_IN_LIMIT;
    while Instant::now() < deadline {
        thread::sleep(poll_after);
        match status(agent, worker_url, &session)? {
            AttemptStatus::Pending => {}
            AttemptStatus::SignedIn { account } => return Some((session, account)),
            AttemptStatus::Denied | AttemptStatus::Expired | AttemptStatus::Failed => return None,
        }
    }
    None
}

pub fn sign_out(agent: &Agent, worker_url: &str, session: &Session) -> bool {
    agent
        .delete(endpoint(worker_url, &session.attempt_path()))
        .header("authorization", &session.authorization())
        .call()
        .is_ok_and(|response| response.status().is_success())
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
    fn generate() -> Option<Self> {
        Some(Self {
            attempt_id: URL_SAFE_NO_PAD.encode(random_bytes::<16>()?),
            tray_secret: URL_SAFE_NO_PAD.encode(random_bytes::<32>()?),
        })
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

fn begin(agent: &Agent, worker_url: &str, session: &Session) -> Option<BeginResponse> {
    let secret = URL_SAFE_NO_PAD.decode(&session.tray_secret).ok()?;
    let body = serde_json::json!({
        "tray_key_sha256": URL_SAFE_NO_PAD.encode(Sha256::digest(secret))
    });
    agent
        .post(endpoint(worker_url, &session.attempt_path()))
        .header("content-type", "application/json")
        .send_json(&body)
        .ok()?
        .body_mut()
        .read_json()
        .ok()
}

fn status(agent: &Agent, worker_url: &str, session: &Session) -> Option<AttemptStatus> {
    let mut response = agent
        .get(endpoint(worker_url, &session.attempt_path()))
        .header("authorization", &session.authorization())
        .call()
        .ok()?;
    if matches!(response.status().as_u16(), 401 | 404) {
        return None;
    }
    let body = response.body_mut().read_to_string().ok()?;
    serde_json::from_str(&body).ok()
}

pub fn endpoint(worker_url: &str, path: &str) -> String {
    format!(
        "{}/{}",
        worker_url.trim_end_matches('/'),
        path.trim_start_matches('/')
    )
}

fn random_bytes<const N: usize>() -> Option<[u8; N]> {
    let mut bytes = [0_u8; N];
    getrandom::getrandom(&mut bytes).ok()?;
    Some(bytes)
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
        let session = Session::generate().unwrap();
        assert_eq!(session.attempt_id.len(), 22);
        assert_eq!(session.tray_secret.len(), 43);
        assert_eq!(
            session.sync_path(),
            format!("v1/auth/battlenet/attempts/{}/sync", session.attempt_id)
        );
    }
}
