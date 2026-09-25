set windows-shell := ["pwsh.exe", "-NoLogo", "-NoProfile", "-Command"]

export ARBITRAGE_WORKER_URL := env("ARBITRAGE_WORKER_URL", "http://127.0.0.1:8787")

# List available recipes.
default:
    @just --list

# Start the local Worker and tray app together.
[parallel]
dev: worker app

# Start the tray app.
app:
    cargo run --manifest-path companion/Cargo.toml --package arbitrage-companion

# Start the local Cloudflare Worker.
worker:
    cd companion/worker && npx --yes wrangler@4.137.0 dev --ip 127.0.0.1 --port 8787

# Regenerate the companion's platform icons from companion/app/assets (macOS, needs resvg).
icons:
    companion/scripts/render-icons

# Run formatting, linting, and tests.
check:
    cargo fmt --manifest-path companion/Cargo.toml --all -- --check
    cargo clippy --manifest-path companion/Cargo.toml --locked --workspace --all-targets --all-features
    cargo test --manifest-path companion/Cargo.toml --locked --workspace --all-targets --all-features
