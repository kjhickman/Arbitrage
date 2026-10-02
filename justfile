set windows-shell := ["pwsh.exe", "-NoLogo", "-NoProfile", "-Command"]

export ARBITRAGE_WORKER_URL := env("ARBITRAGE_WORKER_URL", "http://127.0.0.1:8787")

# List available recipes.
default:
    @just --list --unsorted

# Start the local Worker and tray app together.
[parallel]
dev: worker app

# Start the tray app.
app:
    cargo run --manifest-path companion/Cargo.toml --package arbitrage-companion

# Start the local Cloudflare Worker.
worker:
    cd companion/worker && npx --yes wrangler@4.137.0 dev --ip 127.0.0.1 --port 8787

# Run all Lua and Rust checks.
check: check-lua check-rust

# Run all Lua checks.
check-lua: format-lua lint-lua test-lua

# Run all Rust checks.
check-rust: format-rust lint-rust test-rust

# Check Lua formatting without modifying files.
format-lua:
    stylua --check .

# Lint Lua code.
lint-lua:
    luacheck .

# Run Lua tests.
[unix]
test-lua:
    for test in tests/*_test.lua; do lua "$test" || exit "$?"; done

# Run Lua tests.
[windows]
test-lua:
    foreach ($test in Get-ChildItem tests/*_test.lua) { lua $test.FullName; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } }

# Check Rust formatting without modifying files.
format-rust:
    cargo fmt --manifest-path companion/Cargo.toml --all -- --check

# Lint Rust code.
lint-rust:
    cargo clippy --manifest-path companion/Cargo.toml --locked --workspace --all-targets --all-features

# Run Rust tests.
test-rust:
    cargo test --manifest-path companion/Cargo.toml --locked --workspace --all-targets --all-features
