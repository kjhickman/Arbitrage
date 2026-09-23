use std::{
    thread,
    time::{Duration, Instant},
};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::Deserialize;
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

impl Session {
    fn generate() -> Result<Self, SignInFailure> {
        Ok(Self {
            attempt_id: URL_SAFE_NO_PAD.encode(random_bytes::<16>()?),
            tray_secret: URL_SAFE_NO_PAD.encode(random_bytes::<32>()?),
        })
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
    let mut response = agent
        .get(endpoint(worker_url, &attempt_path(&session.attempt_id)))
        .header("authorization", &bearer(&session.tray_secret))
        .call()
        .map_err(|error| SignInFailure::Worker(error.to_string()))?;
    response
        .body_mut()
        .read_json()
        .map_err(|error| SignInFailure::Worker(error.to_string()))
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
}
