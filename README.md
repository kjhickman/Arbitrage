# Arbitrage

> For what Arbitrage does and how to use it, see [DESCRIPTION.md](DESCRIPTION.md), which is also the CurseForge page.

A World of Warcraft: Forever addon with an optional companion. The companion uploads the addon's saved scans, the
Worker merges them with TradeSkillMaster data, and the companion writes the result into an `Arbitrage_Data` addon that
Arbitrage reads at login.

## Project Structure

```text
Arbitrage.toc        addon manifest
src/                 addon (Lua 5.1)
tests/               Busted specs; support/ holds the shared WoW mocks
libs/LibAHTab/       vendored, refreshed weekly by a workflow pull request
companion/
├── app/             tray app for Windows and macOS
├── shared/          types the app and Worker share
└── worker/          Cloudflare Worker: Battle.net sign-in, sync, TradeSkillMaster ingestion
scripts/changelog    pulls a version's notes from CHANGELOG.md for releases
```

## Setup

- Lua 5.1 with LuaRocks: `luarocks --lua-version=5.1 install busted 2.3.0-1` and `luacheck 1.2.0-1`
- [StyLua](https://github.com/JohnnyMorganz/StyLua) 2.5.2
- [rustup](https://rustup.rs/), which uses the toolchain pinned in `rust-toolchain.toml`
- [Just](https://just.systems/), and Node.js to run the Worker locally

## Checks

`just check` runs formatting, lint, and tests for everything; `just check-lua` and `just check-rust` run one side. Run
one spec with `busted tests/Keys_spec.lua`.

## Running the Companion

Copy `companion/worker/.dev.vars.example` to `.dev.vars` and add Battle.net client credentials, then run `just dev` to
start the local Worker and tray app (or `just worker` / `just app` for one).

## Releasing

Add the version to `CHANGELOG.md` and push a `vX.Y.Z` tag. The release workflow ships only the parts that changed, per
`.github/filters.yml`.
