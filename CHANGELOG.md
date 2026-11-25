# Changelog

## v0.9.0-beta.1

### Addon

- Add a shopping list. Click a craft in Opportunities, choose how many crafts in a box like the crafting window's, and click Add to List, or right-click a craft and choose Add to Shopping List. Change a craft's count on the list the same way: type it and press Enter, or use the arrows or the mouse wheel, Shift for ten. In the Auction House, tabs above the Arbitrage table switch between Opportunities and the Shopping List, which also has a tab of its own in the `/arb` window.
- The Shopping List adds up every material its crafts use, with what's in your bags and banks counting first. Materials Arbitrage would craft for you, such as bars smelted from ore when that's cheaper, are listed with the materials to make them, in whole crafts. Each material shows what's left to buy at its Buyout, or a vendor's price when lower, and the list totals it.
- Hide what you have, at the top right of the Shopping List, leaves out the materials you already have all you need of, and is remembered.
- Choose whether the Shopping List makes or buys each material a character can craft, such as bars you'd rather buy than smelt. The icon beside the material, the menu bar's Professions tools to make it or a gold coin to buy it, switches it for every craft on the list with one click, and hovering it shows what making and buying what's still needed cost, to the copper, and who makes it.
- Refresh Prices, at the bottom of the Shopping List in the Auction House, searches every material your crafts could use, made or bought, so each cost counts every listing buying it would take, cheapest first, leaving out your own auctions. A material with fewer listed than you need shows its cost in yellow, and the total says how many are short. The button counts through its searches, sends one the Auction House doesn't answer within 2 seconds again, and says in chat if it still doesn't.
- Buy from the Shopping List in the Auction House. A Next to buy card under your crafts shows the next material, how many, what each costs, and the total, and what's left to buy sits beside your gold. Buy asks the Auction House for its price and buys at once when it costs no more than shown; costing more, it shows the new price and waits for Buy anyway. Skip passes a material over, and clicking a material makes it the next. Short of gold for what's left on the list, Buy asks once a visit whether to keep buying. What you buy counts as yours while it waits in your mailbox, marked with an envelope beside its Have count, until you collect it.
- Once every commodity is bought, Review searches whatever sells one auction at a time, picks the cheapest whole auctions, and asks to buy them, listing any extra; Buy then buys them one a click. Purchases that fail are noted in chat.
- With Re-choose make/buy checked, as it is at first, Refresh Prices then makes or buys each material whichever way costs least at the prices it found, including ones you switched. Make-or-buy tooltips compare both ways at refreshed prices, and mark a price still from your latest scan.

## v0.8.7

### Companion

- Opt in to beta builds with **Settings → Receive Beta Updates** in the tray. Beta builds also offer **Return to Stable…**.

### Worker

- Serve the Companion's beta update feed without changing the stable channel.
- Fix syncs failing with "The worker returned HTTP 500." when a Companion first syncs a region's sales after updating to 0.8.6.

## v0.8.6

### Addon

- Use much less memory. Arbitrage holds about 20 MB less for saved and synced prices, and with the Companion's prices, logging in takes about half as long. A Full Scan on a busy Auction House needs about 23 MB extra instead of 56, and its longest frame dropped from about 50 ms to about 20. The Database tab holds about 40 MB instead of 100.
- Let go of the Database tab's rows when prices change while the tab is closed, after a scan, a vendor visit, or a recipe change. Reopening it then shows "Reading the price database..." for a few seconds; reopening it without a change is still instant.
- Record each Full Scan's Buyout and units listed beside its Market Value, and each Quick Scan's Buyouts and units. Quick Scans keep the newest of each hour, up to 48, from the last 14 days.
- Show that history. An item's price chart plots each day's average Buyout beside its average Market Value, over faint bars for the units listed, and hovering a day shows all three. The chart no longer draws a line at Market Value, which item details list. Item details list the units listed, and the Database tab adds a Listed column.
- With the Companion, show TradeSkillMaster's region-wide sales. Item details add a Region Sales section with the sale rate and average sale price, and the Database and Opportunities tables add a Sale Rate column. Random-enchant gear shows none, since TradeSkillMaster's figures for it blend every enchant.
- Add tooltip settings for Listed, Sale Rate, and Average Sale Price. Only Sale Rate is on by default, and each line is left out when there's nothing to show, such as without the Companion.
- The Database tab also lists items only a Quick Scan or TradeSkillMaster's Buyouts have seen, without a Market Value.
- The first login after updating converts your saved prices to the new format, which takes a moment once, and drops old prices of grey items. A Quick Scan from before updating isn't kept; your next one refreshes Buyouts. Without the Companion, logging in takes about a fifth of a second longer than before, since Arbitrage reads each saved scan back.
- Spread a Quick Scan's save over more frames, so its longest frame dropped from about 22 ms to 13. Pricing items is also faster.
- Show the Database tab once it has read prices, and sort its columns, in under half the time.
- Time a scan's waiting messages to its kind. A Full Scan says it usually takes about 20 seconds and a Quick Scan about 30; each says it's taking longer than usual 5 seconds past that, and both suggest cancelling after a minute. Quick Scans no longer suggest waiting 15 minutes to try again, since they have no cooldown.

### Companion

- Sync each scan's Buyouts and units listed, and your Quick Scans, so every PC gets them. Synced prices also include TradeSkillMaster's region-wide sales for each item: its average sale price and the share of its auctions that sell.
- Read the addon's new saved format. Update the Companion and the addon together: older Companions say "the saved database is version 3, not 2", and they can no longer sync either, saying "This database version is not supported." The first sync after updating downloads the last 30 days of prices again.
- Leave items the addon knows are grey out of synced prices.

### Worker

- Keep each scan's Buyouts and units, and keep one Quick Scan an hour beside one Full Scan an hour, so a Quick Scan never replaces a Full Scan.
- Send TradeSkillMaster's hourly Buyouts as price history, and its region-wide sales whenever they change, leaving out random-enchant gear, whose figures blend every enchant.

## v0.8.5

### Addon

- Click an item in the Opportunities or Database tab to open its details beside the window. A chart plots the item's average price each day over the last 14 days, with a dashed line at its Market Value; hover it for each day's price and scan count. Below the chart are its Market Value, Buyout, vendor sell price, and when a scan last listed it, then for items your characters can craft, Craft Cost, Buyout Craft Cost, and the materials to buy. Click the row again or the close button to close the details. Shift-clicking a row still links the item in chat.

### Companion

- Fix syncing, which stopped working once the server held about a week of TradeSkillMaster prices: syncs failed with "The worker returned a database the addon cannot store." and later HTTP 500, and the largest databases couldn't upload at all. A sync now sends a list of your scans, uploads each Full Scan once, one at a time, and downloads only the scans this PC doesn't have yet, keeping them for later syncs. A sync where nothing changed is a few kilobytes.
- Older Companions can no longer sync and say "This database version is not supported." Update to keep syncing. The first sync after updating downloads the last 30 days of prices again.
- Retry a failed sync every 5 minutes only when the connection or the server failed. Other failures, like needing to sign in again, wait for your next save, sign-in, or update instead of repeating.
- Say "Sync failed: The worker returned HTTP 500." instead of "Sync failed: Sync failed (HTTP 500)."

### Worker

- Send synced prices in batches of about 2 MB, so a sync no longer grows with the price history.
- Keep TradeSkillMaster realm and region prices for 30 days, the same as scans, instead of forever.

## v0.8.4

### Addon

- Speed up Full Scans. On a busy Auction House, the part after Blizzard responds dropped from about 38 seconds to 15 at the default **Scan Work Per Frame**, or about 7 at 20 ms: Arbitrage prices auctions as it reads them, sorts each item's prices once, skips item links that can't change a price, and reads more auctions each frame.
- Price the auctions Full Scans used to skip because WoW hadn't loaded their item yet, often a fifth of the Auction House, so thousands more items get a Market Value. Arbitrage requests each of those items once after reading and prices its auctions as soon as it loads. If an item's data still doesn't load, chat says how many auctions were skipped.
- Keep the random enchant of gear whose item link loads late in a Full Scan, instead of pricing it by item ID.
- While waiting on Blizzard, say a scan usually takes about 20 seconds instead of 30, and say it's taking longer than usual after 25 seconds instead of 30. A Full Scan suggests cancelling after 45 seconds instead of 60.
- Add **Scan Work Per Frame** under **Scans** in `/arb settings` to trade frame rate for speed while scanning and while the Database tab reads the price database. It defaults to 10 ms, up from a fixed 4 ms for scans and 8 ms for the Database tab, so both lower your frame rate a little more while they run.
- Show the Database tab's table sooner, and keep the game smoother while item details load afterwards. Arbitrage now reads gear stats for the **Stats** filter after the table appears, so that filter fills in a moment later. While item details load, the table updates at most twice a second instead of every frame, and only when what it shows changes, so it no longer blinks or briefly shows item numbers in place of names. Items that turn out grey drop out without re-sorting the whole table. Arbitrage also checks whether an item is grey once instead of on every price lookup, and spends less time on each item's Market Value and Craft Cost.
- List only the active filters above the Database and Opportunities tables, without the count of items or crafts shown.
- Remember which items are grey, so the Database tab leaves them out from the start instead of listing them until they load. Full Scans and Auctionator summary scans note the grey items they see.
- Fix Quick Scans refreshing Buyouts for only the few items WoW already had loaded, instead of every non-grey item listed (broken since v0.8.3). Arbitrage's own Quick Scans also ask Blizzard to leave grey items out of the results.

## v0.8.3

### Addon

- Ignore grey (Poor-quality) items in auction scans and pricing, and don't add Arbitrage lines to their tooltips.
- Trim `/arb status` to stored data and recent scans. Settings live in `/arb settings`, and it no longer shows when Companion prices were synced.
- Add an optional minimap button, off by default. Turn it on with **Show Minimap Button** in `/arb settings`, then left-click it to open or close the Arbitrage window, right-click it for settings, or drag it around the minimap.

### Companion

- Use the Arbitrage icon for Arbitrage Data in the in-game AddOns list.

## v0.8.2

### Addon

- Add **Quick Scan** to refresh Buyouts without changing Market Value history or using the full-scan cooldown. Auctionator's default summary scans also refresh Buyouts. Quick Scan and Full Scan sit at the bottom right of the Arbitrage tab, and hovering either shows what it does and when it last ran. The standalone window no longer shows them, so its table fills the window.
- Replace the Typical, Last Scan, and Buy Now, Sell Later views with one Opportunities table showing Craft Cost and Profit at Market Value beside Buyout Craft Cost and Buyout Profit at the latest scan's cheapest listings. A craft is listed when either profit passes your filters, and the other is grayed. Row tooltips now list only the crafters and the materials to buy, and Net Sale, ROI, and the break-even listing are gone.
- Show the item's own Buyout on item tooltips, under Market Value. Turn it off with **Show Buyout** in `/arb settings`.
- Rename Buyout Cost to Buyout Craft Cost and the Database tab's Min Buyout to Buyout, and describe Market Value, Buyout, Craft Cost, and Buyout Craft Cost the same way everywhere.
- With pricing details, item tooltips start with when a scan last listed the item instead of ending with Market Value data. The Database tab's Last Seen counts Quick Scans too.
- Show Buyout Profit in the profession window at the item's Buyout instead of its Market Value.
- Say how long a scan usually takes while it waits for a response from Blizzard.
- Take each item's Buyout from the newest scan that could have listed it, whether that's a Full Scan, a Quick Scan, or Companion prices from your other PCs or TradeSkillMaster. Random-enchant gear keeps your last Full Scan's Buyouts when newer TradeSkillMaster prices load, since TradeSkillMaster doesn't price it.
- Price gear whose item link doesn't load during a Full Scan by its item ID instead of skipping it, so items like Lionheart Helm no longer go missing. Chat names up to five of them with the total.
- Show which crafters can gain profession skill from each craft in Opportunities, with the orange, yellow, and green skill-up icons from the profession window. Hover a craft for each crafter's chance, as of their last profession window update.
- List Arbitrage under Auctions in the AddOns list, beside Auctionator and TradeSkillMaster.
- Show Craft Cost, Buyout Craft Cost, and Craft Profit on recipe item tooltips for the item the recipe teaches, even before anyone learns it. This works for professions whose window a character on the realm has opened since updating.

### Companion

- Sync your last Full Scan's Buyouts for random-enchant gear alongside newer TradeSkillMaster prices, with when each was scanned, so the addon can keep them.

### Worker

- Check TradeSkillMaster realm prices every 15 minutes, skip unchanged feeds, and honor TradeSkillMaster's retry window when rate-limited.

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
