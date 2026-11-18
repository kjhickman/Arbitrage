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

Sign in with Battle.net. Only your own data is uploaded. The game reads synced prices at login, so they appear the next time you log in or `/reload`.

## Getting Started

1. On each character, open each profession's window once so Arbitrage learns its recipes.
2. At your faction's Auction House, open the **Arbitrage** tab and click **Full Scan**.
3. Check your opportunities there, or anywhere with `/arb`.

Arbitrage works with your faction's Auction House only. Neutral Auction Houses, such as Booty Bay's, keep their own prices and take a larger cut, so Arbitrage doesn't scan or price them.

Using Auctionator? Turn on **Auctionator > Advanced > Use alternate slower scan mode by default** so both can scan (wait for the chat message indicating Arbitrage is done if scanning from Auctionator).

## Commands

- `/arb`: toggle the Arbitrage window
- `/arb settings`: open the settings
- `/arb status`: show stored data
- `/arb forget <character>`: remove a character's recipes
- `/arb help`: list commands
