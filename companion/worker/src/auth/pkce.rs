use std::fmt;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};

use crate::auth::types::digest_sha256;

#[derive(Clone, PartialEq, Eq)]
pub struct PkceVerifier(String);

impl PkceVerifier {
    #[must_use]
    pub fn from_entropy(bytes: [u8; 32]) -> Self {
        Self(URL_SAFE_NO_PAD.encode(bytes))
    }

    pub(crate) fn from_persisted(
        value: String,
    ) -> Result<Self, crate::auth::persist::PersistError> {
        let length = value.len();
        let unreserved = value.bytes().all(|byte| {
            matches!(
                byte,
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~'
            )
        });
        if !(43..=128).contains(&length) || !unreserved {
            return Err(crate::auth::persist::PersistError::Malformed);
        }
        Ok(Self(value))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for PkceVerifier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("PkceVerifier([redacted])")
    }
}

#[must_use]
pub fn pkce_s256_challenge(verifier: &PkceVerifier) -> String {
    let digest = digest_sha256(verifier.as_str().as_bytes());
    URL_SAFE_NO_PAD.encode(digest.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn s256_challenge_matches_rfc7636_appendix_b() {
        let verifier = PkceVerifier(String::from("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));
        assert_eq!(
            pkce_s256_challenge(&verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }
}
