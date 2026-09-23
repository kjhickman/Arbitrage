use std::cell::Cell;
use std::fmt;

use crate::auth::oauth_state::OAuthState;
use crate::auth::origin::PublicOrigin;
use crate::auth::pkce::{PkceVerifier, pkce_s256_challenge};
use crate::auth::types::{AuthorizationCode, Timestamp};

pub const BATTLE_NET_TOKEN_ENDPOINT: &str = "https://oauth.battle.net/token";
pub const BATTLE_NET_USERINFO_ENDPOINT: &str = "https://oauth.battle.net/userinfo";
pub const BATTLE_NET_SCOPE: &str = "openid";

#[derive(Clone)]
pub struct BattleNetTokenSet {
    pub access_token: String,
    pub token_type: BearerTokenType,
    pub access_expires_at: Timestamp,
    pub refresh_token: Option<String>,
    pub granted_scopes: String,
}

impl fmt::Debug for BattleNetTokenSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BattleNetTokenSet")
            .field("access_token", &"[redacted]")
            .field("token_type", &self.token_type)
            .field("access_expires_at", &self.access_expires_at)
            .field(
                "refresh_token",
                &self.refresh_token.as_ref().map(|_| "[redacted]"),
            )
            .field("granted_scopes", &self.granted_scopes)
            .finish()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BearerTokenType {
    Bearer,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AccountSummary {
    pub id: String,
    pub battletag: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderError {
    Denied,
    InvalidGrant,
    UnexpectedResponse,
    Unavailable,
}

#[derive(Clone, PartialEq, Eq)]
pub struct TokenExchangeRequest {
    pub code: AuthorizationCode,
    pub redirect_uri: String,
    pub code_verifier: String,
}

impl fmt::Debug for TokenExchangeRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TokenExchangeRequest")
            .field("code", &self.code)
            .field("redirect_uri", &self.redirect_uri)
            .field("code_verifier", &"[redacted]")
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthorizationUrlParts {
    pub client_id: String,
    pub redirect_uri: String,
    pub scope: String,
    pub state: String,
    pub code_challenge: String,
    pub code_challenge_method: &'static str,
}

#[derive(Debug, Clone)]
pub enum FakeExchangeOutcome {
    Success {
        tokens: BattleNetTokenSet,
        account: AccountSummary,
    },
    ExchangeFailure(ProviderError),
}

#[derive(Debug)]
pub struct FakeBattleNetClient {
    outcome: FakeExchangeOutcome,
    exchange_calls: Cell<u32>,
}

impl FakeBattleNetClient {
    #[must_use]
    pub const fn new(outcome: FakeExchangeOutcome) -> Self {
        Self {
            outcome,
            exchange_calls: Cell::new(0),
        }
    }

    #[must_use]
    pub const fn exchange_calls(&self) -> u32 {
        self.exchange_calls.get()
    }

    pub fn exchange(
        &self,
        _request: &TokenExchangeRequest,
    ) -> Result<BattleNetTokenSet, ProviderError> {
        self.exchange_calls.set(self.exchange_calls.get() + 1);
        match &self.outcome {
            FakeExchangeOutcome::Success { tokens, .. } => Ok(tokens.clone()),
            FakeExchangeOutcome::ExchangeFailure(error) => Err(error.clone()),
        }
    }

    pub fn identity(&self, _access_token: &str) -> Result<AccountSummary, ProviderError> {
        match &self.outcome {
            FakeExchangeOutcome::Success { account, .. } => Ok(account.clone()),
            FakeExchangeOutcome::ExchangeFailure(error) => Err(error.clone()),
        }
    }
}

#[derive(Clone)]
pub struct HttpBattleNetClient {
    client_id: String,
    client_secret: String,
    scope: String,
}

impl fmt::Debug for HttpBattleNetClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HttpBattleNetClient")
            .field("client_id", &self.client_id)
            .field("client_secret", &"[redacted]")
            .field("scope", &self.scope)
            .finish()
    }
}

impl HttpBattleNetClient {
    #[must_use]
    pub fn new(client_id: impl Into<String>, client_secret: impl Into<String>) -> Self {
        Self {
            client_id: client_id.into(),
            client_secret: client_secret.into(),
            scope: BATTLE_NET_SCOPE.to_owned(),
        }
    }

    #[must_use]
    pub fn client_id(&self) -> &str {
        &self.client_id
    }

    pub async fn exchange_async(
        &self,
        request: &TokenExchangeRequest,
    ) -> Result<BattleNetTokenSet, ProviderError> {
        use worker::{Fetch, Method, Request, RequestInit};

        let body = form_encode(&[
            ("grant_type", "authorization_code"),
            ("code", request.code.as_str()),
            ("redirect_uri", request.redirect_uri.as_str()),
            ("client_id", self.client_id.as_str()),
            ("client_secret", self.client_secret.as_str()),
            ("code_verifier", request.code_verifier.as_str()),
        ]);
        let mut init = RequestInit::new();
        init.with_method(Method::Post);
        init.with_body(Some(wasm_bindgen::JsValue::from_str(&body)));
        let req = Request::new_with_init(BATTLE_NET_TOKEN_ENDPOINT, &init)
            .map_err(|_| ProviderError::Unavailable)?;
        req.headers()
            .set("content-type", "application/x-www-form-urlencoded")
            .map_err(|_| ProviderError::Unavailable)?;

        let mut response = Fetch::Request(req)
            .send()
            .await
            .map_err(|_| ProviderError::Unavailable)?;
        let status = response.status_code();
        let text = response
            .text()
            .await
            .map_err(|_| ProviderError::Unavailable)?;
        if text.len() > 8_192 {
            return Err(ProviderError::UnexpectedResponse);
        }
        parse_token_response(status, &text, Timestamp(worker::Date::now().as_millis()))
    }

    pub async fn identity_async(
        &self,
        access_token: &str,
    ) -> Result<AccountSummary, ProviderError> {
        use worker::{Fetch, Method, Request, RequestInit};

        let mut init = RequestInit::new();
        init.with_method(Method::Get);
        let req = Request::new_with_init(BATTLE_NET_USERINFO_ENDPOINT, &init)
            .map_err(|_| ProviderError::Unavailable)?;
        req.headers()
            .set("authorization", &format!("Bearer {access_token}"))
            .map_err(|_| ProviderError::Unavailable)?;

        let mut response = Fetch::Request(req)
            .send()
            .await
            .map_err(|_| ProviderError::Unavailable)?;
        let status = response.status_code();
        let text = response
            .text()
            .await
            .map_err(|_| ProviderError::Unavailable)?;
        if text.len() > 8_192 {
            return Err(ProviderError::UnexpectedResponse);
        }
        parse_userinfo_response(status, &text)
    }
}

pub fn authorization_url_parts(
    client_id: &str,
    scope: &str,
    origin: &PublicOrigin,
    state: &OAuthState,
    verifier: &PkceVerifier,
) -> AuthorizationUrlParts {
    AuthorizationUrlParts {
        client_id: client_id.to_owned(),
        redirect_uri: origin.redirect_uri(),
        scope: scope.to_owned(),
        state: state.encode(),
        code_challenge: pkce_s256_challenge(verifier),
        code_challenge_method: "S256",
    }
}

#[must_use]
pub fn format_authorization_url(authorize_endpoint: &str, parts: &AuthorizationUrlParts) -> String {
    format!(
        "{authorize_endpoint}?response_type=code&client_id={}&redirect_uri={}&scope={}&state={}&code_challenge={}&code_challenge_method={}",
        urlencode(&parts.client_id),
        urlencode(&parts.redirect_uri),
        urlencode(&parts.scope),
        urlencode(&parts.state),
        urlencode(&parts.code_challenge),
        urlencode(parts.code_challenge_method),
    )
}

fn form_encode(parts: &[(&str, &str)]) -> String {
    let mut out = String::new();
    for (index, (key, value)) in parts.iter().enumerate() {
        if index > 0 {
            out.push('&');
        }
        out.push_str(&urlencode(key));
        out.push('=');
        out.push_str(&urlencode(value));
    }
    out
}

fn urlencode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(char::from(byte));
            }
            _ => {
                use std::fmt::Write as _;
                let _ = write!(out, "%{byte:02X}");
            }
        }
    }
    out
}

fn parse_token_response(
    status: u16,
    body: &str,
    now: Timestamp,
) -> Result<BattleNetTokenSet, ProviderError> {
    if status == 429 || (500..600).contains(&status) {
        return Err(ProviderError::Unavailable);
    }
    if status == 401 || status == 403 {
        return Err(ProviderError::Denied);
    }
    if !(200..300).contains(&status) {
        if body.contains("invalid_grant") {
            return Err(ProviderError::InvalidGrant);
        }
        return Err(ProviderError::UnexpectedResponse);
    }
    let value: serde_json::Value =
        serde_json::from_str(body).map_err(|_| ProviderError::UnexpectedResponse)?;
    let access_token = value
        .get("access_token")
        .and_then(serde_json::Value::as_str)
        .filter(|token| !token.is_empty())
        .ok_or(ProviderError::UnexpectedResponse)?
        .to_owned();
    let token_type = value
        .get("token_type")
        .and_then(serde_json::Value::as_str)
        .ok_or(ProviderError::UnexpectedResponse)?;
    if !token_type.eq_ignore_ascii_case("bearer") {
        return Err(ProviderError::UnexpectedResponse);
    }
    let expires_in = value
        .get("expires_in")
        .and_then(serde_json::Value::as_u64)
        .ok_or(ProviderError::UnexpectedResponse)?;
    let refresh_token = value
        .get("refresh_token")
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned);
    let granted_scopes = value
        .get("scope")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_owned();
    Ok(BattleNetTokenSet {
        access_token,
        token_type: BearerTokenType::Bearer,
        access_expires_at: Timestamp(now.0.saturating_add(expires_in.saturating_mul(1_000))),
        refresh_token,
        granted_scopes,
    })
}

fn parse_userinfo_response(status: u16, body: &str) -> Result<AccountSummary, ProviderError> {
    if status == 429 || (500..600).contains(&status) {
        return Err(ProviderError::Unavailable);
    }
    if !(200..300).contains(&status) {
        return Err(ProviderError::UnexpectedResponse);
    }
    let value: serde_json::Value =
        serde_json::from_str(body).map_err(|_| ProviderError::UnexpectedResponse)?;
    let id = value
        .get("sub")
        .or_else(|| value.get("id"))
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or(ProviderError::UnexpectedResponse)?
        .to_owned();
    let battletag = value
        .get("battle_tag")
        .or_else(|| value.get("battletag"))
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or(ProviderError::UnexpectedResponse)?
        .to_owned();
    Ok(AccountSummary { id, battletag })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::pkce::PkceVerifier;
    use crate::auth::types::{AttemptId, CallbackSecret};

    fn sample_tokens() -> BattleNetTokenSet {
        BattleNetTokenSet {
            access_token: "access".to_owned(),
            token_type: BearerTokenType::Bearer,
            access_expires_at: Timestamp(10_000),
            refresh_token: Some("refresh".to_owned()),
            granted_scopes: "openid".to_owned(),
        }
    }

    #[test]
    fn authorization_parts_always_use_s256_and_origin_redirect() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let state = OAuthState::new(AttemptId([1; 16]), CallbackSecret::from_bytes([2; 32]));
        let verifier = PkceVerifier::from_entropy([3; 32]);
        let parts = authorization_url_parts("client", "openid", &origin, &state, &verifier);
        assert_eq!(parts.code_challenge_method, "S256");
        assert_eq!(
            parts.redirect_uri,
            "https://auth.example.com/oauth/battlenet/callback"
        );
        let url = format_authorization_url("https://oauth.battle.net/authorize", &parts);
        assert!(url.contains("code_challenge_method=S256"));
        assert!(!url.contains("code_challenge_method=plain"));
    }

    #[test]
    fn fake_client_success_and_failure_contracts() {
        let success = FakeBattleNetClient::new(FakeExchangeOutcome::Success {
            tokens: sample_tokens(),
            account: AccountSummary {
                id: "42".to_owned(),
                battletag: "Player#42".to_owned(),
            },
        });
        let tokens = success
            .exchange(&TokenExchangeRequest {
                code: AuthorizationCode::new("code".to_owned()),
                redirect_uri: "https://auth.example.com/oauth/battlenet/callback".to_owned(),
                code_verifier: "verifier".to_owned(),
            })
            .unwrap();
        assert_eq!(tokens.access_expires_at, Timestamp(10_000));
        assert_eq!(success.identity("access").unwrap().battletag, "Player#42");
        assert_eq!(success.exchange_calls(), 1);

        let failure = FakeBattleNetClient::new(FakeExchangeOutcome::ExchangeFailure(
            ProviderError::InvalidGrant,
        ));
        assert!(matches!(
            failure.exchange(&TokenExchangeRequest {
                code: AuthorizationCode::new("code".to_owned()),
                redirect_uri: "https://auth.example.com/oauth/battlenet/callback".to_owned(),
                code_verifier: "verifier".to_owned(),
            }),
            Err(ProviderError::InvalidGrant)
        ));
        assert!(matches!(
            FakeBattleNetClient::new(FakeExchangeOutcome::ExchangeFailure(ProviderError::Denied))
                .exchange(&TokenExchangeRequest {
                    code: AuthorizationCode::new("code".to_owned()),
                    redirect_uri: "https://auth.example.com/oauth/battlenet/callback".to_owned(),
                    code_verifier: "verifier".to_owned(),
                }),
            Err(ProviderError::Denied)
        ));
        assert!(matches!(
            FakeBattleNetClient::new(FakeExchangeOutcome::ExchangeFailure(
                ProviderError::UnexpectedResponse,
            ))
            .exchange(&TokenExchangeRequest {
                code: AuthorizationCode::new("code".to_owned()),
                redirect_uri: "https://auth.example.com/oauth/battlenet/callback".to_owned(),
                code_verifier: "verifier".to_owned(),
            }),
            Err(ProviderError::UnexpectedResponse)
        ));
    }

    #[test]
    fn token_response_parser_accepts_bearer_and_maps_errors() {
        let tokens = parse_token_response(
            200,
            r#"{"access_token":"a","token_type":"bearer","expires_in":60,"scope":"openid"}"#,
            Timestamp(1_000),
        )
        .unwrap();
        assert_eq!(tokens.access_token, "a");
        assert_eq!(tokens.token_type, BearerTokenType::Bearer);
        assert_eq!(tokens.access_expires_at, Timestamp(61_000));
        assert_eq!(tokens.granted_scopes, "openid");
        assert!(matches!(
            parse_token_response(503, "{}", Timestamp(0)),
            Err(ProviderError::Unavailable)
        ));
        assert!(matches!(
            parse_token_response(400, r#"{"error":"invalid_grant"}"#, Timestamp(0)),
            Err(ProviderError::InvalidGrant)
        ));
    }
}
