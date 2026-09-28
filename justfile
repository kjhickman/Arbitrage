set windows-shell := ["pwsh.exe", "-NoLogo", "-NoProfile", "-Command"]

local_worker_url := env("ARBITRAGE_WORKER_URL", "http://127.0.0.1:8787")

# List available recipes.
default:
    @just --list

# Start the local Worker and a tray app pointed at it.
[parallel]
dev: worker app-local

# Start the tray app against production.
app:
    cargo run --manifest-path companion/Cargo.toml --package arbitrage-companion

# Start the tray app against the local Worker.
[env("ARBITRAGE_WORKER_URL", local_worker_url)]
app-local:
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
