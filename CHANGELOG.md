# Changelog

## Unreleased

### Addon

- Add an Arbitrage window, opened with `/arb` or from the minimap's Addon Compartment menu, to check your Opportunities away from the Auction House. Full scans still run at the Auction House, and `/arb help` lists the commands.
- Filter the Opportunities table by profession, crafter (including whichever character you are logged in as), and whether to sell to the Auction House or a vendor, and search it by name or item ID.
- Add a Database tab to the Arbitrage window listing every item priced for your realm and faction. Search it by name or item ID, sort it by Market Value, the latest scan's cheapest buyout, Craft Cost, or when a scan last saw the item, and hover an item for its full tooltip.
- Filter the Database tab by category, slot, rarity, stats, required level, item level, Market Value range, whether you can craft an item or craft it at a profit, when it was last seen, and uncertain prices. While filtering, the active filters and how many items match are listed above the table.
- Colour item names by rarity in the Opportunities and Database tables.
- Price random-suffix gear per suffix in tooltips and the Database tab, so items "of the Bear" and "of the Owl" no longer share one price.
- Give the crafting window its own minimum profit, under **Crafting Window** in `/arb settings`, instead of sharing the Opportunities table's. It starts at your current threshold.
- Dim the Opportunities table during a full scan and show elapsed wait time, auction-reading progress, and pricing progress.
- Keep pricing a full scan when the Auction House closes after its auctions are read, instead of discarding the scan and spending the 15 minute cooldown for nothing.
- Say in chat when Arbitrage starts pricing a full scan another addon, such as Auctionator, started, and when that scan is cancelled or throttled.
- Show crafts the chosen crafter or profession can make even when another character knows a cheaper recipe for the same item, priced with the best recipe they know.
- Add a Cancel Scan button while waiting for the server's auction data, so a scan that never gets a response no longer blocks the Opportunities table until the Auction House closes.
- Show how the latest full scan ended, and how long ago, when hovering the Full Scan button.
- Drop support for neutral Auction Houses. Arbitrage now always uses your faction's prices and Auction House cut, its tab at a neutral Auction House explains why it is empty, and full scans there, including another addon's, are no longer saved. This also fixes the Database tab showing the wrong Auction House's prices after visiting a neutral one.
- Shift-click an item in the Opportunities or Database table to link it in chat, and Ctrl-click to preview it in the dressing room.

### Companion

- Write synced prices as daily totals, keeping the file the game loads at login small. Update the addon too, since older versions ignore prices synced in this format.
- Stop syncing neutral Auction House prices, so sync now returns up to 12 recently played faction markets instead of 6.

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
