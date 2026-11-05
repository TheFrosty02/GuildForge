"""Smoke tests for GuildForge in a stand-in WoW environment (tests/mockwow.lua).

Runs the addon with WoW's Lua version (5.1, through lupa) to catch what a syntax check can't:
the 200-local limit, errors at load or login, and sync between two players over a simulated
guild channel. Not part of the addon download (.pkgmeta ignores tests/).

    python3 -m venv .venv && .venv/bin/pip install lupa
    .venv/bin/python tests/run_tests.py            # or pass another GuildForge.lua to test it
"""
import os
import sys

import lupa.lua51 as lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON_PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..', 'GuildForge.lua')
ADDON = open(ADDON_PATH, encoding='utf-8').read()
MOCK = open(os.path.join(HERE, 'mockwow.lua'), encoding='utf-8').read()
failures = []


def check(name, ok, detail=''):
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else '  ' + detail))
    if not ok:
        failures.append(name)


class Player:
    """One WoW client running GuildForge."""

    def __init__(self, name, skill, recipes, realm='Living Flame', restricted=None, folder='GuildForge', setup='',
                 surname=None, source=None):
        self.name, self.realm = name, realm
        # Forever puts "First-Surname" on messages, with no realm.
        self.header = name + '-' + surname if surname else None
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        g = self.lua.globals()
        g.PLAYER, g.REALM, g.ADDON_FOLDER = name, realm, folder
        if surname:
            g.SURNAME, g.INTERFACE = surname, 16001
        g.SKILL = self.lua.table(*skill)
        g.TS_RECIPES = self.lua.table(*recipes)
        if restricted is not None:
            g.CHAT_RESTRICTED = restricted
        self.lua.execute(MOCK)
        if setup:
            self.lua.execute(setup)
        loader = self.lua.eval('function(src,folder) local c,e=loadstring(src,"@GuildForge.lua"); if not c then error(e,0) end; GF_NS={}; c(folder,GF_NS) end')
        loader(source or ADDON, folder)

    def fire(self, *args):
        self.lua.globals().GF_TEST_fire(*args)

    def step(self, dt=0.3):
        g = self.lua.globals()
        g.GF_TEST_timers()
        g.GF_TEST_tick(dt)

    def view(self, who):
        info = self.lua.globals().GF_TEST_members()[who]
        return None if info is None else (info.profNames, info.recipeProfs, info.cooldowns)

    def swap_profession(self, skill, recipes):
        g = self.lua.globals()
        g.SKILL = self.lua.table(*skill)
        g.TS_RECIPES = self.lua.table(*recipes)
        g.TS_COOLDOWNS = self.lua.table()
        self.fire('SKILL_LINES_CHANGED')

    def members(self):
        table = self.lua.globals().GF_TEST_members()
        return {k: (v.profs, v.recipes) for k, v in table.items()}


def deliver(players):
    """Guild channel: every message reaches every player, sender included, with a packed realm."""
    moved = 0
    for sender in players:
        outbox = sender.lua.globals().GF_TEST_outbox()
        for i in range(1, len(outbox) + 1):
            prefix, msg = outbox[i][1], outbox[i][2]
            packed_realm = ''.join(ch for ch in sender.realm if ch.isalnum())
            for player in players:
                header = sender.header or sender.name + '-' + packed_realm
                # Forever adds the sender's realm when it differs from the receiver's.
                if sender.header and player.realm != sender.realm:
                    header += '-' + packed_realm
                player.fire('CHAT_MSG_ADDON', prefix, msg, 'GUILD', header)
            moved += 1
    return moved


def run(players, steps=400):
    sent = 0
    for _ in range(steps):
        for p in players:
            p.step()
        sent += deliver(players)
    return sent


def test_load(folder):
    try:
        p = Player('Arcbinky', ['First Aid', 9, 75], ['Linen Bandage'], folder=folder)
        p.fire('PLAYER_LOGIN')
        run([p], steps=20)
        p.fire('GUILD_ROSTER_UPDATE')
        g = p.lua.globals()
        g.SlashCmdList.GUILDFORGE('')
        g.SlashCmdList.GUILDFORGE('settings')
        run([p], steps=5)
        check('loads, logs in and opens (folder %s)' % folder, g.GuildForgeWindow is not None and g.GuildForgeMinimapButton is not None)
    except Exception as e:  # noqa: BLE001 - report any Lua error as a failure
        check('loads, logs in and opens (folder %s)' % folder, False, str(e).splitlines()[0])


def two_players(realm='Living Flame', restricted=None, late=False):
    a = Player('Arcbinky', ['First Aid', 9, 75], ['Linen Bandage'], realm, restricted)
    a.fire('PLAYER_LOGIN')
    a.fire('TRADE_SKILL_SHOW')
    if late:
        run([a], steps=200)
    b = Player('Fortbek', ['Tailoring', 24, 75], ['Bolt of Linen Cloth', 'Brown Linen Shirt'], realm, restricted)
    b.fire('PLAYER_LOGIN')
    if not late:
        b.fire('TRADE_SKILL_SHOW')
    sent = run([a, b])
    return a.members(), b.members(), sent


def test_sync(label, **kw):
    seen_by_a, seen_by_b, sent = two_players(**kw)
    b_recipes = 0 if kw.get('late') else 2
    ok = seen_by_b.get('Arcbinky') == (1, 1) and seen_by_a.get('Fortbek') == (1, b_recipes)
    check('sync: ' + label, ok, 'A sees %s, B sees %s, %d messages' % (seen_by_a, seen_by_b, sent))


TRAINER_SETUP = r'''
  GuildForgeDB={recipeInfo={Cooking={['Expert Cook']={reagents={},remote=true,source='Trainer',req=125}}}}
  SERVICES={
    {'Apprentice Cook','','available',0}, {'Journeyman Cook','','unavailable',50},
    {'Cooking','Expert','unavailable',125}, {'Spider Sausage','','unavailable',200},
    {'Herb Baked Egg','','used',1},
  }
  function GetNumTrainerServices() return #SERVICES end
  function GetTrainerServiceInfo(i) local s=SERVICES[i]; return s[1],s[2],s[3] end
  function GetTrainerServiceSkillLine() return 'Cooking' end
  function GetTrainerServiceSkillReq(i) return 'Cooking',SERVICES[i][4],true end
  function GetTrainerServiceNumReagents() return 0 end
  function GetTrainerServiceIcon() return 1 end
  function GetTrainerServiceItemLink() return nil end
'''


def test_trainer():
    p = Player('Arcbinky', ['Cooking', 60, 75], [], setup=TRAINER_SETUP)
    p.fire('PLAYER_LOGIN')
    run([p], steps=20)
    header = 'Fortbek-LivingFlame'
    for prefix, msg in [
        ('GFORGE', 'B|Fortbek-Living Flame'), ('GFORGE', 'P|Fortbek-Living Flame|Cooking:60:75'), ('GFORGE', 'E|Fortbek-Living Flame'),
        ('GFORGE_R', 'B|Fortbek-Living Flame|Cooking|1'), ('GFORGE_R', 'I|Fortbek-Living Flame|Cooking|Herb Baked Egg'),
        ('GFORGE_R', 'E|Fortbek-Living Flame|Cooking'), ('GFORGE_R', 'T|Fortbek-Living Flame|Cooking|Artisan Cook~200~'),
    ]:
        p.fire('CHAT_MSG_ADDON', prefix, msg, 'GUILD', header)
    p.fire('TRAINER_SHOW')
    run([p], steps=5)
    saved = p.lua.eval('''function()
      local out={} for name in pairs(GuildForgeDB.recipeInfo.Cooking) do out[#out+1]=name end
      table.sort(out) return table.concat(out,', ') end''')()
    check('trainer: rank upgrades are not saved or accepted', saved == 'Herb Baked Egg, Spider Sausage', 'saved: ' + saved)
    # Draw the Cooking tab with a search, which opens every section, so the Not known rows render.
    try:
        rows = p.lua.eval('''function()
          SlashCmdList.GUILDFORGE('')
          for _,f in ipairs(frames) do
            if f.__kind=='CheckButton' and rawget(f,'name')=='Cooking' then f.__scripts.OnClick(f) end
          end
          for _,f in ipairs(frames) do
            if f.__kind=='EditBox' then f:SetText('sausage'); f.__scripts.OnTextChanged(f) end
          end
          local names={}
          for _,f in ipairs(frames) do
            local label=rawget(f,'name')
            if f.__kind=='Button' and f.__shown and type(label)=='table' and tostring(rawget(label,'__text')):find('Spider Sausage',1,true) then names[#names+1]=label.__text end
          end
          return #names end''')()
        check('trainer: Not known in guild draws as a plain list', rows == 1, '%d Spider Sausage rows' % rows)
    except Exception as e:  # noqa: BLE001
        check('trainer: Not known in guild draws as a plain list', False, str(e).splitlines()[0])


def test_profession_swap(offline):
    label = 'profession swap while the guildmate is ' + ('offline' if offline else 'online')
    a = Player('Arcbinky', ['First Aid', 9, 75], ['Linen Bandage'])
    b = Player('Fortbek', ['Tailoring', 250, 300], ['Bolt of Linen Cloth', 'Mooncloth'],
               setup="TS_COOLDOWNS={Mooncloth=7200}")
    for p in (a, b):
        p.fire('PLAYER_LOGIN')
        p.fire('TRADE_SKILL_SHOW')
    run([a, b])
    before = a.view('Fortbek')
    b.swap_profession(['Leatherworking', 1, 75], ['Light Armor Kit'])
    b.fire('TRADE_SKILL_SHOW')
    if offline:
        run([b], steps=200)                    # Arcbinky misses all of it
        stale = a.view('Fortbek')
        a.lua.globals().SlashCmdList.GUILDFORGE('sync')   # Arcbinky comes back and syncs
    run([a, b])
    after = a.view('Fortbek')
    expected = ('Leatherworking', 'Leatherworking', '')
    ok = before == ('Tailoring', 'Tailoring', 'Mooncloth') and after == expected and (not offline or stale == before)
    check(label, ok, 'before %s, after %s' % (before, after))


BIG_RECIPES = ['%s of the %s %s' % (a, b, c)
               for a in ['Pattern', 'Formula', 'Plans', 'Schematic', 'Recipe']
               for b in ['Ancient', 'Burning', 'Frozen', 'Shadow', 'Radiant', 'Gilded']
               for c in ['Ward', 'Edge', 'Veil', 'Crown', 'Mantle']]


def throttled(players):
    return sum(int(p.lua.globals().THROTTLED or 0) for p in players)


def test_big_profession():
    a = Player('Arcbinky', ['Tailoring', 300, 300], BIG_RECIPES)
    b = Player('Fortbek', ['First Aid', 9, 75], ['Linen Bandage'])
    for p in (a, b):
        p.fire('PLAYER_LOGIN')
        p.fire('TRADE_SKILL_SHOW')
    seconds = None
    for step in range(2000):
        for p in (a, b):
            p.step()
        deliver([a, b])
        names = b.lua.globals().GF_TEST_members()['Arcbinky']
        details = b.lua.eval('function() local n=0 for _,i in pairs(GuildForgeDB.recipeInfo.Tailoring or {}) do if i.remote then n=n+1 end end return n end')()
        if names and names.recipes == len(BIG_RECIPES) and details == len(BIG_RECIPES):
            seconds = (step + 1) * 0.3
            break
    sent = int(a.lua.globals().SENT_COUNT or 0)
    ok = seconds is not None and throttled([a, b]) == 0 and sent < 80
    check('150-recipe profession arrives with names and details, nothing refused', ok,
          'took %s s, %d messages sent, %d refused' % (seconds, sent, throttled([a, b])))
    print('     150 recipes: %d messages, %.0f seconds' % (sent, seconds or -1))


def test_forever_surnames():
    roster = "ROSTER={{'Kota-Fields',true},{'Bob-Smith',true}}"
    # Forever doesn't use realms, but each client still reports one, and guildmates' can differ.
    # Kota also starts with data saved by 1.0.7, which kept the realm in guild and member names.
    saved = roster + r'''
      GuildForgeDB={guilds={['Hidden Leaf - CAMWOW US2 Realm 1 PvE']={members={
        ['Kota Fields-CAMWOW US2 Realm 1 PvE']={professions={},updated=1,recipes={}},
        ['Bob Smith-CAMWOW US2 Realm 1 PvE']={professions={},updated=1,recipes={}}}}}}'''
    a = Player('Kota', ['First Aid', 9, 75], ['Linen Bandage'], 'CAMWOW US2 Realm 1 PvE', setup=saved, surname='Fields')
    b = Player('Bob', ['Tailoring', 24, 75], ['Bolt of Linen Cloth', 'Brown Linen Shirt'], 'CAMWOW US2 Realm 2 PvE',
               setup=roster, surname='Smith')
    for p in (a, b):
        p.fire('PLAYER_LOGIN')
        p.fire('TRADE_SKILL_SHOW')
    run([a, b])
    for p in (a, b):
        p.fire('GUILD_ROSTER_UPDATE')
    run([a, b], steps=5)
    seen_by_a = list(a.lua.globals().GF_TEST_names().values())
    ok = seen_by_a == ['Bob Smith', 'Kota Fields'] and b.members().get('Kota Fields') == (1, 1) \
        and a.members().get('Bob Smith') == (1, 2)
    guilds = sorted(a.lua.globals().GuildForgeDB.guilds.keys())
    ok = ok and guilds == ['Hidden Leaf']
    check('Forever: surnames kept, realms ignored, 1.0.7 data moved', ok,
          'A has %s / %s, B has %s, guilds %s' % (seen_by_a, a.members(), b.members(), guilds))


def test_forever_mixed_realms():
    # Each roster lists the others with their realm when it differs from the viewer's own.
    def roster(me):
        entries = []
        for name, realm in people:
            packed = '' if realm == me else '-' + ''.join(ch for ch in realm if ch.isalnum())
            entries.append("{'%s%s',true}" % (name, packed))
        return 'ROSTER={' + ','.join(entries) + '}'
    people = [('Kota-Arkbinky', 'CAMWOW US2 Realm 1 PvE'), ('Bob-Smith', 'CAMWOW US2 Realm 2 PvE'),
              ('Amara-Ironbraid', 'CAMWOW US2 Realm 2 PvE')]
    old = open(os.path.join(HERE, 'fixtures', 'GuildForge-1.0.7.lua'), encoding='utf-8').read()
    a = Player('Kota', ['First Aid', 9, 75], ['Linen Bandage'], people[0][1], setup=roster(people[0][1]), surname='Arkbinky')
    b = Player('Bob', ['Tailoring', 24, 75], ['Bolt of Linen Cloth', 'Brown Linen Shirt'], people[1][1],
               setup=roster(people[1][1]), surname='Smith')
    c = Player('Amara', ['Cooking', 30, 75], ['Spiced Wolf Meat'], people[2][1], setup=roster(people[2][1]),
               surname='Ironbraid', source=old)
    for p in (a, b, c):
        p.fire('PLAYER_LOGIN')
        p.fire('TRADE_SKILL_SHOW')
    run([a, b, c])
    for p in (a, b, c):
        p.fire('GUILD_ROSTER_UPDATE')
    run([a, b, c], steps=5)
    seen_a, seen_b = a.members(), b.members()
    ok = seen_a.get('Bob Smith') == (1, 2) and seen_b.get('Kota Arkbinky') == (1, 1) \
        and seen_a.get('Amara Ironbraid') == (1, 1) and seen_b.get('Amara Ironbraid') == (1, 1)
    check('Forever: realm-tagged senders and roster, and a guildmate still on 1.0.7', ok,
          'Kota sees %s, Bob sees %s' % (seen_a, seen_b))


def test_forever_restricted():
    # Forever answers "restricted" with true almost everywhere while messages still arrive, so that alone
    # must not stop sharing. Inside an instance it does: messages wait, then everything syncs on leaving.
    roster = "ROSTER={{'Kota Arkbinky',true},{'Bob Smith',true}}"
    realm = 'CAMWOW US2 Realm 1 PvE'
    a = Player('Kota', ['First Aid', 9, 75], ['Linen Bandage'], realm, restricted=True, setup=roster, surname='Arkbinky')
    b = Player('Bob', ['Tailoring', 24, 75], ['Bolt of Linen Cloth', 'Brown Linen Shirt'], realm, restricted=True,
               setup=roster, surname='Smith')
    for p in (a, b):
        p.fire('PLAYER_LOGIN')
        p.fire('TRADE_SKILL_SHOW')
    run([a, b])
    open_world = b.members().get('Kota Arkbinky') == (1, 1) and a.members().get('Bob Smith') == (1, 2)
    check('Forever: "restricted" outside instances does not stop sharing', open_world,
          'Bob sees %s; Kota sees %s' % (b.members(), a.members()))

    c = Player('Amara', ['Cooking', 30, 75], ['Spiced Wolf Meat'], realm, restricted=True,
               setup="IN_INSTANCE=true ROSTER={{'Amara Ironbraid',true},{'Bob Smith',true}}", surname='Ironbraid')
    c.fire('PLAYER_LOGIN')
    c.fire('TRADE_SKILL_SHOW')
    run([b, c])
    sent_inside = c.lua.eval('SENT_COUNT or 0')
    c.lua.globals().IN_INSTANCE = False
    run([b, c])
    check('Forever: held in an instance, full sync after leaving',
          sent_inside == 0 and b.members().get('Amara Ironbraid') == (1, 1),
          'sent inside=%d; Bob sees %s' % (sent_inside, b.members()))


MODERN_PROFESSIONS = r'''
  -- Forever's profession window: no GetTradeSkillInfo; C_TradeSkillUI lists recipes only once loaded.
  GetTradeSkillInfo=nil; GetNumTradeSkills=nil; GetTradeSkillLine=nil
  LOADED=false
  local names={[101]='Enchant Bracer - Minor Health',[102]='Runed Copper Rod',[103]='Enchant Chest - Minor Mana',
    [104]='Enchant Bracer - Minor Stamina',[105]='Enchant Cloak - Minor Agility',[106]='Lesser Magic Wand'}
  GRAY={[103]=60,[104]=130,[105]=110}
  C_TradeSkillUI={
    GetBaseProfessionInfo=function() return {professionName='Enchanting'} end,
    IsTradeSkillLinked=function() return false end, IsTradeSkillGuild=function() return false end,
    GetAllRecipeIDs=function() if not LOADED then return {} end return {101,102,103,104,105,106} end,
    GetRecipeInfo=function(id) return {name=names[id],learned=id<103,icon=1,maxTrivialLevel=GRAY[id]} end,
    GetRecipeSchematic=function(id) return {outputItemID=id==102 and 6218 or nil,reagentSlotSchematics={}} end,
  }
'''


def test_forever_profession_window():
    roster = "ROSTER={{'Kota Arkbinky',true},{'Krystal Clear',true}}"
    realm = 'CAMWOW US2 Realm 1 PvE'
    a = Player('Kota', ['Enchanting', 5, 75], [], realm, setup=roster + MODERN_PROFESSIONS, surname='Arkbinky')
    b = Player('Krystal', ['Tailoring', 10, 75], ['Bolt of Linen Cloth'], realm, setup=roster, surname='Clear')
    for p in (a, b):
        p.fire('PLAYER_LOGIN')
    run([a, b], steps=40)
    a.fire('TRADE_SKILL_SHOW')
    for _ in range(3):  # the first scan, 0.3 s in, sees an empty list
        a.step()
    a.lua.globals().LOADED = True
    run([a, b])
    check('Forever: recipes that load after the profession window opens are still shared',
          b.members().get('Kota Arkbinky') == (1, 2), 'Krystal sees %s' % b.members())

    # The unlearned recipe shows in Kota's own Not known list but isn't shared, so check-ins send no catalog,
    # and a catalog sent by 1.0.9 or earlier (U) is ignored.
    def catalog(p):
        info = p.lua.globals().GuildForgeDB.recipeInfo.Enchanting
        return [] if info is None else sorted(k for k, v in info.items() if v.source)
    b.fire('CHAT_MSG_ADDON', 'GFORGE_R', 'U|Kota Arkbinky|Enchanting|Totem of Thunderous Strikes~~i234478', 'GUILD', 'Kota Arkbinky')
    sent = 0
    for _ in range(3):
        b.lua.globals().SlashCmdList.GUILDFORGE('sync')
        a.lua.globals().SlashCmdList.GUILDFORGE('sync')
        for _ in range(100):
            for p in (a, b):
                p.step()
            for p in (a, b):
                sent += sum(1 for m in p.lua.globals().OUT.values() if m[2][:2] in ('W|', 'U|'))
            deliver([a, b])
    unlearned = ['Enchant Bracer - Minor Stamina', 'Enchant Chest - Minor Mana', 'Enchant Cloak - Minor Agility',
                 'Lesser Magic Wand']
    ok = catalog(a) == unlearned and catalog(b) == [] and sent == 0
    check('Forever: unlearned recipes stay local, no catalog spam on check-ins', ok,
          'Kota has %s, Krystal has %s, catalog messages %d' % (catalog(a), catalog(b), sent))


def test_unknown_sorted_by_skill():
    # Trainer recipes sort by the skill they need, Forever's window recipes by where they turn gray, unknown last.
    setup = r'''GuildForgeDB={recipeInfo={Enchanting={
      ['Enchant Boots - Minor Speed']={reagents={},remote=true,source='Trainer',req=225},
      ['Enchant Bracer - Minor Health']={reagents={},remote=true,source='Trainer',req=1},
      ['Enchant Chest - Minor Mana']={reagents={},remote=true,source='Not learned',gray=60},
      ['Lesser Magic Wand']={reagents={},remote=true,source='Not learned'},
      ['Enchant Cloak - Minor Agility']={reagents={},remote=true,source='Not learned',gray=110}}}}'''
    a = Player('Arcbinky', ['First Aid', 9, 75], ['Linen Bandage'], setup=setup)
    a.fire('PLAYER_LOGIN')
    d = a.lua.globals().GF_TEST_unknown('Enchanting')
    order = [d[i] for i in range(1, len(d) + 1)]
    expected = ['Enchant Bracer - Minor Health', 'Enchant Chest - Minor Mana', 'Enchant Cloak - Minor Agility',
                'Enchant Boots - Minor Speed', 'Lesser Magic Wand']
    check('Not known in guild is sorted by profession skill', order == expected, str(order))


def test_message_log():
    roster = "ROSTER={{'Kota Arkbinky',true},{'Bob Smith',true}}"
    realm = 'CAMWOW US2 Realm 1 PvE'
    a = Player('Kota', ['First Aid', 9, 75], ['Linen Bandage'], realm, setup=roster, surname='Arkbinky')
    b = Player('Bob', ['Tailoring', 24, 75], ['Bolt of Linen Cloth'], realm, setup=roster, surname='Smith')
    for p in (a, b):
        p.fire('PLAYER_LOGIN')
        p.fire('TRADE_SKILL_SHOW')
    g = a.lua.globals()
    g.SlashCmdList.GUILDFORGE('log')
    run([a, b], steps=60)
    window = g.GuildForgeLogWindow
    window.__scripts.OnUpdate(window, 1)
    live = a.lua.eval('GF_NS.logWindow.text') or ''
    report = a.lua.eval('GF_NS.logText(GF_NS.logReport())')
    ok = (window.__shown and 'got from Bob-Smith: S¦Bob Smith¦' in live and 'sent V¦Kota Arkbinky¦' in live
          and '|' not in live and report.startswith('GuildForge v') and 'you: Kota Arkbinky' in report)
    check('message log window shows live messages and a copyable report', ok, live[:300])


def test_forever_catalog_cleared():
    # 1.0.9 and earlier spread Forever's unlearned recipes as trainer recipes; 1.0.10 clears them once.
    saved = r'''GuildForgeDB={recipeInfo={Enchanting={['Totem of Thunderous Strikes']={reagents={},remote=true,source='Trainer'}},
      Cooking={['Spiced Wolf Meat']={reagents={}}}}}'''
    a = Player('Kota', ['Cooking', 20, 75], ['Spiced Wolf Meat'], 'CAMWOW US2 Realm 1 PvE', setup=saved, surname='Arkbinky')
    a.fire('PLAYER_LOGIN')
    info = a.lua.globals().GuildForgeDB.recipeInfo
    check('Forever: catalog spread by 1.0.9 is cleared once, own recipe details kept',
          info.Enchanting['Totem of Thunderous Strikes'] is None and info.Cooking['Spiced Wolf Meat'] is not None)


def test_big_guild():
    names = ['Member%02d' % i for i in range(12)]
    roster = 'ROSTER={' + ','.join("{'%s',true}" % n for n in names) + '}'
    profs = ['Alchemy', 'Blacksmithing', 'Enchanting', 'Engineering', 'Leatherworking', 'Tailoring']
    players = []
    for i, n in enumerate(names[:-1]):
        p = Player(n, [profs[i % len(profs)], 100, 150], ['Recipe %d-%d' % (i, k) for k in range(20)], setup=roster)
        p.fire('PLAYER_LOGIN')
        p.fire('TRADE_SKILL_SHOW')
        players.append(p)
    run(players, steps=300)
    late = Player(names[-1], ['Cooking', 50, 75], ['Spiced Wolf Meat'], setup=roster)
    late.fire('PLAYER_LOGIN')
    players.append(late)
    run(players, steps=600)
    seen = late.members()
    complete = all(seen.get(n) == (1, 20) for n in names[:-1])
    check('12-player guild: a late login downloads everyone, nothing refused', complete and throttled(players) == 0,
          'complete=%s, refused=%d' % (complete, throttled(players)))


if __name__ == '__main__':
    test_load('GuildForge')
    test_load('GuildCraft')
    test_sync('normal realm')
    test_sync("realm with an apostrophe (Nek'Rosh)", realm="Nek'Rosh")
    test_sync('Classic answers the chat-lockdown check with 0', restricted=0)
    test_sync('second player logs in later', realm="Nek'Rosh", late=True)
    test_trainer()
    test_profession_swap(offline=False)
    test_profession_swap(offline=True)
    test_big_profession()
    test_big_guild()
    test_forever_surnames()
    test_forever_mixed_realms()
    test_forever_restricted()
    test_forever_profession_window()
    test_forever_catalog_cleared()
    test_unknown_sorted_by_skill()
    test_message_log()
    print('\n%d failed' % len(failures) if failures else '\nall passed')
    sys.exit(1 if failures else 0)
