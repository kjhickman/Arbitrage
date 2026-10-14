# Arbitrage

Arbitrage targets **World of Warcraft: Forever**.

Find profitable crafts and flips on the Auction House. Arbitrage shows what an item's "market value" is and the cheapest way to craft it, making it easy to spot ways to turn a profit.

Open the Arbitrage tab at the Auction House, run a scan, then hover items.

The Arbitrage Auction House tab ranks known craftable items by estimated net profit per craft, choosing the higher
proceeds from an Auction House sale or vendoring the crafted items. The sale method appears beside the crafter; hover
the row to compare both profit estimates. It uses rolling material values for the primary crafting-cost estimate and
shows the latest scan's minimum material cost as a best case. Crafts appear when either estimate is profitable, and
vendor opportunities do not need an Auction House price for the crafted item. Auction House cuts apply only to AH
sales; listing deposits, available material depth, sale rate, inventory, and recipe cooldowns are not included. Its
sortable table separates normal and minimum crafting costs and their corresponding estimated and best-case profits.

## Spotting Profits

- **Market Value** — what the item currently sells for.
- **Crafting Cost** — the cheapest way to make it, choosing between vendor, Auction House, and crafting at every intermediate step.
- **Minimum Craft Cost** — the same, using the cheapest per-unit buyouts from the latest full scan.
- **Vendor Profit / Best-case Vendor Profit** — vendor sell value minus the corresponding crafting cost. These tooltip values appear for sellable crafts alongside their enabled crafting-cost estimates.

Hold Shift to see the exact cheapest recipe.

The crafting window's recipe list shows estimated net profit **per craft** beside each supported learned recipe,
using that recipe's materials and output quantity. Green means profit, red means loss, yellow means uncertain data,
and `?` means prices are missing. Hover a recipe for its sale method, crafting cost, and best-case profit. AH estimates
include the market's cut. These estimates use the same pricing
and exclusions as the Auction House tab, but also show unprofitable recipes regardless of the tab's filters.

## Recipes

Open each character's profession window once to record its learned recipes. Arbitrage combines recipes recorded for all characters on the realm, then compares buying and crafting each intermediate material to find the cheapest route.

Vendor prices are learned when you visit merchants and shared by same-faction characters on the realm. Only unlimited-stock, coin-priced offers are used. The addon does not account for inventory, cooldowns, or listing depth.

## Commands

- `/arb` or `/arb help` - show all commands
- `/arb status` - show stored data and settings status
- `/arb settings` - open the Arbitrage settings

## Development

Tests use [Busted](https://lunarmodules.github.io/busted/) with PUC Lua 5.1.5. Linting uses [Luacheck](https://github.com/lunarmodules/luacheck), configured in `.luacheckrc`. Install the pinned versions with [LuaRocks](https://luarocks.org/):

```sh
luarocks --lua-version=5.1 install busted 2.3.0-1
luarocks --lua-version=5.1 install luacheck 1.2.0-1
```

```sh
just check-lua
```

Run only the Lua tests with `just test-lua`. Specs live in `tests/*_spec.lua`, with fresh, isolated WoW mocks for each example. To run a single module, use `busted tests/Keys_spec.lua`; to select named examples, use `busted --filter="generic item fallback" tests`.

## Companion App

The companion app's Rust workspace lives in `companion/`. With [Just](https://just.systems/) and Node.js installed, start the local Worker and tray app together with:

```sh
just dev
```

The tray app connects to `https://arbitrage-wow.fyi` by default. `just app` and `just dev` point it at the local Worker on `http://127.0.0.1:8787`, and `ARBITRAGE_WORKER_URL` overrides the endpoint. Run either process separately with `just app` or `just worker`.

Run format check, lint, and tests:

```sh
just check-rust
```

Run `just check` for all six checks. The formatting recipes check only; use `stylua .` or `cargo fmt --manifest-path companion/Cargo.toml --all` to apply formatting.
