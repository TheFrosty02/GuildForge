#!/usr/bin/env python3
"""GuildForge Discord bot.

Reads GuildForge's SavedVariables (GuildForge.lua, written when you log out or /reload) and runs a Discord
bot for the guild:

  * A leaderboard message in one channel: the top crafters of every profession, edited in place whenever
    the saved data changes, so it is always there and always current.
  * /levels [character]          profession levels: one character, or the whole guild
  * /crafts character [profession] [search]   what a character can craft
  * /leaderboard [profession]    the leaderboard, or one profession's full ranking

Command answers are only visible to the person who asked (or sent by DM, see reply_in_dm) and are
deleted after delete_after seconds. Nothing is posted in the channel for anyone else.

Every guildmate running GuildForge keeps a copy of the guild's data, so anyone can run this. It only
sees what *this* PC's game saved, so the data refreshes when that game logs out or /reloads.

Python 3.8+ and discord.py (pip install -r requirements.txt).

    python3 guildforge_discord.py --dry-run     # print the leaderboard and sample answers, no Discord
    python3 guildforge_discord.py               # run the bot

Settings come from guildforge_discord.json next to this script (see guildforge_discord.example.json). The
bot token can also come from the GUILDFORGE_BOT_TOKEN environment variable.
"""

import argparse
import asyncio
import datetime
import glob
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "guildforge_discord.json")
STATE_PATH = os.path.join(HERE, ".guildforge_discord_state.json")
DEFAULT_WOW_DIRS = [
    "/Applications/World of Warcraft",
    "C:/Program Files (x86)/World of Warcraft",
    "C:/Program Files/World of Warcraft",
]
FLAVORS = ["_forever_", "_classic_era_"]
# Leaderboard order; any other profession in the data goes after these.
PROFESSIONS = ["Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Leatherworking", "Tailoring",
               "Cooking", "First Aid", "Fishing", "Herbalism", "Mining", "Skinning"]
# Discord limits: 4096 characters per embed description, 1024 per field, 6000 per message.
DESCRIPTION_LIMIT = 3900
FIELD_LIMIT = 1000
MEDALS = ["🥇", "🥈", "🥉"]


# --- SavedVariables (Lua) parser (same as the Guild Bank Toons companion) -------------------------

class LuaParser:
    """Parses the subset of Lua that WoW writes to SavedVariables: `Name = value` assignments of
    tables, strings, numbers, booleans and nil."""

    def __init__(self, text):
        self.s = text
        self.i = 0

    def error(self, msg):
        line = self.s.count("\n", 0, self.i) + 1
        raise ValueError(f"SavedVariables parse error on line {line}: {msg}")

    def skip(self):
        s, n = self.s, len(self.s)
        while self.i < n:
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("--", self.i):
                end = s.find("\n", self.i)
                self.i = n if end < 0 else end + 1
            else:
                break

    def peek(self):
        self.skip()
        return self.s[self.i] if self.i < len(self.s) else ""

    def expect(self, ch):
        if self.peek() != ch:
            self.error(f"expected {ch!r}")
        self.i += 1

    def name(self):
        self.skip()
        start = self.i
        while self.i < len(self.s) and (self.s[self.i].isalnum() or self.s[self.i] == "_"):
            self.i += 1
        if start == self.i:
            self.error("expected a name")
        return self.s[start:self.i]

    def string(self):
        quote = self.s[self.i]
        self.i += 1
        out = []
        escapes = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}
        while True:
            if self.i >= len(self.s):
                self.error("unterminated string")
            c = self.s[self.i]
            if c == quote:
                self.i += 1
                return "".join(out)
            if c == "\\":
                nxt = self.s[self.i + 1]
                if nxt.isdigit():
                    j = self.i + 1
                    while j < self.i + 4 and j < len(self.s) and self.s[j].isdigit():
                        j += 1
                    out.append(chr(int(self.s[self.i + 1:j])))
                    self.i = j
                    continue
                out.append(escapes.get(nxt, nxt))
                self.i += 2
                continue
            out.append(c)
            self.i += 1

    def number(self):
        start = self.i
        if self.s[self.i] == "-":
            self.i += 1
        while self.i < len(self.s) and (self.s[self.i].isalnum() or self.s[self.i] in ".+-"):
            if self.s[self.i] in "+-" and self.s[self.i - 1] not in "eE":
                break
            self.i += 1
        raw = self.s[start:self.i]
        try:
            return int(raw, 0)
        except ValueError:
            return float(raw)

    def value(self):
        c = self.peek()
        if c == "{":
            return self.table()
        if c in "\"'":
            return self.string()
        if c.isdigit() or c in "-.":
            return self.number()
        word = self.name()
        if word == "true":
            return True
        if word == "false":
            return False
        if word == "nil":
            return None
        self.error(f"unexpected {word!r}")

    def table(self):
        self.expect("{")
        result, index = {}, 1
        while self.peek() != "}":
            if self.peek() == "[":
                self.i += 1
                k = self.value()
                self.expect("]")
                self.expect("=")
                result[k] = self.value()
            else:
                save = self.i
                c = self.peek()
                if c.isalpha() or c == "_":
                    word = self.name()
                    if self.peek() == "=":
                        self.i += 1
                        result[word] = self.value()
                    else:
                        self.i = save
                        result[index] = self.value()
                        index += 1
                else:
                    result[index] = self.value()
                    index += 1
            if self.peek() in ",;":
                self.i += 1
        self.expect("}")
        return result

    def document(self):
        out = {}
        while self.peek():
            name = self.name()
            self.expect("=")
            out[name] = self.value()
        return out


def load_saved_variables(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return LuaParser(f.read()).document()


def load_saved_variables(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return LuaParser(f.read()).document()


def find_saved_variables(wow_dir, account=None):
    dirs = [wow_dir] if wow_dir else DEFAULT_WOW_DIRS
    found = []
    for base in dirs:
        for flavor in FLAVORS:
            pattern = os.path.join(base, flavor, "WTF", "Account", account or "*", "SavedVariables", "GuildForge.lua")
            found.extend(glob.glob(pattern))
    return sorted(found, key=os.path.getmtime, reverse=True)


# --- Reading GuildForge's data --------------------------------------------------------------------

def seq(table):
    """A Lua array (parsed as {1: a, 2: b}) as a Python list."""
    if isinstance(table, list):
        return table
    if not isinstance(table, dict):
        return []
    return [table[i] for i in sorted(k for k in table if isinstance(k, int))]


def short(name):
    """Display name: "Bob-Faerlina" (Classic) -> "Bob"; Forever names ("Kota Arkbinky") have no realm."""
    return (name or "?").split("-")[0]


def name_id(name):
    """Same identity the addon uses: the name without any -Realm, ignoring case and spaces."""
    return short(name).replace(" ", "").lower()


def guild_label(bucket):
    """"Hidden Leaf - Living Flame" (Classic) -> "Hidden Leaf"; Forever buckets are just the guild name."""
    return bucket.split(" - ")[0]


def merge_members(files):
    """{guild bucket: {member key: record}} across every SavedVariables file, newest record winning."""
    guilds = {}
    for path in files:
        db = load_saved_variables(path).get("GuildForgeDB") or {}
        for bucket, guild in (db.get("guilds") or {}).items():
            if not isinstance(guild, dict) or bucket.startswith("No guild"):
                continue
            members = guilds.setdefault(bucket, {})
            for who, record in (guild.get("members") or {}).items():
                if not isinstance(record, dict):
                    continue
                old = members.get(who)
                if old is None or (record.get("updated") or 0) > (old.get("updated") or 0):
                    members[who] = record
    return guilds


def pick_guild(guilds, wanted=""):
    """The guild named in the settings, else the one with the most members."""
    if wanted:
        for bucket in guilds:
            if guild_label(bucket).lower() == wanted.lower() or bucket.lower() == wanted.lower():
                return bucket
        return None
    if not guilds:
        return None
    return max(guilds, key=lambda b: len(guilds[b]))


class GuildData:
    """One guild's members, as the bot shows them."""

    def __init__(self, bucket, members, saved_at):
        self.name = guild_label(bucket)
        self.saved_at = saved_at
        self.members = []
        for who, record in members.items():
            professions = []
            for p in seq(record.get("professions")):
                if isinstance(p, dict) and p.get("name"):
                    professions.append({"name": p["name"], "rank": int(p.get("rank") or 0), "max": int(p.get("max") or 0)})
            recipes = {prof: sorted(str(r) for r in seq(names))
                       for prof, names in (record.get("recipes") or {}).items() if seq(names)}
            self.members.append({"name": short(who), "id": name_id(who), "professions": professions,
                                 "recipes": recipes, "updated": record.get("updated") or 0})
        self.members.sort(key=lambda m: m["name"].lower())

    def professions(self):
        seen = {p["name"] for m in self.members for p in m["professions"]}
        return [p for p in PROFESSIONS if p in seen] + sorted(seen - set(PROFESSIONS))

    def ranking(self, profession):
        rows = []
        for m in self.members:
            for p in m["professions"]:
                if p["name"] == profession:
                    rows.append((m, p))
        rows.sort(key=lambda row: (-row[1]["rank"], row[0]["name"].lower()))
        return rows

    def find(self, name):
        """A member by name: exact (ignoring case and spaces) first, then the only one starting with it."""
        wanted = name_id(name)
        for m in self.members:
            if m["id"] == wanted:
                return m
        matches = [m for m in self.members if m["id"].startswith(wanted)]
        return matches[0] if len(matches) == 1 else None

    def find_profession(self, name):
        for p in self.professions():
            if p.lower() == (name or "").strip().lower():
                return p
        return None


class DataError(Exception):
    """The saved data couldn't be found or doesn't have the guild."""


def load_guild(settings):
    files = find_saved_variables(settings.get("wow_dir"), settings.get("account") or None)
    if not files:
        raise DataError("No GuildForge.lua SavedVariables found. Set wow_dir (and account) in guildforge_discord.json.")
    guilds = merge_members(files)
    bucket = pick_guild(guilds, settings.get("guild") or "")
    if bucket is None:
        names = ", ".join(sorted({guild_label(b) for b in guilds})) or "none"
        raise DataError(f"Guild not found in the saved data. Guilds found: {names}")
    return GuildData(bucket, guilds[bucket], max(os.path.getmtime(f) for f in files))


# --- Messages ---------------------------------------------------------------------------------------
# Each builder returns a plain dict (title, description, fields, footer) so --dry-run can print it and the
# bot can turn it into a Discord embed.

def fit(lines, limit, more="…and {n} more"):
    """Join lines without passing limit characters, ending with how many were left out."""
    out, used = [], 0
    for i, line in enumerate(lines):
        if used + len(line) + 1 > limit - 20:
            out.append(more.format(n=len(lines) - i))
            break
        out.append(line)
        used += len(line) + 1
    return "\n".join(out)


def skill(p):
    return f"{p['rank']}/{p['max']}" if p["max"] else str(p["rank"])


def progress_bar(rank, maximum, width=10):
    filled = round(width * rank / maximum) if maximum else 0
    return "▰" * filled + "▱" * (width - filled)


def recipe_note(member, profession):
    count = len(member["recipes"].get(profession, []))
    return f" · {count} recipe{'s' if count != 1 else ''}" if count else ""


def build_leaderboard(guild, top=5, profession=None):
    sharing = sum(1 for m in guild.members if m["professions"])
    fields = []
    for prof in ([profession] if profession else guild.professions()):
        rows = guild.ranking(prof)
        if not rows:
            continue
        lines = []
        for i, (m, p) in enumerate(rows if profession else rows[:top]):
            place = MEDALS[i] if i < 3 else f"`{i + 1}.`"
            lines.append(f"{place} **{m['name']}** {skill(p)}{recipe_note(m, prof)}")
        if not profession and len(rows) > top:
            lines.append(f"*+{len(rows) - top} more*")
        fields.append((f"{prof} ({len(rows)})", fit(lines, FIELD_LIMIT), not profession))
    if not fields:
        fields.append(("No professions yet", "Nobody has shared professions with this PC's game yet.", False))
    return {
        "title": f"⚒️ {guild.name} crafting leaderboard" + (f": {profession}" if profession else ""),
        "description": f"{sharing} guildmates sharing professions · data saved <t:{int(guild.saved_at)}:R>",
        "fields": fields,
        "footer": "Ask the bot: /levels, /crafts, /leaderboard. Only you see the answer.",
    }


def build_levels(guild, character=None):
    if character:
        m = guild.find(character)
        if m is None:
            return not_found(guild, character)
        lines = [f"**{p['name']}** {skill(p)}  {progress_bar(p['rank'], p['max'])}{recipe_note(m, p['name'])}"
                 for p in m["professions"]] or ["No professions shared yet."]
        return {"title": f"{m['name']}'s professions", "description": "\n".join(lines), "fields": [],
                "footer": updated_note(m)}
    lines = []
    for m in guild.members:
        if m["professions"]:
            lines.append(f"**{m['name']}**: " + ", ".join(f"{p['name']} {skill(p)}" for p in m["professions"]))
    return {"title": f"{guild.name} profession levels", "description": fit(lines, DESCRIPTION_LIMIT) or "Nobody yet.",
            "fields": [], "footer": "Use /levels <character> for one character in detail."}


def build_crafts(guild, character, profession=None, search=None):
    m = guild.find(character)
    if m is None:
        return not_found(guild, character)
    term = (search or "").strip().lower()
    fields, total = [], 0
    for prof in sorted(m["recipes"]):
        if profession and prof.lower() != profession.lower():
            continue
        names = [r for r in m["recipes"][prof] if term in r.lower()]
        if not names:
            continue
        total += len(names)
        fields.append((f"{prof} ({len(names)})", fit([f"• {r}" for r in names], FIELD_LIMIT), False))
    if not fields:
        what = f" matching \"{search}\"" if term else ""
        where = f" in {profession}" if profession else ""
        text = (f"No recipes{what}{where} shared for {m['name']} yet. Recipes are shared when they open "
                "the profession window with GuildForge loaded.")
        return {"title": f"What {m['name']} can craft", "description": text, "fields": [], "footer": updated_note(m)}
    return {"title": f"What {m['name']} can craft", "description": f"{total} recipe{'s' if total != 1 else ''}", "fields": fields[:25],
            "footer": updated_note(m)}


def not_found(guild, character):
    close = [m["name"] for m in guild.members if name_id(character)[:3] in m["id"]][:8]
    hint = f" Did you mean: {', '.join(close)}?" if close else ""
    return {"title": "Character not found", "description": f"Nobody called \"{character}\" in {guild.name}'s data.{hint}",
            "fields": [], "footer": ""}


def updated_note(member):
    if not member["updated"]:
        return ""
    day = datetime.datetime.fromtimestamp(member["updated"]).strftime("%Y-%m-%d %H:%M")
    return f"Last shared {day}"


def as_text(msg):
    """A message as plain text, for --dry-run."""
    out = [f"== {msg['title']} ==", msg["description"]]
    for name, value, _ in msg["fields"]:
        out += ["", f"[{name}]", value]
    if msg["footer"]:
        out += ["", f"({msg['footer']})"]
    return "\n".join(out)


# --- The bot ----------------------------------------------------------------------------------------

def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def save_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def run_bot(settings):
    import discord
    from discord import app_commands

    token = os.environ.get("GUILDFORGE_BOT_TOKEN") or settings.get("token")
    if not token:
        raise SystemExit("Set token in guildforge_discord.json or the GUILDFORGE_BOT_TOKEN environment variable.")
    server_id = int(settings["server_id"]) if settings.get("server_id") else None
    channel_id = int(settings["leaderboard_channel_id"]) if settings.get("leaderboard_channel_id") else None
    top = int(settings.get("top") or 5)
    # Interaction answers can only be edited or deleted for 15 minutes.
    delete_after = max(0, min(int(settings.get("delete_after", 300)), 840))
    reply_in_dm = bool(settings.get("reply_in_dm"))
    interval = max(5, int(settings.get("interval") or 15))

    client = discord.Client(intents=discord.Intents.default())
    tree = app_commands.CommandTree(client)
    state = load_json(STATE_PATH, {})
    current = {"guild": load_guild(settings), "stamp": None}

    def embed(msg):
        e = discord.Embed(title=msg["title"], description=msg["description"], colour=0xD8AA55)
        for name, value, inline in msg["fields"]:
            e.add_field(name=name, value=value or "-", inline=inline)
        if msg["footer"]:
            e.set_footer(text=msg["footer"])
        return e

    async def answer(interaction, msg):
        """Only the asker sees the answer (or gets it by DM), and it's deleted once delete_after passes."""
        if reply_in_dm:
            try:
                sent = await interaction.user.send(embed=embed(msg))
                await interaction.response.send_message("Sent you a DM.", ephemeral=True)
                if delete_after:
                    await asyncio.sleep(delete_after)
                    await sent.delete()
                    await interaction.delete_original_response()
                return
            except discord.Forbidden:
                pass  # DMs closed: answer here instead, still only visible to them.
        await interaction.response.send_message(embed=embed(msg), ephemeral=True)
        if delete_after:
            await asyncio.sleep(delete_after)
            try:
                await interaction.delete_original_response()
            except discord.HTTPException:
                pass

    async def character_names(interaction, typed):
        typed = name_id(typed)
        names = [m["name"] for m in current["guild"].members if typed in m["id"]]
        return [app_commands.Choice(name=n, value=n) for n in names[:25]]

    async def profession_names(interaction, typed):
        return [app_commands.Choice(name=p, value=p) for p in current["guild"].professions()
                if typed.lower() in p.lower()][:25]

    @tree.command(name="levels", description="Profession levels for one character, or the whole guild")
    @app_commands.describe(character="Character name (leave empty for everyone)")
    @app_commands.autocomplete(character=character_names)
    async def levels(interaction, character: str = None):
        await answer(interaction, build_levels(current["guild"], character))

    @tree.command(name="crafts", description="What a character can craft")
    @app_commands.describe(character="Character name", profession="Only this profession", search="Only recipes containing this")
    @app_commands.autocomplete(character=character_names, profession=profession_names)
    async def crafts(interaction, character: str, profession: str = None, search: str = None):
        await answer(interaction, build_crafts(current["guild"], character, profession, search))

    @tree.command(name="leaderboard", description="The crafting leaderboard, or one profession's full ranking")
    @app_commands.describe(profession="One profession, all crafters")
    @app_commands.autocomplete(profession=profession_names)
    async def leaderboard(interaction, profession: str = None):
        prof = current["guild"].find_profession(profession) if profession else None
        if profession and not prof:
            await answer(interaction, {"title": "Profession not found", "description": f"Nobody shares {profession}.",
                                       "fields": [], "footer": ""})
            return
        await answer(interaction, build_leaderboard(current["guild"], top, prof))

    async def refresh_leaderboard():
        """Edit the leaderboard message in place; post a new one if it's missing."""
        if not channel_id:
            return
        msg = build_leaderboard(current["guild"], top)
        digest = hashlib.sha1(json.dumps(msg, sort_keys=True).encode()).hexdigest()
        if digest == state.get("leaderboard_digest") and state.get("leaderboard_message") and current["stamp"]:
            return
        channel = client.get_channel(channel_id) or await client.fetch_channel(channel_id)
        message = None
        if state.get("leaderboard_message") and state.get("leaderboard_channel") == channel_id:
            try:
                message = await channel.fetch_message(int(state["leaderboard_message"]))
            except discord.NotFound:
                message = None
        if message:
            await message.edit(content=None, embed=embed(msg))
        else:
            message = await channel.send(embed=embed(msg))
        state.update(leaderboard_message=str(message.id), leaderboard_channel=channel_id, leaderboard_digest=digest)
        save_json(STATE_PATH, state)

    async def watch():
        """Reload whenever the game saves (logout or /reload) and update the leaderboard."""
        while not client.is_closed():
            try:
                files = find_saved_variables(settings.get("wow_dir"), settings.get("account") or None)
                stamp = max((os.path.getmtime(f) for f in files), default=None)
                if stamp != current["stamp"]:
                    if current["stamp"] is not None:
                        current["guild"] = load_guild(settings)
                    await refresh_leaderboard()
                    current["stamp"] = stamp
            except Exception as e:  # keep the bot running; the next save tries again
                print(f"GuildForge bot: update failed: {e}", file=sys.stderr)
            await asyncio.sleep(interval)

    @client.event
    async def on_ready():
        if server_id:
            server = discord.Object(id=server_id)
            tree.copy_global_to(guild=server)
            await tree.sync(guild=server)
        else:
            await tree.sync()
        print(f"GuildForge bot online as {client.user} for {current['guild'].name}.")
        if not getattr(client, "watching", False):
            client.watching = True
            client.loop.create_task(watch())

    client.run(token)


def main():
    parser = argparse.ArgumentParser(description="GuildForge Discord bot")
    parser.add_argument("--dry-run", action="store_true", help="print the leaderboard and sample answers, no Discord")
    parser.add_argument("--config", default=CONFIG_PATH, help="settings file (default: guildforge_discord.json)")
    parser.add_argument("--wow-dir", help="World of Warcraft folder")
    parser.add_argument("--saved-variables", help="read this GuildForge.lua instead of searching wow_dir")
    parser.add_argument("--guild", help="guild name, when the saved data has more than one")
    args = parser.parse_args()
    settings = load_json(args.config, {})
    if args.wow_dir:
        settings["wow_dir"] = args.wow_dir
    if args.guild:
        settings["guild"] = args.guild
    if args.saved_variables:
        global find_saved_variables
        path = args.saved_variables
        find_saved_variables = lambda *_: [path]  # noqa: E731
    if args.dry_run:
        guild = load_guild(settings)
        print(as_text(build_leaderboard(guild, int(settings.get("top") or 5))))
        print()
        print(as_text(build_levels(guild)))
        sample = next((m for m in guild.members if m["recipes"]), None)
        if sample:
            print()
            print(as_text(build_crafts(guild, sample["name"])))
        return
    run_bot(settings)


def entry():
    try:
        main()
    except DataError as e:
        raise SystemExit(f"GuildForge bot: {e}")


if __name__ == "__main__":
    entry()
