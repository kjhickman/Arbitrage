use arbitrage_shared::{SyncPayload, pivot};
use std::path::{Path, PathBuf};
use ureq::Agent;

use crate::{saved_variables, sign_in};

pub fn run(
    agent: &Agent,
    worker_url: &str,
    session: &sign_in::Session,
    path: &Path,
    roots: &[PathBuf],
) -> Result<(), String> {
    let own = saved_variables::load(path).map_err(|error| error.to_string())?;
    let body = pivot::to_payload(&own).to_json();

    let mut response = agent
        .post(sign_in::endpoint(worker_url, &session.sync_path()))
        .header("authorization", &session.authorization())
        .header("content-type", "application/json")
        .send(body)
        .map_err(|_| "Could not reach the worker.".to_owned())?;

    let status = response.status().as_u16();
    if !response.status().is_success() {
        return Err(message_for_http_status(status));
    }

    let text = response
        .body_mut()
        .read_to_string()
        .map_err(|_| "The worker returned a database the addon cannot store.".to_owned())?;
    let combined = SyncPayload::from_json(&text)
        .map_err(|_| "The worker returned a database the addon cannot store.".to_owned())?;
    saved_variables::publish_import(path, &pivot::to_database(&combined), roots)
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn message_for_http_status(status: u16) -> String {
    match status {
        401 => "Sign in again.".to_owned(),
        409 => "Sign in before syncing.".to_owned(),
        422 => "This database version is not supported.".to_owned(),
        400 => "The database could not be read.".to_owned(),
        other => format!("Sync failed (HTTP {other})."),
    }
}

#[cfg(test)]
mod tests {
    use super::message_for_http_status;

    #[test]
    fn maps_http_status_to_the_literal_sentences() {
        assert_eq!(message_for_http_status(401), "Sign in again.");
        assert_eq!(message_for_http_status(409), "Sign in before syncing.");
        assert_eq!(
            message_for_http_status(422),
            "This database version is not supported."
        );
        assert_eq!(
            message_for_http_status(400),
            "The database could not be read."
        );
        assert_eq!(message_for_http_status(500), "Sync failed (HTTP 500).");
        assert_eq!(message_for_http_status(503), "Sync failed (HTTP 503).");
    }
}
