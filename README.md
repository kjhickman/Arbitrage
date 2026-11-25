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
libs/LibDBIcon-1.0/  vendored with LibDataBroker and CallbackHandler, refreshed the same way
companion/
├── app/             tray app for Windows and macOS
├── shared/          types the app and Worker share
└── worker/          Cloudflare Worker: Battle.net sign-in, sync, TradeSkillMaster ingestion
scripts/changelog    pulls a version's notes from CHANGELOG.md for releases
scripts/bench/       benchmarks the addon in a fake game client
```

## Setup

- Lua 5.1 with LuaRocks: `luarocks --lua-version=5.1 install busted 2.3.0-1` and `luacheck 1.2.0-1`
- [StyLua](https://github.com/JohnnyMorganz/StyLua) 2.5.2
- [rustup](https://rustup.rs/), which uses the toolchain pinned in `rust-toolchain.toml`
- [Just](https://just.systems/), and Node.js to run the Worker locally

## Checks

`just check` runs formatting, lint, and tests for everything; `just check-lua` and `just check-rust` run one side. Run
one spec with `busted tests/Keys_spec.lua`.

## Releasing

Add a matching version section to `CHANGELOG.md` and push a `vX.Y.Z` tag for stable or `vX.Y.Z-beta.N` for a beta.
The workflow ships only the parts that changed, per `.github/filters.yml`. The first beta compares to the last stable
tag; later betas compare to the preceding beta for that version. Stable tags always compare to the preceding stable
tag, even if a beta is on the same commit. Beta tags never deploy the production Worker.
For a `.pkgmeta`-only addon change, add `### Addon` release notes if it should ship to CurseForge.

Addon betas appear on the same CurseForge project. Testers can set **Arbitrage → Release Type → Beta** in CurseForge or
use the specific file link. In the Companion tray, **Settings → Receive Beta Updates** opts into the beta update feed.
For a change that needs both, announce the beta after CurseForge approves the file and the Companion offers the update.
