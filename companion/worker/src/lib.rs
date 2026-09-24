#![allow(clippy::future_not_send)]

mod auth;
pub mod sync;

use worker::{Context, Env, Request, Response, Result, event};

pub use crate::auth::durable::AuthSession;
pub use crate::sync::AccountDatabase;

#[event(fetch)]
async fn fetch(request: Request, environment: Env, _context: Context) -> Result<Response> {
    auth::routes::router().run(request, environment).await
}
