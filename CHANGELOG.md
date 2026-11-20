# Changelog

## Unreleased

### Addon

- Show Craft Cost, Buyout Cost, and Craft Profit on recipe item tooltips for the item the recipe teaches, even before anyone learns it. This works for professions whose window a character on the realm has opened since updating.

## v0.8.1

### Addon

- Choose how to price the Opportunities table: **Typical** uses Market Value, **Last Scan** uses scanned buyouts, and **Buy Now, Sell Later** compares profit at the scanned sale price and at Market Value using the same scanned material cost. Scan-based views show the scan age and a shopping list priced from the scan.
- Apply the Opportunities minimum profit filter to the selected price view, and explain the price views and uncertain prices in the glossary.
- Show estimated profit per craft for unlearned recipes in the profession trainer window when recipe and price data are available.
- Fix Market Value rounding that could make crafting window profits flicker by one copper without a new scan.
- Warn when a full scan is taking longer than usual and suggest trying again if the server hasn't sent auction data after a minute.

### Companion

- Rename **Launch at Login** to **Launch on Startup** and clarify the warning if the setting can't be updated.

## v0.8.0

### Addon

- Add an Arbitrage window with Opportunities and Database tabs, opened with `/arb` or from the minimap's Addon Compartment menu, to check prices away from the Auction House. Full scans still run at the Auction House, and `/arb help` lists the commands.
- Filter the Opportunities table by profession, crafter (including whichever character you are logged in as), and whether to sell to the Auction House or a vendor, and search it by name or item ID. Filtering by crafter or profession prices each craft with the best recipe they know, and while any filter is on, the active filters and how many crafts they leave are listed above the table.
- Show costs, sales, and profits per item in the Opportunities table and the crafting window, with per-craft totals in tooltips for recipes that make several items. The minimum profit settings and sorting work per item too.
- Rename Best Profit to Buyout Profit, since it uses the latest scan's cheapest buyouts and isn't always better than Profit, remove the Best Cost column, and gray out the Profit of crafts listed only for their Buyout Profit.
- Give item names more room in the Opportunities table: rows show only AH or Vendor beside the name, and professions and crafters move to the row tooltip.
- Make Opportunities row tooltips self-contained, with Net Sale, Craft Cost, profits, crafters, and the materials to buy for one craft, instead of repeating the item tooltip's own pricing lines.
- Rename the Opportunities filter checkboxes to Hide uncertain opportunities and Hide crafts profitable only at buyout prices, and update the pricing glossary to the new names and per-item values.
- Explain uncertain prices in plain words, such as "fewer than 3 days of scans" or "last seen over 3 days ago", and say how prices firm up when hiding uncertain opportunities leaves the list empty.
- Add a Database tab listing every item priced for your realm and faction. Search it by name or item ID, sort it by Market Value, the latest scan's cheapest buyout, Craft Cost, or when a scan last saw the item, and hover an item for its full tooltip.
- Filter the Database tab by category, slot, rarity, stats, required level, item level, Market Value range, whether you can craft an item or craft it at a profit after the 5% Auction House cut, when it was last seen, and uncertain prices. Filters are saved between sessions, and while any are on, they are listed above the table with how many items match.
- Colour item names by rarity, show prices of 1 gold or more without copper, and Shift-click an item to link it in chat or Ctrl-click to preview it, in both the Opportunities and Database tables.
- Price random-suffix gear per suffix in tooltips and the Database tab, so items "of the Bear" and "of the Owl" no longer share one price.
- Drop support for neutral Auction Houses. Arbitrage now always uses your faction's prices and Auction House cut, its tab at a neutral Auction House explains why it is empty, and full scans there, including another addon's, are no longer saved.
- Replace the Vendor Profit and Best-case Vendor Profit tooltip lines with an optional Craft Profit line, Market Value after the 5% Auction House cut minus Craft Cost, turned on with Show Craft Profit in settings.
- Rename Crafting Cost to Craft Cost and Best-case Crafting Cost to Buyout Cost in item tooltips, settings, and `/arb status`, and use Title Case for every setting name.
- Label the tooltip's scan details Market Value data instead of MP data, show how long ago the latest scan was, and head material lists with what they cover, such as "Materials for one item (Craft Cost):".
- Rename the Compact pricing details choice to Never, since it never adds the details.
- Give the crafting window its own minimum profit, under **Crafting Window** in `/arb settings`, instead of sharing the Opportunities table's. It starts at your current threshold.
- Show the profit or loss on hover for crafting window recipes whose profit is below the minimum, instead of leaving them looking unpriced.
- Dim the Opportunities table during a full scan and show elapsed wait time, auction-reading progress, and pricing progress, with a Cancel Scan button while waiting for the server's auction data.
- Keep pricing a full scan when the Auction House closes after its auctions are read, instead of discarding the scan and spending the 15 minute cooldown for nothing.
- Say in chat when Arbitrage starts pricing a full scan another addon, such as Auctionator, started, and when that scan is cancelled or throttled.
- Show how old the stored prices are, and how this session's latest full scan ended, when hovering the Full Scan button. `/arb status` also shows how long ago the Companion synced the loaded prices.
- Show in chat how many recipes were recorded the first time a profession window is opened, and name the recipes a character learns after that.
- Stop warning about enchants and other recipes that make no item, and only warn about unsupported recipes again when more of them appear.

### Companion

- Write synced prices as daily totals, keeping the file the game loads at login small. Update the addon too, since older versions ignore prices synced in this format.
- Stop syncing neutral Auction House prices, so sync now returns up to 12 recently played faction markets instead of 6.
- Note under the tray menu's last sync time that WoW loads synced prices at login or `/reload`, and record the sync time in the synced prices so `/arb status` can show their age.

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
