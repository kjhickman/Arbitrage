# Changelog

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
