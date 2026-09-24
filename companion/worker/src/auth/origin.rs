pub const CALLBACK_PATH: &str = "/oauth/battlenet/callback";
pub const COMPLETION_PATH: &str = "/oauth/battlenet/complete";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublicOrigin {
    origin: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OriginError {
    Empty,
    NotHttps,
    HasPathQueryOrFragment,
    InvalidAuthority,
}

impl PublicOrigin {
    pub fn parse(raw: &str) -> Result<Self, OriginError> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return Err(OriginError::Empty);
        }
        if trimmed.contains(['?', '#']) {
            return Err(OriginError::HasPathQueryOrFragment);
        }

        if let Some(authority) = trimmed.strip_prefix("http://") {
            return loopback_origin(authority);
        }

        let without_scheme = trimmed
            .strip_prefix("https://")
            .ok_or(OriginError::NotHttps)?;

        if without_scheme.contains('@') {
            return Err(OriginError::InvalidAuthority);
        }
        if without_scheme.is_empty() || without_scheme.contains('/') {
            return Err(OriginError::HasPathQueryOrFragment);
        }
        if without_scheme.starts_with('[') {
            let end = without_scheme
                .find(']')
                .ok_or(OriginError::InvalidAuthority)?;
            let rest = &without_scheme[end + 1..];
            if !(rest.is_empty()
                || (rest.starts_with(':') && rest[1..].bytes().all(|b| b.is_ascii_digit())))
            {
                return Err(OriginError::InvalidAuthority);
            }
        }

        let origin = format!("https://{without_scheme}");
        Ok(Self { origin })
    }

    #[must_use]
    pub fn redirect_uri(&self) -> String {
        format!("{}{CALLBACK_PATH}", self.origin)
    }

    #[must_use]
    pub fn completion_uri(&self) -> String {
        format!("{}{COMPLETION_PATH}", self.origin)
    }
}

fn loopback_origin(authority: &str) -> Result<PublicOrigin, OriginError> {
    if authority.contains(['/', '@', '?', '#']) {
        return Err(OriginError::HasPathQueryOrFragment);
    }
    let (host, port) = match authority.split_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (authority, None),
    };
    if host != "127.0.0.1" && host != "localhost" {
        return Err(OriginError::NotHttps);
    }
    if let Some(port) = port
        && (port.is_empty() || !port.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return Err(OriginError::InvalidAuthority);
    }
    Ok(PublicOrigin {
        origin: format!("http://{authority}"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derives_callback_and_completion_from_one_origin() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        assert_eq!(
            origin.redirect_uri(),
            "https://auth.example.com/oauth/battlenet/callback"
        );
        assert_eq!(
            origin.completion_uri(),
            "https://auth.example.com/oauth/battlenet/complete"
        );
    }

    #[test]
    fn rejects_separately_shaped_redirect_strings() {
        assert_eq!(
            PublicOrigin::parse("https://auth.example.com/oauth/battlenet/callback"),
            Err(OriginError::HasPathQueryOrFragment)
        );
        assert_eq!(
            PublicOrigin::parse("http://auth.example.com"),
            Err(OriginError::NotHttps)
        );
        let local = PublicOrigin::parse("http://127.0.0.1:8787").unwrap();
        assert_eq!(
            local.redirect_uri(),
            "http://127.0.0.1:8787/oauth/battlenet/callback"
        );
        assert_eq!(
            PublicOrigin::parse("https://user@auth.example.com"),
            Err(OriginError::InvalidAuthority)
        );
        assert_eq!(
            PublicOrigin::parse("https://auth.example.com/"),
            Err(OriginError::HasPathQueryOrFragment)
        );
    }
}
