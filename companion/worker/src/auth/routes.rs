use serde::Deserialize;
use worker::{Env, Method, Request, RequestInit, Response, Result, RouteContext, Router};

use crate::auth::completion::COMPLETION_PATH;
use crate::auth::durable::binding_name;
use crate::auth::handlers::{callback_state_attempt_id, completion_http, parse_attempt_path_id};
use crate::auth::origin::CALLBACK_PATH;
use crate::sync::{ACCOUNT_DATABASES, AccountKey};

const BODY_LIMIT: usize = 8 * 1024 * 1024;

#[derive(Deserialize)]
struct SignedInAccountBody {
    id: String,
}

pub fn router() -> Router<'static, ()> {
    Router::new()
        .post_async("/v1/auth/battlenet/attempts/:id", begin)
        .get_async("/v1/auth/battlenet/attempts/:id", status)
        .delete_async("/v1/auth/battlenet/attempts/:id", revoke)
        .post_async("/v1/auth/battlenet/attempts/:id/sync", sync)
        .get_async(CALLBACK_PATH, callback)
        .get(COMPLETION_PATH, complete)
}

async fn begin(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    forward_attempt(req, &ctx, Method::Post, "/internal/begin").await
}

async fn status(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    forward_attempt(req, &ctx, Method::Get, "/internal/status").await
}

async fn revoke(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    forward_attempt(req, &ctx, Method::Delete, "/internal/revoke").await
}

async fn sync(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let id = ctx
        .param("id")
        .ok_or_else(|| worker::Error::RustError("missing attempt id".to_owned()))?;
    let attempt_id = parse_attempt_path_id(id)
        .map_err(|_| worker::Error::RustError("invalid attempt id".to_owned()))?;

    let body = req.bytes().await?;
    if body.len() > BODY_LIMIT {
        return Response::error("Payload Too Large", 413);
    }

    let auth_stub = durable_stub(&ctx.env, &attempt_id.encode())?;
    let mut auth_init = RequestInit::new();
    auth_init
        .with_method(Method::Get)
        .with_redirect(worker::RequestRedirect::Manual);
    let mut auth_request = Request::new_with_init(
        "https://auth-session.internal/internal/signed-in-account",
        &auth_init,
    )?;
    auth_request
        .headers_mut()?
        .set("X-Arbitrage-Attempt-Id", &attempt_id.encode())?;
    if let Some(authorization) = req.headers().get("Authorization")? {
        auth_request
            .headers_mut()?
            .set("Authorization", &authorization)?;
    }
    let mut auth_response = auth_stub.fetch_with_request(auth_request).await?;
    if auth_response.status_code() != 200 {
        return Ok(auth_response);
    }

    let Ok(signed_in) = auth_response.json::<SignedInAccountBody>().await else {
        return Response::error("Internal Server Error", 500);
    };
    let Ok(account) = AccountKey::parse(&signed_in.id) else {
        return Response::error("Internal Server Error", 500);
    };

    let namespace = ctx.env.durable_object(ACCOUNT_DATABASES)?;
    let stub = namespace.id_from_name(account.as_str())?.get_stub()?;

    let mut sync_init = RequestInit::new();
    sync_init
        .with_method(Method::Post)
        .with_redirect(worker::RequestRedirect::Manual)
        .with_body(Some(wasm_bindgen::JsValue::from(js_sys::Uint8Array::from(
            body.as_slice(),
        ))));
    let mut sync_request = Request::new_with_init(
        "https://account-database.internal/internal/sync",
        &sync_init,
    )?;
    sync_request
        .headers_mut()?
        .set("Content-Type", "application/json")?;
    stub.fetch_with_request(sync_request).await
}

async fn callback(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let url = req.url()?;
    let owned: Vec<(String, String)> = url
        .query_pairs()
        .map(|(key, value)| (key.into_owned(), value.into_owned()))
        .collect();
    let params: Vec<(&str, &str)> = owned
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_str()))
        .collect();
    let Ok(attempt_id) = callback_state_attempt_id(&params) else {
        return Response::error("Bad Request", 400);
    };
    let stub = durable_stub(&ctx.env, &attempt_id.encode())?;
    let mut init = RequestInit::new();
    init.with_method(Method::Get)
        .with_redirect(worker::RequestRedirect::Manual);
    let internal = url.query().map_or_else(
        || "https://auth-session.internal/internal/callback".to_owned(),
        |query| format!("https://auth-session.internal/internal/callback?{query}"),
    );
    let forwarded = Request::new_with_init(&internal, &init)?;
    stub.fetch_with_request(forwarded).await
}

fn complete(_req: Request, _ctx: RouteContext<()>) -> Result<Response> {
    let page = completion_http();
    let mut response = Response::ok(page.body)?;
    response = response.with_status(page.status);
    response
        .headers_mut()
        .set("Cache-Control", page.cache_control)?;
    response
        .headers_mut()
        .set("Referrer-Policy", page.referrer_policy)?;
    response
        .headers_mut()
        .set("Content-Security-Policy", page.content_security_policy)?;
    response
        .headers_mut()
        .set("Content-Type", page.content_type)?;
    Ok(response)
}

async fn forward_attempt(
    mut req: Request,
    ctx: &RouteContext<()>,
    method: Method,
    internal_path: &str,
) -> Result<Response> {
    let id = ctx
        .param("id")
        .ok_or_else(|| worker::Error::RustError("missing attempt id".to_owned()))?;
    let attempt_id = parse_attempt_path_id(id)
        .map_err(|_| worker::Error::RustError("invalid attempt id".to_owned()))?;
    let stub = durable_stub(&ctx.env, &attempt_id.encode())?;

    let mut init = RequestInit::new();
    let is_post = matches!(method, Method::Post);
    init.with_method(method)
        .with_redirect(worker::RequestRedirect::Manual);
    if is_post {
        let body = req.bytes().await?;
        init.with_body(Some(wasm_bindgen::JsValue::from(js_sys::Uint8Array::from(
            body.as_slice(),
        ))));
    }
    let mut forwarded = Request::new_with_init(
        &format!("https://auth-session.internal{internal_path}"),
        &init,
    )?;
    forwarded
        .headers_mut()?
        .set("X-Arbitrage-Attempt-Id", &attempt_id.encode())?;
    if let Some(authorization) = req.headers().get("Authorization")? {
        forwarded
            .headers_mut()?
            .set("Authorization", &authorization)?;
    }
    if is_post {
        forwarded
            .headers_mut()?
            .set("Content-Type", "application/json")?;
    }
    stub.fetch_with_request(forwarded).await
}

fn durable_stub(env: &Env, name: &str) -> Result<worker::Stub> {
    let namespace = env.durable_object(binding_name())?;
    namespace.id_from_name(name)?.get_stub()
}
