#![allow(clippy::future_not_send)]

mod auth;
mod companion;
pub mod market;
pub mod region;
pub mod sync;
pub mod tsm;

use worker::{Context, Env, Request, Response, Result, ScheduleContext, ScheduledEvent, event};

pub use crate::auth::durable::AuthSession;
pub use crate::market::MarketDatabase;
pub use crate::region::RegionDatabase;
pub use crate::sync::AccountDatabase;
pub use crate::tsm::TsmIngest;

#[event(fetch)]
async fn fetch(request: Request, environment: Env, _context: Context) -> Result<Response> {
    auth::routes::router().run(request, environment).await
}

#[event(scheduled)]
async fn scheduled(event: ScheduledEvent, environment: Env, _context: ScheduleContext) {
    if let Err(error) = tsm::run_scheduled(&event.cron(), &environment).await {
        worker::console_error!("TSM ingestion failed: {error}");
    }
}
