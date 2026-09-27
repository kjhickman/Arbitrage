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
        let url = worker::Url::parse(trimmed).map_err(|_| OriginError::InvalidAuthority)?;
        if url.query().is_some() || url.fragment().is_some() || url.path() != "/" {
            return Err(OriginError::HasPathQueryOrFragment);
        }
        if !url.username().is_empty() || url.password().is_some() || url.host_str().is_none() {
            return Err(OriginError::InvalidAuthority);
        }
        if url.scheme() != "https"
            && (url.scheme() != "http"
                || !matches!(url.host_str(), Some("127.0.0.1" | "localhost")))
        {
            return Err(OriginError::NotHttps);
        }

        Ok(Self {
            origin: url.as_str().trim_end_matches('/').to_owned(),
        })
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
            PublicOrigin::parse("https://auth.example.com/").unwrap(),
            PublicOrigin::parse("https://auth.example.com").unwrap()
        );
    }
}
