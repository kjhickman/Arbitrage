# Arbitrage

Addon that calculates rolling market values from Auction House full scans and the cheapest known crafting cost for items.

Run `/arb scan` at the Auction House, then market values will be displayed on tooltips. If Auctionator is installed, its full scans also update Arbitrage.

## Crafting Costs

Open each character's profession window once to record its learned recipes. Arbitrage combines recipes recorded for all characters on the realm, then compares buying and crafting each intermediate material to find the cheapest route.

Crafting cost is shown per output item. The tooltip lists the final materials to buy after cheaper intermediates are crafted. The MVP uses only rolling Auction House prices; vendor prices, inventory, cooldowns, proc yields, and listing depth are not included.

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

```sh
stylua .
stylua --check .
selene .
```
