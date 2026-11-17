# Arbitrage

**Note: still under pretty heavy development, things could break.**

Arbitrage targets **World of Warcraft: Forever**.

Find profitable crafts and flips on the Auction House. Arbitrage shows what an item's "market value" is and the cheapest way to craft it, making it easy to spot ways to turn a profit.

Open the Arbitrage tab at the Auction House to run a scan, then check craft opportunities from anywhere with `/arb` or the minimap Addon Compartment menu.

The Arbitrage window and Auction House tab rank known craftable items by estimated net profit per craft. It uses rolling market values for the primary estimate and shows the latest scan's minimum material cost as a best case. Auction House cuts are included; listing deposits, available material depth, sale rate, inventory, and recipe cooldowns are not. Its sortable table separates normal and best-case crafting costs and their corresponding estimated and best-case profits.

## Spotting Profits

*   **Market Value** — what the item currently sells for.
*   **Crafting Cost** — the cheapest way to make it, choosing between vendor, Auction House, and crafting at every intermediate step.
*   **Best-case Crafting Cost** — the same, using the cheapest per-unit buyouts from the latest full scan.

Hold Shift to see the exact cheapest recipe.

## In Your Profession Window

Every recipe you know shows its estimated profit per craft right in the list: green when the craft makes money, red when it loses money. Hover one for the full breakdown, including why an estimate might be uncertain.

## Choosing What To Show

Arbitrage lists crafts that turn a profit, counting a craft if either its estimated profit or its best-case profit clears the bar. Use the **Filter** menu on the Arbitrage tab to set **Minimum profit** anywhere from 2 silver to 100 gold, or to show every known craft whether it makes money or not. The same threshold decides which crafts show a profit in your profession window.

Estimates built on thin, stale, or volatile scan data are marked as uncertain, and can be hidden entirely.

## Price Database

The **Database** tab in the Arbitrage window lists every item Arbitrage has prices for, priciest first. Search by name or item ID, and sort by market value, latest minimum buyout, crafting cost for items your characters can make, or when the item was last seen. Hover any row for its full tooltip.

Filter the list by category and subcategory (Armor > Plate), slot, rarity, stats (Strength + Stamina finds everything "of the Bear"), required level, item level, a market value range in gold, items you can craft or profitably craft, and how recently the item was seen. Active filters are listed above the table.

## Recipes

Open each character's profession window once to record its learned recipes (I didn't want to manually compile all the new Forever recipes). Arbitrage combines recipes recorded for all characters on the realm, then compares buying and crafting each intermediate material to find the cheapest route.

Vendor prices are learned when you visit merchants and shared by same-faction characters on the realm. Only unlimited-stock, coin-priced offers are used. The addon does not account for inventory, cooldowns, or listing depth.

## Using With Auctionator

To scan with Arbitrage while Auctionator is enabled, turn on **Auctionator > Advanced > Use alternate slower scan mode by default**.

## Commands

*   `/arb` - toggle the Arbitrage window (also available in the minimap Addon Compartment menu)
*   `/arb help` - show all commands
*   `/arb status` - show stored data and settings status
*   `/arb settings` - open the Arbitrage settings
*   `/arb forget <character>` - remove stored recipes for a character

**Also in development, a companion app: [Arbitrage Companion](https://github.com/kjhickman/Arbitrage/releases/latest)**

It syncs your scan data across multiple PCs, and fills in market prices from TradeSkillMaster's public Forever data so you have numbers to work with before you have scanned much yourself. Sharing scans directly with other players is still to come.
