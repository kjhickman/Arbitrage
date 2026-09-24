use crate::sign_in::{self, Session};

const SERVICE: &str = "arbitrage-companion";
const ACCOUNT: &str = "battlenet";

/// Stores the session JSON in the platform keychain.
///
/// # Errors
///
/// Returns an error when encoding fails or the platform store rejects the write.
pub fn save(session: &Session) -> keyring::Result<()> {
    let payload = serde_json::to_string(session)
        .map_err(|error| keyring::Error::PlatformFailure(Box::new(error)))?;
    entry()?.set_password(&payload)
}

/// Loads the stored session, if there is a readable one.
pub fn load() -> Option<Session> {
    let payload = entry().ok()?.get_password().ok()?;
    sign_in::decode_session(&payload)
}

/// Deletes the stored session.
///
/// # Errors
///
/// Returns an error when the platform store rejects the delete. Missing entries
/// are treated as success.
pub fn delete() -> keyring::Result<()> {
    match entry()?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(error),
    }
}

fn entry() -> keyring::Result<keyring::Entry> {
    keyring::Entry::new(SERVICE, ACCOUNT)
}
