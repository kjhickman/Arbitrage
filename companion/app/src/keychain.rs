use crate::sign_in::{self, Session};

const SERVICE: &str = "arbitrage-companion";
const ACCOUNT: &str = "battlenet";

#[derive(Debug)]
pub enum Error {
    Keyring,
    Codec,
}

/// Stores the session JSON in the platform keychain.
///
/// # Errors
///
/// Returns an error when encoding fails or the platform store rejects the write.
pub fn save(session: &Session) -> Result<(), Error> {
    let payload = sign_in::encode_session(session).map_err(|_| Error::Codec)?;
    entry()?.set_password(&payload).map_err(|_| Error::Keyring)
}

/// Loads the stored session, if any.
///
/// # Errors
///
/// Returns an error when the platform store fails or the stored JSON is invalid.
pub fn load() -> Result<Option<Session>, Error> {
    match entry()?.get_password() {
        Ok(payload) => Ok(Some(
            sign_in::decode_session(&payload).map_err(|_| Error::Codec)?,
        )),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(_) => Err(Error::Keyring),
    }
}

/// Deletes the stored session.
///
/// # Errors
///
/// Returns an error when the platform store rejects the delete. Missing entries
/// are treated as success.
pub fn delete() -> Result<(), Error> {
    match entry()?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(_) => Err(Error::Keyring),
    }
}

fn entry() -> Result<keyring::Entry, Error> {
    keyring::Entry::new(SERVICE, ACCOUNT).map_err(|_| Error::Keyring)
}
