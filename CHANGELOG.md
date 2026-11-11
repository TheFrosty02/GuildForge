# Changelog

All notable changes to GuildForge are listed here.

## [1.2.0] - 2026-11-11

### Added
- **Guild Home**: the window now opens on a Home tab with guild news, who's online with GuildForge and their professions, requests you can make, cooldowns that are ready, and your Request Board and Shopping List at a glance. Searching from Home searches the whole guild.
- **Guild news**: skill milestones (every 25 points), professions taken up, newly learned recipes (marked when they're the first in the guild) and finished requests, worked out from what guildmates already share. A leveling spree within a few hours stays one line. Nothing shows for data you're only catching up on.
- **Request board**: expand a recipe and click **Request** (with an optional note) to ask the guild for it, even when no crafter is online. Guildmates who know the recipe see it under **You can make**, in chat and on the minimap button tooltip; **I'll make it** whispers you and marks it taken for everyone. **Done** takes it down and credits the crafter in guild news. Up to 5 open requests each, closed after 3 days; late logins catch up. `/gf home` and `/gf requests` open the new tabs.
- **Discord bot**: `/requests` lists the request board, and guild news can be posted to a channel (`news_channel_id`).

### Note
- Guildmates on older versions keep syncing as before, but don't see or answer requests until they update.

## [1.1.3] - 2026-11-07

### Changed
- The number on the GF minimap button is now green, like the online dots in the list, instead of red. It counts guildmates online with GuildForge (you included), and the red looked like unread notifications. Hover the button to see who they are.

## [1.1.2] - 2026-11-06

### Added
- **Guild bank materials** with the Guild Bank Toons addon (optional). When it's installed and your guild has a bank toon or shared guild bank tab, reagent lines show how many the guild bank has (`Guild bank: 120`), and:
  - **Get mats from guild bank** on an expanded recipe asks the bank for what your bags are missing, for as many as are on your shopping list (or one). The Shopping List has the same button for every material still needed.
  - **Craft order via guild bank** on a recipe you don't know has the bank mail the missing materials straight to the crafter GuildForge would ask, and whispers them as usual, saying the mats are coming from the guild bank.
  - The buttons are greyed out, with the reason in their tooltip, when the bank has none of what's missing. Chat tells you what was requested and anything the bank couldn't cover.
  - Without Guild Bank Toons, or in a guild without a bank, none of this shows. It appears as soon as a bank is set up, without a reload.

### Fixed
- The GF minimap button sat on a different ring from other addons' buttons, so it looked pushed into the map. It now uses the same spacing and size as other minimap buttons (those made with LibDBIcon), and follows square minimaps too.

## [1.1.1] - 2026-11-05

### Added
- **Discord bot** (`companion/`, not part of the addon download): a crafting leaderboard that stays up to date in one message, plus `/levels`, `/crafts` and `/leaderboard` commands whose answers only the asker sees and that delete themselves. See the README for setup.

### Fixed
- **Ordinary recipes showed up as cooldowns on WoW Forever** ("20 of 20 ready"). Right after you craft, Forever reports a few seconds of cooldown on every recipe, and GuildForge took each one for a profession cooldown and shared it. Only cooldowns of a minute or more count now, those wrong entries are cleared once, and ones still sent by older versions are ignored. A real cooldown that was already ready (like Mooncloth) shows again the next time it's used.

## [1.1.0] - 2026-11-05

### Added
- **Message log window.** Settings → **Message log** (or `/gf log`) shows everything GuildForge sends and receives, live, plus its chat messages, with times. **Copy** puts it, with your version, game client and name at the top, in a box ready to paste into Discord or a GitHub issue. **Clear** starts it fresh. It keeps the last 500 lines.

### Fixed
- **GuildForge flooded guild addon chat on WoW Forever.** Forever's profession window lists every recipe of a profession, learned or not (262 for Enchanting), and GuildForge shared all the unlearned ones as **Not known in guild**, sending them again whenever a guildmate checked in. Unlearned recipes from your own profession window now only show for you; the shared list comes from trainers again, as on Classic, and a guildmate can ask for it at most once every 10 minutes.
- The unlearned recipes already spread by 1.0.9 and earlier are cleared once, and lists sent by those versions are ignored. Visiting trainers fills the shared list again.

### Changed
- **Not known in guild is sorted by profession skill**, lowest first. Trainer recipes use the skill they need ("Req 75"). WoW Forever doesn't tell addons the skill a recipe needs, so recipes from your profession window use the skill where they turn gray ("Gray at 110"), which gives nearly the same order. `/gf scan` shows the gray level of an unlearned recipe so it can be checked.

### Note
- Everyone should update: 1.1.0 and older versions don't exchange the Not known in guild list.

## [1.0.9] - 2026-11-04

### Fixed
- **Some guildmates on WoW Forever still couldn't see each other** and showed as "version unknown" in `/gf who`. When two characters report different realms, the game adds the realm to the other's name on messages and in the guild roster ("First-Surname-CAMWOWUS2Realm2PvE"), so the names didn't match. GuildForge now reads a Forever name as just the first name and surname. Guildmates still on 1.0.7 are understood too.
- On WoW Forever, messages that wait out an instance or combat no longer pile up: they're dropped while blocked, and GuildForge checks in with the guild as soon as you're out, so everything catches up.
- **Recipes weren't shared when opening a profession on WoW Forever.** Forever's profession window opens before its recipe list loads, so GuildForge read an empty list. It now looks again once the recipes have loaded.

### Changed
- `/gf debug` now also shows whether GuildForge is set up to receive guild messages and how many addon messages have arrived, and message text in it displays correctly. It also lists each saved guildmate's professions and recipe counts, and the summary you share.
- `/gf scan` (with a profession window open) shows what GuildForge can read from the window and saves your recipes.

## [1.0.8] - 2026-11-04

### Fixed
- **Sharing still didn't work on WoW Forever.** Forever doesn't use realms, but each character still reports one, and guildmates' can differ. GuildForge put that realm in every name, so a guildmate reporting another realm looked like a different person and their messages were rejected. On Forever, characters are now known by first name and surname only, and data saved by 1.0.7 is moved over automatically.

### Added
- `/gf debug` shows how GuildForge reads your name, the guild roster and saved members, plus the last messages sent and received, and flags anything it rejects.

## [1.0.7] - 2026-11-04

### Fixed
- **Sharing didn't work on WoW Forever.** Forever writes names as "First-Surname", and GuildForge read the surname as a realm, so it cut every name down to the first name and rejected guildmates' messages as coming from the wrong sender. Characters are now known by first name and surname, and the list shows them as "First Surname". `/gf status` shows the name you're sharing as.

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
