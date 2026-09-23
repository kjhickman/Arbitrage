use worker::{Context, Env, Request, Response, Result};
use worker_macros::event;

#[event(fetch)]
async fn fetch(_request: Request, _environment: Env, _context: Context) -> Result<Response> {
    Response::ok("Hello from Arbitrage Worker!")
}
