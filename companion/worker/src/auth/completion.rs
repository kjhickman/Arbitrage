pub const COMPLETION_PATH: &str = "/oauth/battlenet/complete";

const COMPLETION_BODY: &str = concat!(
    "<!DOCTYPE html><html lang=\"en\"><head>",
    "<meta charset=\"utf-8\">",
    "<meta name=\"referrer\" content=\"no-referrer\">",
    "<title>Sign-in complete</title>",
    "</head><body>",
    "<p>You can close this window and return to Arbitrage.</p>",
    "</body></html>"
);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrowserCompletionRedirect {
    pub status: u16,
    pub location: String,
    pub cache_control: &'static str,
    pub referrer_policy: &'static str,
}

impl BrowserCompletionRedirect {
    #[must_use]
    pub const fn to_completion_page(completion_uri: String) -> Self {
        Self {
            status: 303,
            location: completion_uri,
            cache_control: "no-store",
            referrer_policy: "no-referrer",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompletionPage {
    pub status: u16,
    pub cache_control: &'static str,
    pub referrer_policy: &'static str,
    pub content_security_policy: &'static str,
    pub content_type: &'static str,
    pub body: &'static str,
}

#[must_use]
pub const fn completion_page() -> CompletionPage {
    CompletionPage {
        status: 200,
        cache_control: "no-store",
        referrer_policy: "no-referrer",
        content_security_policy: "default-src 'none'; base-uri 'none'; form-action 'none'",
        content_type: "text/html; charset=utf-8",
        body: COMPLETION_BODY,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redirect_is_303_no_store_without_oauth_material() {
        let redirect = BrowserCompletionRedirect::to_completion_page(
            "https://auth.example.com/oauth/battlenet/complete".to_owned(),
        );
        assert_eq!(redirect.status, 303);
        assert_eq!(redirect.cache_control, "no-store");
        assert_eq!(
            redirect.location,
            "https://auth.example.com/oauth/battlenet/complete"
        );
        assert!(!redirect.location.contains("code="));
        assert!(!redirect.location.contains("state="));
        assert!(!redirect.location.contains("token"));
    }

    #[test]
    fn completion_page_has_no_account_or_secret_fields() {
        let page = completion_page();
        assert_eq!(page.status, 200);
        assert_eq!(page.cache_control, "no-store");
        assert_eq!(
            page.content_security_policy,
            "default-src 'none'; base-uri 'none'; form-action 'none'"
        );
        assert!(!page.body.contains("code="));
        assert!(!page.body.contains("state="));
        assert!(!page.body.contains("token"));
        assert!(!page.body.contains("account"));
        assert!(!page.body.to_ascii_lowercase().contains("battlenet"));
    }
}
