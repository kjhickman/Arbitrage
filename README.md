# Arbitrage

Find profitable crafts and flips on the Auction House. Arbitrage shows what an item's "market value" is and the cheapest way to craft it, making it easy to spot ways to turn a profit.

Run `/arb scan` at the Auction House, then hover items. If Auctionator is installed, its full scans also update Arbitrage.

## Spotting Profits

- **Market Value** — what the item currently sells for.
- **Crafting Cost** — the cheapest way to make it, choosing between vendor, Auction House, and crafting at every intermediate step.
- **Minimum Craft Cost** — the same, using the cheapest per-unit buyouts from the latest full scan.

Hold Shift to see the exact cheapest recipe.

## Recipes

Open each character's profession window once to record its learned recipes. Arbitrage combines recipes recorded for all characters on the realm, then compares buying and crafting each intermediate material to find the cheapest route.

Vendor prices are learned when you visit merchants and shared by same-faction characters on the realm. Only unlimited-stock, coin-priced offers are used. The addon does not account for inventory, cooldowns, or listing depth.

## Commands

`/arb` or `/arbitrage`

- `/arb status` - show stored item count, tooltip setting, latest scan, and recent scan count
- `/arb count` - show stored item count
- `/arb scan` - run a full Auction House scan (shared 15-minute cooldown)
- `/arb item <dbKey>` - show the stored market value for a database key
- `/arb recipes` - show recorded recipe and character counts
- `/arb tooltip` - toggle market and crafting values in item tooltips

## Development

Tests use LuaJIT (Lua 5.1 semantics). Linting uses [wowlua-ls](https://github.com/TradeSkillMaster/wowlua-ls) v0.27.0.

```sh
for test in tests/*_test.lua; do luajit "$test"; done
stylua .
stylua --check .
wowlua_ls check . --severity hint
```
