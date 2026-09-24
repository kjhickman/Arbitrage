use std::fmt;

use serde::{Deserialize, Serialize};
use worker::url::form_urlencoded;

use crate::auth::oauth_state::OAuthState;
use crate::auth::origin::PublicOrigin;
use crate::auth::pkce::{PkceVerifier, pkce_s256_challenge};
use crate::auth::types::AuthorizationCode;

pub const BATTLE_NET_AUTHORIZE_ENDPOINT: &str = "https://oauth.battle.net/authorize";
pub const BATTLE_NET_TOKEN_ENDPOINT: &str = "https://oauth.battle.net/token";
pub const BATTLE_NET_USERINFO_ENDPOINT: &str = "https://oauth.battle.net/userinfo";
pub const BATTLE_NET_SCOPE: &str = "openid";
const RESPONSE_LIMIT: usize = 8_192;

#[derive(Clone)]
pub struct BattleNetTokenSet {
    pub access_token: String,
}

impl fmt::Debug for BattleNetTokenSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BattleNetTokenSet")
            .field("access_token", &"[redacted]")
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
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

#[derive(Clone)]
pub struct HttpBattleNetClient {
    client_id: String,
    client_secret: String,
}

impl fmt::Debug for HttpBattleNetClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HttpBattleNetClient")
            .field("client_id", &self.client_id)
            .field("client_secret", &"[redacted]")
            .finish()
    }
}

impl HttpBattleNetClient {
    #[must_use]
    pub fn new(client_id: impl Into<String>, client_secret: impl Into<String>) -> Self {
        Self {
            client_id: client_id.into(),
            client_secret: client_secret.into(),
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
        use worker::{Method, Request, RequestInit};

        let body = form_urlencoded::Serializer::new(String::new())
            .extend_pairs([
                ("grant_type", "authorization_code"),
                ("code", request.code.as_str()),
                ("redirect_uri", request.redirect_uri.as_str()),
                ("client_id", self.client_id.as_str()),
                ("client_secret", self.client_secret.as_str()),
                ("code_verifier", request.code_verifier.as_str()),
            ])
            .finish();
        let mut init = RequestInit::new();
        init.with_method(Method::Post);
        init.with_body(Some(wasm_bindgen::JsValue::from_str(&body)));
        let req = Request::new_with_init(BATTLE_NET_TOKEN_ENDPOINT, &init)
            .map_err(|_| ProviderError::Unavailable)?;
        req.headers()
            .set("content-type", "application/x-www-form-urlencoded")
            .map_err(|_| ProviderError::Unavailable)?;

        let (status, text) = fetch_text(req).await?;
        parse_token_response(status, &text)
    }

    pub async fn identity_async(
        &self,
        access_token: &str,
    ) -> Result<AccountSummary, ProviderError> {
        use worker::{Method, Request, RequestInit};

        let mut init = RequestInit::new();
        init.with_method(Method::Get);
        let req = Request::new_with_init(BATTLE_NET_USERINFO_ENDPOINT, &init)
            .map_err(|_| ProviderError::Unavailable)?;
        req.headers()
            .set("authorization", &format!("Bearer {access_token}"))
            .map_err(|_| ProviderError::Unavailable)?;

        let (status, text) = fetch_text(req).await?;
        parse_userinfo_response(status, &text)
    }
}

async fn fetch_text(req: worker::Request) -> Result<(u16, String), ProviderError> {
    let mut response = worker::Fetch::Request(req)
        .send()
        .await
        .map_err(|_| ProviderError::Unavailable)?;
    let status = response.status_code();
    let text = response
        .text()
        .await
        .map_err(|_| ProviderError::Unavailable)?;
    if text.len() > RESPONSE_LIMIT {
        return Err(ProviderError::UnexpectedResponse);
    }
    Ok((status, text))
}

#[must_use]
pub fn format_authorization_url(
    client_id: &str,
    origin: &PublicOrigin,
    state: &OAuthState,
    verifier: &PkceVerifier,
) -> String {
    let query = form_urlencoded::Serializer::new(String::new())
        .append_pair("response_type", "code")
        .append_pair("client_id", client_id)
        .append_pair("redirect_uri", &origin.redirect_uri())
        .append_pair("scope", BATTLE_NET_SCOPE)
        .append_pair("state", &state.encode())
        .append_pair("code_challenge", &pkce_s256_challenge(verifier))
        .append_pair("code_challenge_method", "S256")
        .finish();
    format!("{BATTLE_NET_AUTHORIZE_ENDPOINT}?{query}")
}

fn parse_token_response(status: u16, body: &str) -> Result<BattleNetTokenSet, ProviderError> {
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
    let bearer = value
        .get("token_type")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|token_type| token_type.eq_ignore_ascii_case("bearer"));
    let expires = value
        .get("expires_in")
        .and_then(serde_json::Value::as_u64)
        .is_some();
    if !bearer || !expires {
        return Err(ProviderError::UnexpectedResponse);
    }
    Ok(BattleNetTokenSet { access_token })
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

    #[test]
    fn authorization_parts_always_use_s256_and_origin_redirect() {
        let origin = PublicOrigin::parse("https://auth.example.com").unwrap();
        let state = OAuthState::new(AttemptId([1; 16]), CallbackSecret::from_bytes([2; 32]));
        let verifier = PkceVerifier::from_entropy([3; 32]);
        let url = format_authorization_url("client", &origin, &state, &verifier);
        assert!(url.starts_with("https://oauth.battle.net/authorize?"));
        assert!(url.contains("scope=openid"));
        assert!(url.contains(
            "redirect_uri=https%3A%2F%2Fauth.example.com%2Foauth%2Fbattlenet%2Fcallback"
        ));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(!url.contains("code_challenge_method=plain"));
    }

    #[test]
    fn token_response_parser_accepts_bearer_and_maps_errors() {
        let tokens = parse_token_response(
            200,
            r#"{"access_token":"a","token_type":"bearer","expires_in":60,"scope":"openid"}"#,
        )
        .unwrap();
        assert_eq!(tokens.access_token, "a");
        assert!(matches!(
            parse_token_response(
                200,
                r#"{"access_token":"a","token_type":"mac","expires_in":60}"#
            ),
            Err(ProviderError::UnexpectedResponse)
        ));
        assert!(matches!(
            parse_token_response(200, r#"{"access_token":"a","token_type":"bearer"}"#),
            Err(ProviderError::UnexpectedResponse)
        ));
        assert!(matches!(
            parse_token_response(503, "{}"),
            Err(ProviderError::Unavailable)
        ));
        assert!(matches!(
            parse_token_response(401, "{}"),
            Err(ProviderError::Denied)
        ));
        assert!(matches!(
            parse_token_response(400, r#"{"error":"invalid_grant"}"#),
            Err(ProviderError::InvalidGrant)
        ));
    }
}
