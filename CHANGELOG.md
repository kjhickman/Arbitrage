# Changelog

## Unreleased

### Addon

- Dim the Opportunities table during a full scan and show elapsed wait time, auction-reading progress, and pricing progress.
- Keep pricing a full scan when the Auction House closes after its auctions are read, instead of discarding the scan and spending the 15 minute cooldown for nothing.
- Say in chat when Arbitrage starts pricing a full scan another addon, such as Auctionator, started, and when that scan is cancelled or throttled.

## v0.7.1

### Addon

- Control Crafting Cost, Best-case Crafting Cost, Vendor Profit, and Best-case Vendor Profit independently in item tooltips, preserving existing visibility choices on upgrade.
- Choose whether tooltip pricing details stay compact, appear while holding Shift, or always appear.
- Move craft-list filters into the Auction House panel.
- Add a setting to show or hide profits in the crafting window.

## v0.7.0

### Addon

- Filter the craft list by a minimum profit, from every known craft through any profit at all up to 100 gold. The same threshold decides which crafts show a profit in the profession window.
- Colour the profit in the profession window green when a craft makes money and red when it loses money, including when the estimate is uncertain. Hover a craft to see why an estimate is uncertain.
- Show the last scan as an age, such as `31 minutes ago`, instead of a timestamp.
- Show scan progress on the Full Scan button while a scan runs, and the minutes remaining when a scan is still on cooldown.
- Keep waiting for a slow full scan instead of abandoning it after 30 seconds, which discarded the result on busy realms and spent the 15 minute cooldown for nothing.
- Re-request item data the client drops during a full scan, and stop waiting on it after 2 seconds, so a scan no longer stalls on a handful of items.
- Skip auctions whose item does not exist rather than waiting on data that can never arrive.
- Report progress while reading a large scan instead of leaving the chat frame silent.

### Companion

- Retry a failed sync every five minutes, and sync whenever you sign in or the app starts, instead of waiting for the game to next write its saved variables. A sync that failed could previously stay stuck until the next time you logged out.

## v0.6.0

### Addon

- Automatically prune a character's stored recipes when a profession is unlearned, while keeping shared professions known by other characters on the realm.
- Add `/arb forget <character>` to manually remove stored recipes for a character (such as a deleted alt).
- Ignore linked and guild profession windows when capturing recipes.
- Support live WoW: Forever realms by keying market and recipe data by ruleset (`Normal`, `PvP`, `Roleplay`, `Roleplay PvP`, `Hardcore`) and including character surnames. Open each profession window once after updating to re-save recipes under your ruleset realm.
- Fail fast and record the account-wide cooldown immediately when the Auction House throttles a full scan request.

### Companion

- Update WoW client auto-detection for the live `_forever_` directory instead of `_classic_beta_`.
- Include TradeSkillMaster Forever realm and regional market pricing in synced market data (excluding random-suffix gear).
