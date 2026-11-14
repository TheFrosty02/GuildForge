# GuildForge

**Your guild's professions, all in one place.** GuildForge shares every member's profession skills and known recipes over guild addon chat, so you can see who can craft what, what it takes to make it, and whether you already have the mats — without spamming guild chat.

Built for **WoW Forever**, and also works on **Classic Era**.

![Guild Professions overview](docs/screenshots/overview.webp)

## Features

### Guild Home
The window opens on **Home**, the guild's crafting hub at a glance:

- **Guild news**: who reached a new skill milestone (every 25 points), took up a profession, learned a recipe (flagged when they're the first in the guild), or finished a request. Shift-click a recipe in the news to link it.
- **Online with GuildForge**: who's on right now, with their professions.
- **Requests you can make**, **cooldowns ready**, and your **Request Board** and **Shopping List** at a glance (click either to open it).

Typing in the search box from Home searches the whole guild, like the All tab.

### Request board
Need something crafted when nobody who can make it is online? Expand the recipe and click **Request**, with an optional note ("have mats", "tip 5g"). It goes on the guild's **Request Board** (the note tab at the bottom of the tabs):

- Guildmates who know the recipe see it under **You can make**, get a chat line when it's posted, and see a count on the minimap button.
- **I'll make it** whispers you and marks it as taken for everyone, so two people don't both craft it.
- Once you have it, click **Done**: it comes off every board and the crafter gets the credit in guild news. **Cancel** takes it down without that.
- Up to 5 open requests each; they close on their own after 3 days. Guildmates who log in later catch up on the board.

### Every profession at a glance
The **All** tab lists each profession with how many guildmates have it, how many recipes are shared, and the top crafter. Profession tabs run down the right side of the window, spellbook style, with their icons — professions nobody in the guild has yet are greyed out.

### Crafters, ranked and live
Open a profession to see every guildmate who has it, ranked by skill with a color-coded bar (Apprentice, Journeyman, Expert, Artisan). A green dot means they're online right now; offline crafters show when they were last seen. Click a crafter to show only their recipes.

![Tailoring tab with crafters and recipes](docs/screenshots/profession.webp)

### Recipes with reagents and your mat counts
Every known recipe shows its icon, item-quality color, who can craft it, and whether **you** have the mats in your bags (`Mats ready x17`). Click a recipe to expand it and see each reagent with what you have against what's needed, plus anything sitting in your bank.

- **Ask a crafter** — one click whispers the best online crafter with the item link and the mats you already have.
- **Add to list** — queue it on your shopping list.
- **Shift-click** any recipe or reagent to link it in chat; hover for the full item tooltip.

![Expanded recipe with reagents and actions](docs/screenshots/recipe.png)

### Shopping list
Collect the recipes you plan to make and GuildForge combines them into one list of materials, showing what you've gathered and how many more you need. The same "need 4 more" note appears on item tooltips everywhere — bags, vendors and the auction house.

![Shopping list](docs/screenshots/shopping-list.webp)

### Guild bank materials (with Guild Bank Toons)
If your guild uses the [Guild Bank Toons](https://github.com/kota150/GuildBankToons) addon, GuildForge works with it; without it, none of this shows.

- **Guild bank stock** next to your own counts on every reagent line (`Guild bank: 120`).
- **Get mats from guild bank** on an expanded recipe (and on the Shopping List, for every material still needed) asks the bank for what your bags are missing. A recipe on your shopping list asks for that many crafts.
- **Craft order via guild bank** on a recipe you can't make: the bank mails the missing materials to the crafter, who is told to craft it and mail it to you, and GuildForge whispers them as **Ask a crafter** does.
- Requests wait for a bank officer's approval in Guild Bank Toons. Chat lists what was requested and anything the bank couldn't cover; the buttons are greyed out when the bank has none of it.

### And more
- **Search** recipes, crafters, professions and reagents (try "linen") across the whole guild, plus a **Have mats** filter for things you can craft right now.
- **Item tooltips** show which guildmates craft an item and which recipes use it.
- **Cooldowns** — Mooncloth, transmutes and the Salt Shaker are tracked and shared, so the guild can see who's ready.
- **Not known in guild** — recipes seen at trainers that nobody in the guild has learned yet, with the skill they require. Anyone's trainer visits fill in the list for the whole guild.
- **Minimap button** — a "GF" bubble with a badge counting guildmates online with GuildForge. Left-click to open, right-click to sync, drag to move.
- **Light on guild chat** — syncs send a short fingerprint of each recipe list, and guildmates only download lists that changed.

### Settings
Click the gear next to **Sync** to toggle the minimap button, item tooltips, syncing on login and quiet mode, adjust the window scale, or re-share all of your recipes. If your data ever looks wrong, **Clear my data** forgets everything you've received from guildmates (keeping your own professions) and downloads it fresh.

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
| `/guildforge home` | Open the Home tab |
| `/guildforge requests` | Open the Request Board |
| `/guildforge minimap` | Show or hide the minimap button |
| `/guildforge clear` | Forget received guild data and download it again fresh |
| `/guildforge who` | List guildmates online with GuildForge and their versions |
| `/guildforge status` | Print sync counters |
| `/guildforge log` | Open the live message log (also in Settings), with Copy for bug reports |
| `/guildforge debug` | Print how your name, the roster and recent messages are read |
| `/guildforge scan` | With a profession window open: show what GuildForge can read from it, and save your recipes |

## Discord bot

The bot in [`companion/`](companion/) brings GuildForge to your guild's Discord:

- **A leaderboard that's always there.** One message in a channel of your choice lists the top crafters of every profession with their skill and recipe count. The bot edits that same message whenever the data changes, so it never piles up new posts.
- **`/levels [character]`**: one character's professions with progress bars, or everyone's levels.
- **`/crafts character [profession] [search]`**: what a character can craft, optionally one profession or recipes containing a word. Character and profession names autocomplete.
- **`/leaderboard [profession]`**: the leaderboard, or a full ranking for one profession.
- **`/requests [profession]`**: open requests from GuildForge's request board, with who's on each one.
- **Guild news in a channel** (optional, `news_channel_id`): skill milestones, newly learned recipes and finished requests, posted as they're saved. The first run only marks where to start, so it doesn't post the backlog.

Answers are only visible to the person who asked (or sent to them by DM with `reply_in_dm`), nothing shows in the channel for anyone else, and each answer is deleted after `delete_after` seconds (5 minutes by default, at most 14).

### Who runs it

WoW addons can't reach the internet, so the bot reads the data GuildForge saves on the PC it runs on (`SavedVariables/GuildForge.lua`), which the game writes when you **log out or `/reload`**. So:

- **One person runs it**: usually an officer who plays often. Nobody else needs anything besides GuildForge itself; guildmates just use the commands in Discord.
- It runs on **the same PC that plays WoW** with GuildForge, signed in to a character in the guild. That game collects everyone's professions from guild chat while it's online; the bot picks them up at the next logout or `/reload` and updates the leaderboard within seconds.
- The bot only answers while the script is running. Leave it running while you play, or on a PC that stays on (it still needs WoW and GuildForge on that PC for fresh data).

### Setting it up

1. **Make the bot** at <https://discord.com/developers/applications> → **New Application** (name it GuildForge) → **Bot** → **Reset Token** and copy the token. Keep it secret: anyone with it controls the bot. No privileged intents are needed.
2. **Invite it**: **OAuth2** → **URL Generator** → scopes `bot` and `applications.commands`; bot permissions **View Channels**, **Send Messages**, **Embed Links** and **Read Message History**. Open the generated link and pick your server.
3. **Get the IDs**: in Discord, **User Settings → Advanced → Developer Mode** on, then right-click your server → **Copy Server ID**, and right-click the leaderboard channel → **Copy Channel ID** (and the news channel, if you want one).
4. **Install Python 3.8 or newer** (python.org; on Windows tick *Add python.exe to PATH*), then in the `companion` folder:
   ```
   pip install -r requirements.txt
   ```
5. **Settings**: copy `guildforge_discord.example.json` to `guildforge_discord.json` and fill in `token`, `server_id`, `leaderboard_channel_id`, `news_channel_id` (or leave it empty for no news posts) and `wow_dir` (your World of Warcraft folder, for example `C:/Program Files (x86)/World of Warcraft`). That file is git-ignored.
6. **Check it** without touching Discord; this prints the leaderboard and sample answers from your saved data:
   ```
   python3 guildforge_discord.py --dry-run
   ```
7. **Run it**:
   ```
   python3 guildforge_discord.py
   ```
   It posts the leaderboard and the commands appear in your server right away. Keep the window open; close it to stop the bot.

Other settings: `guild` (if your saved data has more than one guild), `account` (if several WoW accounts play on that PC; by default every account's data is merged, newest first), `top` (crafters per profession on the leaderboard, default 5), `delete_after`, `reply_in_dm`, and `interval` (how often to check for a new save, in seconds). On Windows use `python` instead of `python3`.

## Compatibility

- **WoW Forever** (`GuildForge_Forever.toc`, interface 16001 from the beta) is the main target. GuildForge reads recipes from Forever's profession window, appears in the minimap addon menu and in Esc → Options → AddOns, supports first and last names, and holds guild messages while the game blocks addon chat (for example in combat in instances), sending them afterwards. If Forever launches with a different interface number, update the TOC.
- **Classic Era** (`GuildForge_Vanilla.toc`, interface 11509) runs from the same files.
- Guildmates on older GuildForge versions still sync with newer ones; they just won't see reagent details, cooldowns or the faster summary syncing until they update.

## Releasing

Pushing a version tag builds `GuildForge.zip` with the [BigWigs packager](https://github.com/BigWigsMods/packager) and publishes it (see `.github/workflows/release.yml`):

```
git tag v1.0.0
git push origin v1.0.0
```

The tag becomes the addon's version, and the matching `CHANGELOG.md` section becomes the release notes. The ZIP is always attached to a GitHub release; it's also uploaded to CurseForge once the repository has a `CF_API_KEY` secret and the TOC files have `## X-Curse-Project-ID`. `CURSEFORGE.md` holds the project page description.

## Testing

`tests/run_tests.py` runs GuildForge in a stand-in WoW environment with WoW's Lua version. It checks that the addon loads and opens, that two players sync (including realms with punctuation and late logins), that trainer rank upgrades aren't saved, and the Guild Bank Toons integration against a stub of its API (hidden without a bank, stock shown, missing amounts requested, craft orders sent to the crafter):

```
python3 -m venv .venv && .venv/bin/pip install lupa
.venv/bin/python tests/run_tests.py
```

## Credits

Created by TheFrosty02, with UI and feature work by kota150.
