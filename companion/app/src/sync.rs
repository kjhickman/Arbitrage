use arbitrage_shared::{SyncPayload, pivot};
use std::{
    fmt,
    path::{Path, PathBuf},
};
use ureq::Agent;

use crate::{saved_variables, sign_in};

#[derive(Debug)]
pub enum Error {
    Load(saved_variables::LoadError),
    Unreachable,
    Rejected(u16),
    UnusableResponse,
    Publish(saved_variables::PublishError),
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Load(error) => error.fmt(formatter),
            Self::Unreachable => formatter.write_str("Could not reach the worker."),
            Self::Rejected(401) => formatter.write_str("Sign in again."),
            Self::Rejected(409) => formatter.write_str("Sign in before syncing."),
            Self::Rejected(422) => formatter.write_str("This database version is not supported."),
            Self::Rejected(400) => formatter.write_str("The database could not be read."),
            Self::Rejected(status) => write!(formatter, "Sync failed (HTTP {status})."),
            Self::UnusableResponse => {
                formatter.write_str("The worker returned a database the addon cannot store.")
            }
            Self::Publish(error) => error.fmt(formatter),
        }
    }
}

/// Uploads the account's own database and publishes the combined one the worker returns.
///
/// # Errors
///
/// Returns an [`Error`] naming the step that failed.
pub fn run(
    agent: &Agent,
    worker_url: &str,
    session: &sign_in::Session,
    path: &Path,
    roots: &[PathBuf],
) -> Result<(), Error> {
    let own = saved_variables::load(path).map_err(Error::Load)?;
    let body = pivot::to_payload(&own).to_json();

    let text = agent
        .post(sign_in::endpoint(worker_url, &session.sync_path()))
        .header("authorization", &session.authorization())
        .header("content-type", "application/json")
        .send(body)
        .map_err(|error| transport_error(&error))?
        .body_mut()
        .read_to_string()
        .map_err(|_| Error::UnusableResponse)?;
    let combined = SyncPayload::from_json(&text).map_err(|_| Error::UnusableResponse)?;
    saved_variables::publish_import(path, &pivot::to_database(&combined), roots)
        .map_err(Error::Publish)
}

/// ureq reports 4xx and 5xx as errors, so those must stay distinct from a failed connection.
const fn transport_error(error: &ureq::Error) -> Error {
    match *error {
        ureq::Error::StatusCode(status) => Error::Rejected(status),
        _ => Error::Unreachable,
    }
}

#[cfg(test)]
mod tests {
    use super::{Error, transport_error};

    #[test]
    fn rejections_read_as_the_literal_sentences() {
        let message = |status| Error::Rejected(status).to_string();
        assert_eq!(message(401), "Sign in again.");
        assert_eq!(message(409), "Sign in before syncing.");
        assert_eq!(message(422), "This database version is not supported.");
        assert_eq!(message(400), "The database could not be read.");
        assert_eq!(message(500), "Sync failed (HTTP 500).");
        assert_eq!(message(503), "Sync failed (HTTP 503).");
    }

    #[test]
    fn an_http_error_is_not_reported_as_a_connection_failure() {
        assert!(matches!(
            transport_error(&ureq::Error::StatusCode(422)),
            Error::Rejected(422)
        ));
        assert!(matches!(
            transport_error(&ureq::Error::ConnectionFailed),
            Error::Unreachable
        ));
    }
}
