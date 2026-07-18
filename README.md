# Arbitrage

Companion addon for Auctionator that calculates rolling market values from Auction House full scans.

Requires Auctionator. Run an Auctionator full scan, then the market value will be displayed on tooltips.

## Commands

`/arb` or `/arbitrage`

- `/arb status` - show stored item count, tooltip setting, latest scan, and recent scan count
- `/arb count` - show stored item count
- `/arb item <dbKey>` - show the stored market value for a specific Auctionator database key
- `/arb tooltip` - toggle market values in item tooltips

## Development

```sh
stylua .
stylua --check .
selene .
```
