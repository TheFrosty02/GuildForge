# GuildForge

**Your guild's professions, all in one place.** GuildForge shares every member's profession skills and known recipes over guild addon chat, so you can see who can craft what, what it takes to make it, and whether you already have the mats — without spamming guild chat.

Built for **WoW Forever**, and also works on **Classic Era**.

![Guild Professions overview](docs/screenshots/overview.webp)

## Features

### Every profession at a glance
The **All** tab lists each profession with how many guildmates have it, how many recipes are shared, and the top crafter. Profession tabs run down the right side of the window, spellbook style, with their icons — professions nobody in the guild has yet are greyed out.

### Crafters, ranked and live
Open a profession to see every guildmate who has it, ranked by skill with a color-coded bar (Apprentice, Journeyman, Expert, Artisan). A green dot means they're online right now; offline crafters show when they were last seen. Click a crafter to show only their recipes.

![Tailoring tab with crafters and recipes](docs/screenshots/profession.webp)

### Recipes with reagents and your mat counts
Every known recipe shows its icon, item-quality color, who can craft it, and whether **you** have the mats in your bags (`Mats ready x17`, `Missing mats`). Expand a recipe to see each reagent with what you have against what's needed, plus anything sitting in your bank.

- **Ask a crafter** — one click whispers the best online crafter with the item link and the mats you already have.
- **Add to list** — queue it on your shopping list.
- **Shift-click** any recipe or reagent to link it in chat; hover for the full item tooltip.

![Expanded recipe with reagents and actions](docs/screenshots/recipe.png)

### Shopping list
Collect the recipes you plan to make and GuildForge combines them into one list of materials, showing what you've gathered and how many more you need. The same "need 4 more" note appears on item tooltips everywhere — bags, vendors and the auction house.

![Shopping list](docs/screenshots/shopping-list.webp)

### And more
- **Search** recipes, crafters, professions and reagents (try "linen") across the whole guild, plus a **Have mats** filter for things you can craft right now.
- **Item tooltips** show which guildmates craft an item and which recipes use it.
- **Cooldowns** — Mooncloth, transmutes and the Salt Shaker are tracked and shared, so the guild can see who's ready.
- **Not known in guild** — recipes seen at trainers that nobody in the guild has learned yet, with the skill they require. Anyone's trainer visits fill in the list for the whole guild.
- **Minimap button** — a "GF" bubble with a badge counting guildmates online with GuildForge. Left-click to open, right-click to sync, drag to move.
- **Light on guild chat** — syncs send a short fingerprint of each recipe list, and guildmates only download lists that changed.

### Settings
Click the gear next to **Sync Guild** to toggle the minimap button, item tooltips, syncing on login and quiet mode, adjust the window scale, or re-share all of your recipes. If your data ever looks wrong, **Clear my data** forgets everything you've received from guildmates (keeping your own professions) and downloads it fresh.

![Settings panel](docs/screenshots/settings.png)

## Installation

1. Install from CurseForge, or download this repository and put the `GuildForge` folder in your AddOns folder:
   - WoW Forever: `World of Warcraft/_forever_/Interface/AddOns/GuildForge`
   - Classic Era: `World of Warcraft/_classic_era_/Interface/AddOns/GuildForge`
2. Make sure the folder contains `GuildForge.toc` and `GuildForge.lua`.
3. Restart the game (or `/reload`) and enable GuildForge on the character select AddOns screen.

## Getting started

1. Open each of your professions once (for example your First Aid or Leatherworking window). GuildForge scans the recipes you know and shares them with the guild.
2. Visit profession trainers to fill in the **Not known in guild** lists.
3. Click the **GF** minimap button or type `/guildforge` to open the window.

Your guildmates need GuildForge too — the more people running it, the more complete the guild's list gets.

## Slash commands

| Command | What it does |
| --- | --- |
| `/guildforge` | Open or close the window (also `/gf`, `/gforge`, `/guildprof`, and the old `/guildcraft`) |
| `/guildforge sync` | Ask the guild for any changed professions and recipes |
| `/guildforge push` | Re-share all of your recipes in full |
| `/guildforge refresh` | Rescan your own professions |
| `/guildforge settings` | Open the settings panel |
| `/guildforge minimap` | Show or hide the minimap button |
| `/guildforge clear` | Forget received guild data and download it again fresh |
| `/guildforge who` | List guildmates online with GuildForge and their versions |
| `/guildforge status` | Print sync counters |

## Compatibility

- **WoW Forever** (`GuildForge_Forever.toc`, interface 16001 from the beta) is the main target. GuildForge reads recipes from Forever's profession window, appears in the minimap addon menu and in Esc → Options → AddOns, supports first and last names, and holds guild messages while the game blocks addon chat (for example in combat in instances), sending them afterwards. If Forever launches with a different interface number, update the TOC.
- **Classic Era** (`GuildForge_Vanilla.toc`, interface 11509) runs from the same files.
- Guildmates on older GuildForge versions still sync with newer ones; they just won't see reagent details, cooldowns or the faster summary syncing until they update.

## Releasing

Pushing a version tag builds `GuildForge.zip` with the [BigWigs packager](https://github.com/BigWigsMods/packager) and publishes it (see `.github/workflows/release.yml`):

```
git tag v0.14.0
git push origin v0.14.0
```

The tag becomes the addon's version, and the matching `CHANGELOG.md` section becomes the release notes. The ZIP is always attached to a GitHub release; it's also uploaded to CurseForge once the repository has a `CF_API_KEY` secret and the TOC files have `## X-Curse-Project-ID`. `CURSEFORGE.md` holds the project page description.

## Credits

Created by TheFrosty02, with UI and feature work by kota150.
