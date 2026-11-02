# Changelog

All notable changes to GuildForge are listed here.

## [0.14.0] - 2026-11-02

### Added
- **Clear my data** in Settings (and `/guildforge clear`): forget everything received from guildmates and download it again fresh. Your own professions and recipes are kept.
- **Built for WoW Forever:** separate Forever and Classic Era TOCs, and a GuildForge entry in Esc → Options → AddOns.

### Changed
- **Renamed to GuildForge.** The window, minimap button (now "GF"), commands (`/guildforge`, `/gforge`; `/guildcraft` still works) and saved data all use the new name. Data saved under the old name isn't carried over: guildmates' data downloads again on the first sync, and opening each profession once re-shares your own recipes.
- **Much lighter syncing for big guilds.** Logging in or pressing Sync now sends one short summary per player instead of everyone re-sending their professions. Guildmates only send the pieces that actually changed, and replies are spread out over a few seconds.
- People who leave the guild are removed from your saved data, not just hidden.
- Item tooltips and the All tab do less work, so they stay smooth during big syncs.
- When WoW Forever blocks addon chat (for example in combat in instances), guild messages wait and send afterwards instead of being dropped.

### Removed
- The guild master "Reset guild data" button, replaced by the per-player **Clear my data**.

## [0.13.0] - 2026-10-31

### Added
- **Not known in guild** is shared with the whole guild: any member's trainer visits fill in everyone's list.
- Each guildmate's GuildForge version in crafter and minimap tooltips, plus `/guildforge who`.
- Data is kept separately for each guild, so alts in other guilds don't mix.
- Support for WoW: Forever first and last names, and for same-named characters on different realms.

### Fixed
- A message the game kept refusing could stall all of a player's syncing.
- Classic Era trainer recipes weren't added to **Not known in guild**.
- People who left the guild still showed up in lists.

## [0.12.0] - 2026-10-31

### Added
- **Ask a crafter:** whisper the best online crafter with the item link and the mats you have.
- **Shopping list** tab with combined materials, and "need 4 more" on item tooltips.
- Item tooltips show which guildmates craft an item and which recipes use it.
- Online dots and "last seen" times for crafters.
- Profession cooldown tracking (Mooncloth, transmutes, Salt Shaker), shared with the guild.
- **Not known in guild** recipes from trainers.
- Settings panel: minimap button, item tooltips, sync on login, quiet mode, window scale.
- WoW: Forever support from the same files.

### Fixed
- Duplicate crafter names caused by dropped sync messages.
- The settings panel was see-through in Classic.
- Online dots weren't green.

## [0.10.0] - 2026-10-31

### Added
- WoW-styled window with profession tabs and icons down the right side.
- Recipe icons, reagents and your bag and bank counts, with a **Have mats** filter.
- GF minimap button with a count of guildmates online with GuildForge.
