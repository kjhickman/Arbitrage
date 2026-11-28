# Arbitrage

A World of Warcraft: Forever addon that finds craft-and-flip profits, plus an optional Rust companion that syncs scans and prices. See README.md for layout, setup, and releasing, and DESCRIPTION.md for what players see.

- `src/`: the addon (Lua 5.1), loaded in `Arbitrage.toc` order. `tests/`: Busted specs, with WoW mocks in `tests/support/`.
- `companion/`: Rust workspace. `app/` is the tray app, `worker/` is the Cloudflare Worker, and `shared/` holds the types they both use.
- `libs/` is vendored and a workflow refreshes it. Don't edit it.
- Don't edit DESCRIPTION.md, README.md, or AGENTS.md without the user's approval.

## Working here

- Verify with `just check` (or `just check-lua` / `just check-rust`). Run one spec with `busted tests/Name_spec.lua`.
- A new `src/` file goes in `Arbitrage.toc`. A new WoW global goes in `.luacheckrc`.
- Words players see come from `src/Terminology.lua`.
- A change players will notice gets an entry under `## Unreleased` in `CHANGELOG.md`, in the same commit as the code change.
