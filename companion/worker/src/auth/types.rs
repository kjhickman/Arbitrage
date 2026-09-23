use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use std::fmt;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Timestamp(pub u64);

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct AttemptId(pub [u8; 16]);

impl AttemptId {
    pub fn encode(&self) -> String {
        URL_SAFE_NO_PAD.encode(self.0)
    }

    pub fn parse(raw: &str) -> Result<Self, WireParseError> {
        Ok(Self(decode_fixed(raw)?))
    }
}

impl fmt::Debug for AttemptId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("AttemptId").field(&Hex(&self.0)).finish()
    }
}

#[derive(Clone, Copy)]
pub struct TraySecret([u8; 32]);

impl TraySecret {
    #[must_use]
    pub const fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    pub fn parse_bearer_token(raw: &str) -> Result<Self, WireParseError> {
        Ok(Self(decode_fixed(raw)?))
    }

    #[must_use]
    pub fn sha256(&self) -> Sha256Digest {
        digest_sha256(&self.0)
    }
}

impl fmt::Debug for TraySecret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TraySecret([redacted])")
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct CallbackSecret([u8; 32]);

impl CallbackSecret {
    #[must_use]
    pub const fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    #[must_use]
    pub fn sha256(&self) -> Sha256Digest {
        digest_sha256(&self.0)
    }

    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl fmt::Debug for CallbackSecret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("CallbackSecret([redacted])")
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct AuthorizationCode(String);

impl AuthorizationCode {
    #[must_use]
    pub const fn new(value: String) -> Self {
        Self(value)
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for AuthorizationCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AuthorizationCode([redacted])")
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Sha256Digest(pub [u8; 32]);

impl Sha256Digest {
    pub fn encode(&self) -> String {
        URL_SAFE_NO_PAD.encode(self.0)
    }

    pub fn parse(raw: &str) -> Result<Self, WireParseError> {
        Ok(Self(decode_fixed(raw)?))
    }
}

impl fmt::Debug for Sha256Digest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Sha256Digest").field(&Hex(&self.0)).finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireParseError {
    Malformed,
}

#[must_use]
pub fn digest_sha256(bytes: &[u8]) -> Sha256Digest {
    let digest = Sha256::digest(bytes);
    let mut out = [0_u8; 32];
    out.copy_from_slice(&digest);
    Sha256Digest(out)
}

#[must_use]
pub fn secrets_equal(a: &Sha256Digest, b: &Sha256Digest) -> bool {
    bool::from(a.0.ct_eq(&b.0))
}

fn decode_fixed<const N: usize>(value: &str) -> Result<[u8; N], WireParseError> {
    let decoded = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| WireParseError::Malformed)?;
    decoded
        .as_slice()
        .try_into()
        .map_err(|_| WireParseError::Malformed)
}

struct Hex<'a>(&'a [u8]);

impl fmt::Debug for Hex<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for byte in self.0 {
            write!(f, "{byte:02x}")?;
        }
        Ok(())
    }
}
