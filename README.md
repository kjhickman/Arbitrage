# Arbitrage

Addon that calculates rolling market values from Auction House full scans and the cheapest known crafting cost for items.

Run `/arb scan` at the Auction House, then market values will be displayed on tooltips. If Auctionator is installed, its full scans also update Arbitrage.

## Crafting Costs

Open each character's profession window once to record its learned recipes. Arbitrage combines recipes recorded for all characters on the realm, then compares buying and crafting each intermediate material to find the cheapest route.

Crafting Cost uses rolling Auction House prices. Minimum Craft Cost uses the cheapest per-unit buyout from the latest full scan. Both costs choose the cheapest vendor, Auction House, or crafting path for each reagent. Hold Shift for each plan's final materials to buy and their purchase sources.

Vendor prices are learned when you visit merchants and shared by same-faction characters on the realm. Only unlimited-stock, coin-priced offers are used. The addon does not account for inventory, cooldowns, proc yields, or listing depth.

Auction House cuts do not affect crafting cost because reagents are purchased at their full price.

## Commands

`/arb` or `/arbitrage`

- `/arb status` - show stored item count, tooltip setting, latest scan, and recent scan count
- `/arb count` - show stored item count
- `/arb scan` - run a full Auction House scan (shared 15-minute cooldown)
- `/arb item <dbKey>` - show the stored market value for a database key
- `/arb recipes` - show recorded recipe and character counts
- `/arb tooltip` - toggle market and crafting values in item tooltips

## Development

Linting uses [wowlua-ls](https://github.com/TradeSkillMaster/wowlua-ls) v0.27.0.

```sh
stylua .
stylua --check .
wowlua_ls check . --severity hint
```
