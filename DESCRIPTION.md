# Arbitrage

**Find out which of your crafts make gold on World of Warcraft: Forever, and exactly how much.**

Arbitrage scans the Auction House and ranks every recipe your characters know by profit, after the Auction House cut.

- **Every craft, ranked.** One list for all your characters on the realm, showing who can make each craft and whether to sell to the Auction House or a vendor.
- **True crafting costs.** For each material it buys, uses a vendor, or crafts, whichever is cheapest, all the way down the recipe tree.
- **Prices you can trust.** Market values use 14 days of scans with recent days weighted most, and shaky estimates are marked in yellow.
- **Everywhere you need it.** Profit beside each recipe in your profession window, prices on item tooltips, and a searchable database of every item you've priced.

## Arbitrage Companion

**[Arbitrage Companion](https://github.com/kjhickman/Arbitrage/releases/latest)** is an optional desktop app for Windows and macOS that keeps your prices fresh:

- Fills in prices from TradeSkillMaster's public Forever data.
- Syncs your scans across PCs.
- Runs in the tray and syncs whenever the game saves.

Sign in with Battle.net. Only your own data is uploaded. The game reads synced prices at login, so they appear the next time you log in or `/reload`; `/arb status` shows how long ago the loaded prices were synced.

## Getting Started

1. On each character, open each profession's window once so Arbitrage learns its recipes.
2. At your faction's Auction House, open the **Arbitrage** tab and click **Full Scan**.
3. Check your opportunities there, or anywhere with `/arb`.

Open each profession window again after updating Arbitrage to record skill-up chances. Opportunities uses WoW's profession skill-up icons to show the best chance among the listed crafters. Hover a craft to see who can gain skill and how many points per craft, based on each crafter's last profession window update.
To hide the icons without hiding the hover details, uncheck **Show Skill-Up Icons** under **Opportunities** in `/arb settings`.

Arbitrage works with your faction's Auction House only. Neutral Auction Houses, such as Booty Bay's, keep their own prices and take a larger cut, so Arbitrage doesn't scan or price them.

Use **Quick Scan** to refresh buyouts for materials and other non-gear items, even while Full Scan is on cooldown. Full Scan still updates Market Value and gear prices. Quick Scan prices stay on this computer and aren't uploaded by the Companion.

Using Auctionator? Its default summary scan also refreshes Arbitrage's buyouts. Its alternate slower scan updates Market Value as well. Wait for Arbitrage's chat message before closing the Auction House.

## Commands

- `/arb`: toggle the Arbitrage window
- `/arb settings`: open the settings
- `/arb forget <character>`: remove a character's recipes (necessary after deleting a character)
- `/arb help`: list commands
