use worker::{Date, DurableObject, Env, Request, Response, Result, State, durable_object};

use crate::auth::battlenet::{HttpBattleNetClient, ProviderError};
use crate::auth::handlers::{
    RECORD_STORAGE_KEY, SignedInError, begin_attempt, parse_bearer_authorization, parse_begin_body,
    prepare_callback, revoke_for_capability, signed_in_account_id, status_for_capability,
};
use crate::auth::origin::PublicOrigin;
use crate::auth::persist;
use crate::auth::pkce::PkceVerifier;
use crate::auth::session::AuthSessionRecord;
use crate::auth::types::{AttemptId, CallbackSecret, Timestamp, TraySecret};

#[durable_object]
pub struct AuthSession {
    state: State,
    env: Env,
}

impl DurableObject for AuthSession {
    fn new(state: State, env: Env) -> Self {
        Self { state, env }
    }

    async fn fetch(&self, req: Request) -> Result<Response> {
        let path = req.url()?.path().to_owned();
        match (req.method(), path.as_str()) {
            (worker::Method::Post, "/internal/begin") => self.begin(req).await,
            (worker::Method::Get, "/internal/status") => self.status(req).await,
            (worker::Method::Delete, "/internal/revoke") => self.revoke(req).await,
            (worker::Method::Get, "/internal/callback") => self.callback(req).await,
            (worker::Method::Get, "/internal/signed-in-account") => {
                self.signed_in_account(req).await
            }
            _ => Response::error("Not Found", 404),
        }
    }
}

impl AuthSession {
    async fn begin(&self, mut req: Request) -> Result<Response> {
        let attempt_id = attempt_id_header(&req)?;
        let origin = public_origin(&self.env)?;
        let client = provider_client(&self.env)?;
        let body = req.bytes().await?;
        if body.len() > 512 {
            return Response::error("Bad Request", 400);
        }
        let Some(tray_key) = parse_begin_body(&body) else {
            return Response::error("Bad Request", 400);
        };

        let existing = self.load_record().await?;
        let Ok((record, result)) = begin_attempt(
            existing,
            attempt_id,
            tray_key,
            CallbackSecret::from_bytes(random_bytes()?),
            PkceVerifier::from_entropy(random_bytes()?),
            &origin,
            client.client_id(),
            now(),
        ) else {
            return Response::error("Conflict", 409);
        };
        self.store_record(&record).await?;
        let status = if result.created { 201 } else { 200 };
        no_store(Response::from_json(&result.response)?.with_status(status))
    }

    async fn status(&self, req: Request) -> Result<Response> {
        let Some((attempt_id, secret)) = capability(&req)? else {
            return Response::error("Unauthorized", 401);
        };
        let record = self.load_record().await?;
        let Ok(status) = status_for_capability(record.as_ref(), attempt_id, &secret) else {
            return Response::error("Unauthorized", 401);
        };
        no_store(Response::from_json(&status)?)
    }

    async fn revoke(&self, req: Request) -> Result<Response> {
        let Some((attempt_id, secret)) = capability(&req)? else {
            return Response::error("Unauthorized", 401);
        };
        let record = self.load_record().await?;
        let Ok(record) = revoke_for_capability(record, attempt_id, &secret, now()) else {
            return Response::error("Unauthorized", 401);
        };
        self.store_record(&record).await?;
        no_store(Response::empty()?.with_status(204))
    }

    async fn signed_in_account(&self, req: Request) -> Result<Response> {
        let Some((attempt_id, secret)) = capability(&req)? else {
            return Response::error("Unauthorized", 401);
        };
        let record = self.load_record().await?;
        match signed_in_account_id(record.as_ref(), attempt_id, &secret) {
            Ok(id) => no_store(Response::from_json(&serde_json::json!({ "id": id }))?),
            Err(SignedInError::Unauthorized) => Response::error("Unauthorized", 401),
            Err(SignedInError::NotSignedIn) => Response::error("Conflict", 409),
        }
    }

    async fn callback(&self, req: Request) -> Result<Response> {
        let origin = public_origin(&self.env)?;
        let url = req.url()?;
        let params: Vec<_> = url.query_pairs().collect();

        let existing = self.load_record().await?;
        let Ok((mut record, exchange)) = prepare_callback(existing, &origin, &params, now()) else {
            return Response::error("Bad Request", 400);
        };

        self.store_record(&record).await?;

        if let Some(request) = exchange.as_ref() {
            let client = provider_client(&self.env)?;
            let outcome = match client.exchange_async(request).await {
                Ok(tokens) => client
                    .identity_async(&tokens.access_token)
                    .await
                    .map_err(|_| ProviderError::UnexpectedResponse),
                Err(error) => Err(error),
            };
            record.apply_exchange_outcome(outcome, now());
            self.store_record(&record).await?;
        }

        redirect_completion(&origin.completion_uri())
    }

    async fn load_record(&self) -> Result<Option<AuthSessionRecord>> {
        let storage = self.state.storage();
        let value: Option<String> = storage.get(RECORD_STORAGE_KEY).await?;
        let Some(raw) = value else {
            return Ok(None);
        };
        persist::decode(raw.as_bytes()).map(Some).map_err(|_| {
            worker::Error::RustError("stored auth session record is malformed".to_owned())
        })
    }

    async fn store_record(&self, record: &AuthSessionRecord) -> Result<()> {
        let bytes = persist::encode(record)
            .map_err(|_| worker::Error::RustError("failed to encode auth session".to_owned()))?;
        let raw = String::from_utf8(bytes)
            .map_err(|_| worker::Error::RustError("auth session encode was not utf8".to_owned()))?;
        self.state.storage().put(RECORD_STORAGE_KEY, raw).await
    }
}

fn no_store(mut response: Response) -> Result<Response> {
    response.headers_mut().set("Cache-Control", "no-store")?;
    Ok(response)
}

fn redirect_completion(location: &str) -> Result<Response> {
    let mut response = Response::empty()?.with_status(303);
    response.headers_mut().set("Location", location)?;
    let mut response = no_store(response)?;
    response
        .headers_mut()
        .set("Referrer-Policy", "no-referrer")?;
    Ok(response)
}

fn capability(req: &Request) -> Result<Option<(AttemptId, TraySecret)>> {
    let attempt_id = attempt_id_header(req)?;
    let secret = parse_bearer_authorization(req.headers().get("Authorization")?.as_deref());
    Ok(secret.map(|secret| (attempt_id, secret)))
}

fn attempt_id_header(req: &Request) -> Result<AttemptId> {
    let raw = req
        .headers()
        .get("X-Arbitrage-Attempt-Id")?
        .ok_or_else(|| worker::Error::RustError("missing attempt id".to_owned()))?;
    AttemptId::parse(&raw).map_err(|_| worker::Error::RustError("invalid attempt id".to_owned()))
}

fn public_origin(env: &Env) -> Result<PublicOrigin> {
    let raw = env.var("PUBLIC_ORIGIN")?.to_string();
    PublicOrigin::parse(&raw)
        .map_err(|_| worker::Error::RustError("PUBLIC_ORIGIN is invalid".to_owned()))
}

fn provider_client(env: &Env) -> Result<HttpBattleNetClient> {
    let client_id = match env.var("BATTLE_NET_CLIENT_ID") {
        Ok(value) => value.to_string(),
        Err(_) => env.secret("BATTLE_NET_CLIENT_ID")?.to_string(),
    };
    let client_secret = env.secret("BATTLE_NET_CLIENT_SECRET")?.to_string();
    Ok(HttpBattleNetClient::new(client_id, client_secret))
}

fn now() -> Timestamp {
    Timestamp(Date::now().as_millis())
}

fn random_bytes<const N: usize>() -> Result<[u8; N]> {
    let mut bytes = [0_u8; N];
    getrandom::getrandom(&mut bytes)
        .map_err(|_| worker::Error::RustError("CSPRNG unavailable".to_owned()))?;
    Ok(bytes)
}
