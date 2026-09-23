use worker::{Date, DurableObject, Env, Request, Response, Result, State, durable_object};

use crate::auth::battlenet::HttpBattleNetClient;
use crate::auth::handlers::{
    AUTH_SESSIONS_BINDING, CallbackPrepareError, RECORD_STORAGE_KEY, SignedInError,
    apply_provider_outcome, begin_attempt, parse_bearer_authorization, parse_begin_body,
    prepare_callback, revoke_for_capability, signed_in_account_id, status_for_capability,
};
use crate::auth::origin::PublicOrigin;
use crate::auth::pkce::PkceVerifier;
use crate::auth::session::AuthSessionRecord;
use crate::auth::session::BeginError;
use crate::auth::types::{AttemptId, CallbackSecret, Timestamp};

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
        let path = path_without_query(&req)?;
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
        let (record, result) = match begin_attempt(
            existing,
            attempt_id,
            tray_key,
            CallbackSecret::from_bytes(random_bytes()?),
            PkceVerifier::from_entropy(random_bytes()?),
            &origin,
            client.client_id(),
            now(),
        ) {
            Ok(value) => value,
            Err(BeginError::ConflictingTrayKey | BeginError::NotPending) => {
                return Response::error("Conflict", 409);
            }
        };
        self.store_record(&record).await?;
        let mut response = Response::from_json(&result.response)?;
        response.headers_mut().set("Cache-Control", "no-store")?;
        if result.created {
            Ok(response.with_status(201))
        } else {
            Ok(response.with_status(200))
        }
    }

    async fn status(&self, req: Request) -> Result<Response> {
        let attempt_id = attempt_id_header(&req)?;
        let Some(secret) =
            parse_bearer_authorization(req.headers().get("Authorization")?.as_deref())
        else {
            return Response::error("Unauthorized", 401);
        };
        let record = self.load_record().await?;
        let status = match status_for_capability(record.as_ref(), attempt_id, &secret) {
            Ok(status) => status,
            Err(crate::auth::session::ProofError::Unauthorized) => {
                return Response::error("Unauthorized", 401);
            }
        };
        let mut response = Response::from_json(&status)?;
        response.headers_mut().set("Cache-Control", "no-store")?;
        Ok(response)
    }

    async fn revoke(&self, req: Request) -> Result<Response> {
        let attempt_id = attempt_id_header(&req)?;
        let Some(secret) =
            parse_bearer_authorization(req.headers().get("Authorization")?.as_deref())
        else {
            return Response::error("Unauthorized", 401);
        };
        let record = self.load_record().await?;
        let record = match revoke_for_capability(record, attempt_id, &secret, now()) {
            Ok(record) => record,
            Err(crate::auth::session::ProofError::Unauthorized) => {
                return Response::error("Unauthorized", 401);
            }
        };
        self.store_record(&record).await?;
        let mut response = Response::empty()?;
        response.headers_mut().set("Cache-Control", "no-store")?;
        Ok(response.with_status(204))
    }

    async fn signed_in_account(&self, req: Request) -> Result<Response> {
        let attempt_id = attempt_id_header(&req)?;
        let Some(secret) =
            parse_bearer_authorization(req.headers().get("Authorization")?.as_deref())
        else {
            return Response::error("Unauthorized", 401);
        };
        let record = self.load_record().await?;
        match signed_in_account_id(record.as_ref(), attempt_id, &secret) {
            Ok(id) => {
                let mut response = Response::from_json(&serde_json::json!({ "id": id }))?;
                response.headers_mut().set("Cache-Control", "no-store")?;
                Ok(response)
            }
            Err(SignedInError::Unauthorized) => Response::error("Unauthorized", 401),
            Err(SignedInError::NotSignedIn) => Response::error("Conflict", 409),
        }
    }

    async fn callback(&self, req: Request) -> Result<Response> {
        let origin = public_origin(&self.env)?;
        let url = req.url()?;
        let owned: Vec<(String, String)> = url
            .query_pairs()
            .map(|(key, value)| (key.into_owned(), value.into_owned()))
            .collect();
        let params: Vec<(&str, &str)> = owned
            .iter()
            .map(|(key, value)| (key.as_str(), value.as_str()))
            .collect();

        let existing = self.load_record().await?;
        let (mut record, prepared) = match prepare_callback(existing, &origin, &params, now()) {
            Ok(value) => value,
            Err(CallbackPrepareError::InvalidQuery(_) | CallbackPrepareError::MissingAttempt) => {
                return Response::error("Bad Request", 400);
            }
            Err(CallbackPrepareError::Consume(_)) => return Response::error("Bad Request", 400),
        };

        self.store_record(&record).await?;

        if let Some(request) = prepared.exchange.as_ref() {
            let client = provider_client(&self.env)?;
            let exchange = client.exchange_async(request).await;
            let identity = if let Ok(tokens) = &exchange {
                Some(client.identity_async(&tokens.access_token).await)
            } else {
                None
            };
            match crate::auth::handlers::decide_callback_exchange(exchange, identity) {
                crate::auth::handlers::CallbackExchangeDecision::Success { account, tokens } => {
                    let _ = apply_provider_outcome(&mut record, Ok((account, tokens)), now());
                }
                crate::auth::handlers::CallbackExchangeDecision::RetryableFailure => {
                    let _ = apply_provider_outcome(
                        &mut record,
                        Err(crate::auth::battlenet::ProviderError::Unavailable),
                        now(),
                    );
                }
                crate::auth::handlers::CallbackExchangeDecision::TerminalFailure => {
                    record.apply_exchange_failure(false, now());
                }
            }
            self.store_record(&record).await?;
        }

        redirect_completion(&prepared.redirect)
    }

    async fn load_record(&self) -> Result<Option<AuthSessionRecord>> {
        let storage = self.state.storage();
        let value: Option<String> = storage.get(RECORD_STORAGE_KEY).await?;
        let Some(raw) = value else {
            return Ok(None);
        };
        AuthSessionRecord::decode(raw.as_bytes())
            .map(Some)
            .map_err(|_| {
                worker::Error::RustError("stored auth session record is malformed".to_owned())
            })
    }

    async fn store_record(&self, record: &AuthSessionRecord) -> Result<()> {
        let bytes = record
            .encode()
            .map_err(|_| worker::Error::RustError("failed to encode auth session".to_owned()))?;
        let raw = String::from_utf8(bytes)
            .map_err(|_| worker::Error::RustError("auth session encode was not utf8".to_owned()))?;
        self.state.storage().put(RECORD_STORAGE_KEY, raw).await
    }
}

fn redirect_completion(
    redirect: &crate::auth::completion::BrowserCompletionRedirect,
) -> Result<Response> {
    let mut response = Response::empty()?;
    response = response.with_status(redirect.status);
    response.headers_mut().set("Location", &redirect.location)?;
    response
        .headers_mut()
        .set("Cache-Control", redirect.cache_control)?;
    response
        .headers_mut()
        .set("Referrer-Policy", redirect.referrer_policy)?;
    Ok(response)
}

fn path_without_query(req: &Request) -> Result<String> {
    Ok(req.url()?.path().to_owned())
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

#[must_use]
pub const fn binding_name() -> &'static str {
    AUTH_SESSIONS_BINDING
}
