# Changelog

All notable changes to GuildForge are listed here.

## [1.0.6] - 2026-11-04

### Changed
- **Much faster recipe sharing.** Several recipes now travel in each message instead of one, so a 150-recipe profession reaches the guild with all its reagents in about a minute (62 messages) instead of about five (310 messages).
- **Stays inside WoW's addon message limit.** Every message now waits its turn and goes out at the pace the game allows (a short burst, then about one per second), so the game no longer refuses messages, even in a big guild when someone logs in and catches up with everyone.

### Note
- Everyone in the guild should update: GuildForge 1.0.5 and earlier can't read the new packed recipe lists, so they won't receive recipes from 1.0.6 players until they update. 1.0.6 still reads lists from older versions.

## [1.0.5] - 2026-11-04

### Fixed
- **Dropping a profession now clears it.** If someone unlearns a profession, its recipes and cooldowns are removed for them and for the whole guild, so they no longer show up as a crafter of something they can't make. Guildmates who were offline catch up the next time they and that player are online together.
- Profession and skill changes made less than 15 seconds after the last update were never shared until the next login. They're now sent as soon as the 15 seconds are up.
- A profession update that lost part of itself on the way could make guildmates think a profession was dropped. Incomplete updates are now ignored.

## [1.0.4] - 2026-11-03

### Fixed
- Profession ranks from trainers (like **Apprentice Cook** and **Journeyman Cook**) showed up in **Not known in guild** as if they were recipes. They're no longer saved or shared, and ones already saved are cleared.

### Changed
- **Not known in guild** is now a simple list: each recipe shows its icon, name and the skill it needs. Nobody in the guild knows these yet, so there were never reagents to show, and the list no longer does the extra work of checking your bags for them.

## [1.0.3] - 2026-11-02

### Fixed
- **Nothing was being shared on Classic Era.** A check meant to pause messages while WoW Forever blocks addon chat misread Classic's answer, so every message waited forever. Messages now only wait in instances or combat, when the game really says chat is blocked. `/gf status` shows whether sending is being held.
- Guildmates' data never arrived on realms whose names contain an apostrophe or other punctuation (like Nek'Rosh): every guild message was rejected as coming from the wrong sender.

## [1.0.2] - 2026-11-02

### Changed
- The window title now just says **GuildForge**; the version number moved to the bottom of the Settings panel.

## [1.0.1] - 2026-11-02

### Changed
- Re-release of 1.0.0 with no changes to the addon.

## [1.0.0] - 2026-11-02

First release. **Your guild's professions, all in one place.** GuildForge shares every member's professions and known recipes over hidden guild addon messages, so you can see who can craft what, what it takes, and whether you already have the mats, without spamming guild chat.

Built for **WoW Forever**, and also works on **Classic Era**.

### Features
- **Every profession at a glance.** Spellbook-style tabs with crafter counts, recipe counts and the top crafter for each profession.
- **Crafters, ranked and live.** Skill bars by rank, green dots for who's online, and when offline crafters were last seen.
- **Recipes with reagents.** Icons, item quality, who can craft it, and whether you have the mats in your bags (plus your bank).
- **Ask a crafter.** One click whispers the best online crafter with the item link and the mats you already have.
- **Shopping list.** Queue recipes and get one combined materials list, with "need 4 more" on item tooltips everywhere, including the auction house.
- **Item tooltips.** See which guildmates craft an item and which recipes use it.
- **Cooldowns.** Mooncloth, transmutes and the Salt Shaker are tracked and shared with the guild.
- **Not known in guild.** Recipes seen at trainers that nobody in the guild has learned yet, filled in by everyone's trainer visits.
- **Search everything:** recipes, crafters, professions and reagents, plus a **Have mats** filter.
- **Light on guild chat.** One short summary per player when you log in; only data that changed is downloaded. Built to handle large guilds.
- **WoW Forever ready.** Supports first and last names, holds messages while the game blocks addon chat (like combat in instances), and appears in Esc → Options → AddOns.
- **Settings:** minimap button, item tooltips, sync on login, quiet mode, window scale, re-share your recipes, and **Clear my data** to download everything fresh.

### Getting started
1. Click the **GF** minimap button or type `/gf`.
2. Open each of your professions once so GuildForge can share your recipes.
3. Visit trainers to fill in **Not known in guild**.

Your guildmates need GuildForge too: the more people running it, the more complete the guild's list gets.

### Known notes
- WoW Forever support is built against the beta (interface 16001). If launch changes it, an update will follow quickly.
- Found a bug or have an idea? Open an issue on [GitHub](https://github.com/TheFrosty02/GuildForge/issues).
