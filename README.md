# Arbitrage

Arbitrage targets **World of Warcraft: Forever**.

Find profitable crafts and flips on the Auction House. Arbitrage shows what an item's "market value" is and the cheapest way to craft it, making it easy to spot ways to turn a profit.

Open the Arbitrage tab at the Auction House, run a scan, then hover items.

The Arbitrage Auction House tab ranks known craftable items by estimated net profit per craft. It uses rolling market
values for the primary estimate and shows the latest scan's minimum material cost as a best case. Crafts appear when
either estimate is profitable. Auction House cuts are included; listing deposits, available material depth, sale rate,
inventory, and recipe cooldowns are not. Its sortable table separates normal and minimum crafting costs and their
corresponding estimated and best-case profits.

## Spotting Profits

- **Market Value** — what the item currently sells for.
- **Crafting Cost** — the cheapest way to make it, choosing between vendor, Auction House, and crafting at every intermediate step.
- **Minimum Craft Cost** — the same, using the cheapest per-unit buyouts from the latest full scan.

Hold Shift to see the exact cheapest recipe.

## Recipes

Open each character's profession window once to record its learned recipes. Arbitrage combines recipes recorded for all characters on the realm, then compares buying and crafting each intermediate material to find the cheapest route.

Vendor prices are learned when you visit merchants and shared by same-faction characters on the realm. Only unlimited-stock, coin-priced offers are used. The addon does not account for inventory, cooldowns, or listing depth.

## Commands

- `/arb` or `/arb help` - show all commands
- `/arb status` - show stored data and settings status
- `/arb settings` - open the Arbitrage settings

## Development

Tests use PUC Lua 5.1.5. Linting uses [wowlua-ls](https://github.com/TradeSkillMaster/wowlua-ls) v0.32.1. Because that release does not yet provide a Forever flavor, `.wowluarc.json` uses its Retail flavor as the closest available model for Forever's modern UI API. Install the pinned command-line binary on macOS or Linux with:

```sh
./scripts/install-wowlua-ls
```

This installs it in `.tools/`. VS Code and JetBrains contributors can instead install the official wowlua-ls extension, which includes the language server.

```sh
for test in tests/*_test.lua; do lua "$test"; done
stylua .
stylua --check .
.tools/wowlua_ls check . --severity hint
```
