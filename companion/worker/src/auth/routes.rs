use serde::Deserialize;
use worker::{Env, Method, Request, RequestInit, Response, Result, RouteContext, Router};

use crate::auth::callback::validate_callback_query;
use crate::auth::handlers::AUTH_SESSIONS_BINDING;
use crate::auth::origin::{CALLBACK_PATH, COMPLETION_PATH};
use crate::auth::types::AttemptId;
use crate::sync::{AccountKey, BODY_LIMIT};

const COMPLETION_BODY: &str = concat!(
    "<!DOCTYPE html><html lang=\"en\"><head>",
    "<meta charset=\"utf-8\">",
    "<meta name=\"referrer\" content=\"no-referrer\">",
    "<title>Sign-in complete</title>",
    "</head><body>",
    "<p>You can close this window and return to Arbitrage.</p>",
    "</body></html>"
);

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
        .get_async("/v1/companion/latest", crate::companion::latest)
        .get_async("/v1/companion/latest/:platform", crate::companion::download)
}

async fn begin(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    forward_attempt(&mut req, &ctx, Method::Post, "/internal/begin").await
}

async fn status(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    forward_attempt(&mut req, &ctx, Method::Get, "/internal/status").await
}

async fn revoke(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    forward_attempt(&mut req, &ctx, Method::Delete, "/internal/revoke").await
}

async fn sync(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let body = req.bytes().await?;
    if body.len() > BODY_LIMIT {
        return Response::error("Payload Too Large", 413);
    }

    let mut auth_response =
        forward_attempt(&mut req, &ctx, Method::Get, "/internal/signed-in-account").await?;
    if auth_response.status_code() != 200 {
        return Ok(auth_response);
    }

    let Ok(signed_in) = auth_response.json::<SignedInAccountBody>().await else {
        return Response::error("Internal Server Error", 500);
    };
    let Some(account) = AccountKey::parse(&signed_in.id) else {
        return Response::error("Internal Server Error", 500);
    };
    let Ok(text) = std::str::from_utf8(&body) else {
        return Response::error("Bad Request", 400);
    };

    crate::sync::sync(&ctx.env, &account, text).await
}

async fn callback(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let url = req.url()?;
    let params: Vec<_> = url.query_pairs().collect();
    let Ok(callback) = validate_callback_query(&params) else {
        return Response::error("Bad Request", 400);
    };
    let stub = durable_stub(&ctx.env, &callback.state().attempt_id().encode())?;
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
    let mut response = Response::ok(COMPLETION_BODY)?;
    let headers = response.headers_mut();
    headers.set("Cache-Control", "no-store")?;
    headers.set("Referrer-Policy", "no-referrer")?;
    headers.set(
        "Content-Security-Policy",
        "default-src 'none'; base-uri 'none'; form-action 'none'",
    )?;
    headers.set("Content-Type", "text/html; charset=utf-8")?;
    Ok(response)
}

async fn forward_attempt(
    req: &mut Request,
    ctx: &RouteContext<()>,
    method: Method,
    internal_path: &str,
) -> Result<Response> {
    let id = ctx
        .param("id")
        .ok_or_else(|| worker::Error::RustError("missing attempt id".to_owned()))?;
    let attempt_id = AttemptId::parse(id)
        .map_err(|_| worker::Error::RustError("invalid attempt id".to_owned()))?;
    let stub = durable_stub(&ctx.env, &attempt_id.encode())?;

    let mut init = RequestInit::new();
    let is_post = matches!(method, Method::Post);
    init.with_method(method)
        .with_redirect(worker::RequestRedirect::Manual);
    if is_post {
        init.with_body(Some(bytes_body(&req.bytes().await?)));
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

fn bytes_body(bytes: &[u8]) -> wasm_bindgen::JsValue {
    wasm_bindgen::JsValue::from(worker::js_sys::Uint8Array::from(bytes))
}

fn durable_stub(env: &Env, name: &str) -> Result<worker::Stub> {
    let namespace = env.durable_object(AUTH_SESSIONS_BINDING)?;
    namespace.id_from_name(name)?.get_stub()
}
