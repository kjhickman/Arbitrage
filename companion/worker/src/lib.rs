#![allow(clippy::future_not_send)]

mod auth;
mod companion;
pub mod market;
pub mod sync;

use worker::{Context, Env, Request, Response, Result, event};

pub use crate::auth::durable::AuthSession;
pub use crate::market::MarketDatabase;
pub use crate::sync::AccountDatabase;

/// Durable Objects route on the path alone; the origin only has to make the URL valid.
fn internal_url(path: &str) -> String {
    format!("https://arbitrage.internal{path}")
}

#[event(fetch)]
async fn fetch(request: Request, environment: Env, _context: Context) -> Result<Response> {
    auth::routes::router().run(request, environment).await
}
