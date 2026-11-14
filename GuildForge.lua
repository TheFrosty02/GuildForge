-- GuildForge - Classic Era + WoW: Forever; WoW-styled window, profession tabs, recipe reagents,
-- craft requests, shopping list, item tooltips, cooldowns, learnable recipes, summary-based syncing, settings
-- The release packager writes the git tag into the TOC; an unpackaged checkout still shows the placeholder.
-- Look the addon up by the folder WoW loaded it from: the modern lookup errors on an unknown name,
-- and an error here would stop the whole file (commands and minimap button included).
local addonName=...
local GetMetadata=(C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local VERSION
if GetMetadata and type(addonName)=='string' then
  local ok,value=pcall(GetMetadata,addonName,'Version')
  if ok then VERSION=value end
end
if type(VERSION)~='string' or VERSION:find('@',1,true) then VERSION='dev' end
VERSION=VERSION:gsub('^v','')
-- Helper functions live in one table: WoW's Lua allows at most 200 locals at the top of a file. It's the
-- addon's private table, which WoW passes in second (and the tests use to look inside).
local GF=select(2,...)
if type(GF)~='table' then GF={} end
-- Hidden guild addon-message channels: professions and roll calls, and recipe data.
local PREFIX='GFORGE'
local RECIPE_PREFIX='GFORGE_R'
local frame=CreateFrame('Frame')
local window, status, searchBox, scrollFrame, scrollContent
local headerIcon, headerTitle, headerSub, matsCheck
local minimapButton
local tabs={}
local selectedTab='All'
local selectedCrafter={}
local sectionCollapsed, recipeOpen = {}, {}
local recipeQueue, recipePending = {}, {}
local recipeSent, recipeReceived = 0, 0
local droppedMessages = 0
local addonVersions = {} -- nameId -> GuildForge version heard this session
local cdStampSeen = {} -- who -> last cooldown stamp we pulled for
local updatePending, sinceUpdate, sinceRoster = false, 0, 0
local activeSeen, guildOnline, guildLastSeen, guildMembers = {}, {}, {}, {}
local rosterHasOffline = false
-- Member data is stored per guild. Until the guild name loads, messages land here and merge in later.
local tempMembers, currentGuild = {}, nil
local fullQueuedAt, pullRequestedAt = {}, {}
local recipeIndex, indexDirty = nil, true
local professions={"Alchemy","Blacksmithing","Enchanting","Engineering","Leatherworking","Tailoring","Cooking","First Aid","Fishing","Herbalism","Mining","Skinning"}
local professionIcons={
  Alchemy='Interface\\Icons\\Trade_Alchemy',
  Blacksmithing='Interface\\Icons\\Trade_BlackSmithing',
  Enchanting='Interface\\Icons\\Trade_Engraving',
  Engineering='Interface\\Icons\\Trade_Engineering',
  Leatherworking='Interface\\Icons\\Trade_LeatherWorking',
  Tailoring='Interface\\Icons\\Trade_Tailoring',
  Cooking='Interface\\Icons\\INV_Misc_Food_15',
  ['First Aid']='Interface\\Icons\\Spell_Holy_SealOfSacrifice',
  Fishing='Interface\\Icons\\Trade_Fishing',
  Herbalism='Interface\\Icons\\Spell_Nature_NatureTouchGrow',
  Mining='Interface\\Icons\\Trade_Mining',
  Skinning='Interface\\Icons\\INV_Misc_Pelt_Wolf_01',
  All='Interface\\Icons\\INV_Misc_Book_09',
  Shopping='Interface\\Icons\\INV_Misc_Bag_08',
  Home='Interface\\Icons\\INV_Shirt_GuildTabard_01',
  Requests='Interface\\Icons\\INV_Misc_Note_01',
}
local specialTabs={All='All Professions',Shopping='Shopping List',Home='Guild Home',Requests='Request Board'}
-- WoW: Forever runs on the modern (Midnight-era) API where many Classic globals moved into C_ namespaces.
-- Resolve each once so the same file runs on Classic Era and Forever.
local GetItemInfo=GetItemInfo or (C_Item and C_Item.GetItemInfo)
local GetItemIcon=GetItemIcon or (C_Item and C_Item.GetItemIconByID)
local GetItemInfoInstant=GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
local GetItemCount=GetItemCount or (C_Item and C_Item.GetItemCount)
local GetSpellTexture=GetSpellTexture or (C_Spell and C_Spell.GetSpellTexture)
local GetSpellLink=GetSpellLink or (C_Spell and C_Spell.GetSpellLink)
local InsertChatLink=(ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
local SendChat=(C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
-- Midnight "secret values" can't be indexed or compared; treat them as unknown instead of erroring.
local function isSecret(value) return type(issecretvalue)=='function' and issecretvalue(value) end
function GF.spellName(id)
  if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
  return GetSpellInfo and (GetSpellInfo(id))
end
function GF.spellCooldown(id)
  if C_Spell and C_Spell.GetSpellCooldown then
    local cd=C_Spell.GetSpellCooldown(id)
    if type(cd)=='table' then return cd.startTime,cd.duration end
    return cd
  end
  if GetSpellCooldown then return GetSpellCooldown(id) end
end
function GF.itemCooldown(id)
  local fn=(C_Container and C_Container.GetItemCooldown) or GetItemCooldown
  if fn then return fn(id) end
end
function GF.knowsSpell(id)
  if IsPlayerSpell then return IsPlayerSpell(id) end
  return IsSpellKnown and IsSpellKnown(id)
end
local QUESTION_ICON='Interface\\Icons\\INV_Misc_QuestionMark'
-- A white circle (the portrait mask) so vertex colors show true; tinting a dark texture stays dark.
local DOT_TEXTURE='Interface\\CharacterFrame\\TempPortraitAlphaMask'
local BACKDROP_TEMPLATE=BackdropTemplateMixin and 'BackdropTemplate' or nil
local CONTENT_W=646
local update, refreshMinimap, selectTab
local clearMyData, handleSummary, handleAsk
local function releaseSearchFocus()
  if searchBox and searchBox:HasFocus() then searchBox:ClearFocus() end
end
-- requestUpdate: guild data changed (rebuild tooltip index too); requestRedraw: only bags/time changed.
local function requestUpdate() updatePending=true; indexDirty=true end
local function requestRedraw() updatePending=true end
local scanRecipes, queueRecipes
local db, recipeInfo, lastBroadcast= nil, nil, 0
local received, sent=0,0
local function settings() return GuildForgeDB and GuildForgeDB.settings or {} end
-- Routine messages respect quiet mode; pass always=true for replies to something the player did.
local function log(s,always)
  -- Everything also goes to the message log window, quiet mode or not, without chat colors.
  if GF.note then GF.note((tostring(s):gsub('|c%x%x%x%x%x%x%x%x',''):gsub('|r',''))) end
  if not always and settings().quiet then return end
  print('|cffd8aa55GuildForge:|r '..tostring(s))
end
local function realm() return (GetRealmName and GetRealmName()) or 'Unknown' end
local cachedPlayer
-- WoW: Forever adds surnames, and UnitName may not match the name other players see on our messages.
-- GF.learnOwnName() records the name the server puts on our own messages, keyed by UnitName.
-- Forever (interface 16xxx) has one realm per ruleset, and the part after a '-' in a name is a surname, not a realm.
GF.forever=(function() local iface=GetBuildInfo and select(4,GetBuildInfo()); return type(iface)=='number' and iface>=16000 and iface<17000 end)()
local function playerName()
  if cachedPlayer then return cachedPlayer end
  local name,surname=UnitName('player')
  if name and not isSecret(name) then
    local learned=GuildForgeDB and GuildForgeDB.knownAs and GuildForgeDB.knownAs[name..'-'..realm()]
    -- On Forever, UnitName's second value is the surname.
    if GF.forever and type(surname)=='string' and not isSecret(surname) and surname~='' then name=name..' '..surname end
    cachedPlayer=learned or name
  end
  return cachedPlayer
end
-- Forever doesn't use realms: a character is its name alone, whatever realm the client reports.
local function key()
  if GF.forever then return playerName() or 'Unknown' end
  return (playerName() or 'Unknown')..'-'..realm()
end
local function now() return (time and time()) or 0 end
-- APIs format realms differently ("Living Flame" vs "LivingFlame", or none for your own realm),
-- so compare characters by a normalized name-realm id instead of the bare name.
-- Message headers drop spaces and punctuation from realm names ("Nek'Rosh" -> "NekRosh"), so compare letters and digits only.
local function normalizeRealm(server) return (server or ''):gsub('[^%w]',''):lower() end
local function splitName(name)
  if type(name)~='string' or isSecret(name) then return nil end
  -- Strip a suffix naming our own realm first, so hyphens in surnames or realm names don't split wrongly.
  local own=normalizeRealm(realm())
  local start=1
  while true do
    local dash=name:find('-',start,true)
    if not dash then break end
    if normalizeRealm(name:sub(dash+1))==own then name=name:sub(1,dash-1); break end
    start=dash+1
  end
  -- Forever: a name is "First" plus an optional surname ("First Surname" or "First-Surname"). The game
  -- can add the realm of a character reporting a different one ("First-Surname-CAMWOWUS2Realm2PvE");
  -- names never contain digits and these realms do, so stop at the first part with a digit.
  if GF.forever then
    local parts={}
    for part in name:gmatch('[^%s%-]+') do
      if part:find('%d') or #parts==2 then break end
      parts[#parts+1]=part
    end
    if #parts==0 then return nil end
    return table.concat(parts,' '),realm()
  end
  local character,server=name:match('^([^-]+)%-(.+)$')
  if not character then return name,realm() end
  return character,server
end
local function nameId(name)
  local character,server=splitName(name)
  if not character then return nil end
  if GF.forever then return (character:gsub('%s',''):lower()) end
  return character:gsub('%s',''):lower()..'-'..normalizeRealm(server)
end
-- "Bob" for your own realm, "Bob-Faerlina" for anyone from another realm; "Bob Smith" on Forever.
local function displayName(name)
  local character,server=splitName(name)
  if not character then return name end
  if normalizeRealm(server)==normalizeRealm(realm()) then return character end
  return character..'-'..server:gsub('%s','')
end
-- Our own guild addon messages echo back with the sender name the server uses for us.
function GF.learnOwnName(sender)
  local character=splitName(sender)
  local base=UnitName('player')
  if not character or character==cachedPlayer or not base or isSecret(base) then return end
  local oldKey=key()
  cachedPlayer=character
  local newKey=key()
  if GuildForgeDB then
    GuildForgeDB.knownAs=GuildForgeDB.knownAs or {}
    GuildForgeDB.knownAs[base..'-'..realm()]=character
  end
  if db and db[oldKey] then
    if not db[newKey] then db[newKey]=db[oldKey] end
    db[oldKey]=nil
  end
end
-- True when the addon-message sender is the character named in the payload, or the client hides the sender.
local function senderMatches(sender,who)
  if isSecret(sender) then return true end
  local id=nameId(sender)
  return id~=nil and id==nameId(who)
end
local function scan()
  local list,seen={},{}
  local valid={Alchemy=true,Blacksmithing=true,Enchanting=true,Engineering=true,Herbalism=true,Leatherworking=true,Mining=true,Skinning=true,Tailoring=true,Cooking=true,Fishing=true,['First Aid']=true}
  if GetNumSkillLines and GetSkillLineInfo then
    for i=1,GetNumSkillLines() do
      local name,header,_,rank,_,_,maximum=GetSkillLineInfo(i)
      if not header and valid[name] and not seen[name] then
        seen[name]=true; list[#list+1]={name=name,rank=tonumber(rank) or 0,max=tonumber(maximum) or 0}
      end
    end
  end
  if GetProfessions and GetProfessionInfo then
    local slots={GetProfessions()}
    for _,slot in ipairs(slots) do
      if slot then
        local name,_,rank,maximum=GetProfessionInfo(slot)
        if name and valid[name] and not seen[name] then
          seen[name]=true; list[#list+1]={name=name,rank=tonumber(rank) or 0,max=tonumber(maximum) or 0}
        end
      end
    end
  end
  table.sort(list,function(a,b) return a.name<b.name end)
  return list
end
function GF.initDB()
  GuildForgeDB=GuildForgeDB or {}
  GuildForgeDB.guilds=GuildForgeDB.guilds or {}
  -- Recipe details (crafted item + reagents) are shared by name, independent of who knows them.
  GuildForgeDB.recipeInfo=GuildForgeDB.recipeInfo or {}
  GuildForgeDB.minimap=GuildForgeDB.minimap or {angle=200,hide=false}
  GuildForgeDB.ui=GuildForgeDB.ui or {tab='All',matsOnly=false}
  GuildForgeDB.shopping=GuildForgeDB.shopping or {}
  GuildForgeDB.settings=GuildForgeDB.settings or {}
  local s=GuildForgeDB.settings
  if s.scale==nil then s.scale=1 end
  if s.syncOnLogin==nil then s.syncOnLogin=true end
  if s.quiet==nil then s.quiet=false end
  if s.tooltips==nil then s.tooltips=true end
  db=tempMembers
  recipeInfo=GuildForgeDB.recipeInfo
  -- 1.0.9 and earlier shared Forever's whole profession window (every unlearned recipe) as "Not known in
  -- guild". Clear what was received once; trainer visits fill the list again.
  if GF.forever and not GuildForgeDB.catalogV2 then
    for _,list in pairs(recipeInfo) do
      for name,info in pairs(list) do
        if type(info)=='table' and info.remote and info.source=='Trainer' then list[name]=nil end
      end
    end
  end
  GuildForgeDB.catalogV2=true
  -- 1.1.0 and earlier tracked every recipe as a cooldown on Forever (see GF.noteRecipeCooldown). Clear the
  -- ready ones once; real cooldowns come back the next time they're used.
  if GF.forever and not GuildForgeDB.cooldownsV2 then
    for _,guild in pairs(GuildForgeDB.guilds) do
      for _,record in pairs(guild.members or {}) do
        for name,cd in pairs(type(record)=='table' and record.cooldowns or {}) do
          if type(cd)=='table' and (cd.readyAt or 0)<=((time and time()) or 0) then record.cooldowns[name]=nil end
        end
      end
    end
  end
  GuildForgeDB.cooldownsV2=true
  -- 1.2.0 added the Home tab; open there once, then remember whatever tab was last used.
  if not GuildForgeDB.homeV1 then GuildForgeDB.ui.tab='Home'; GuildForgeDB.homeV1=true end
  selectedTab=professionIcons[GuildForgeDB.ui.tab or ''] and GuildForgeDB.ui.tab or 'Home'
end
-- A record keeps recipes and cooldowns only for professions it still has (after someone drops one).
-- Returns whether any recipes, and whether any cooldowns, were removed.
function GF.dropRemovedProfessions(record)
  local has={}
  for _,p in ipairs(record.professions or {}) do has[p.name]=true end
  local recipesDropped,cooldownsDropped=false,false
  for prof in pairs(record.recipes or {}) do
    if not has[prof] then record.recipes[prof]=nil; recipesDropped=true end
  end
  for prof in pairs(record.recipeUpdated or {}) do
    if not has[prof] then record.recipeUpdated[prof]=nil end
  end
  for name,cd in pairs(record.cooldowns or {}) do
    if type(cd)=='table' and cd.prof and not has[cd.prof] then record.cooldowns[name]=nil; cooldownsDropped=true end
  end
  return recipesDropped,cooldownsDropped
end
local function save()
  if not db then GF.initDB() end
  if not playerName() or db==tempMembers then return end
  local name=key()
  local previous=db[name] or {}
  local professions=scan()
  db[name]={professions=professions,updated=now(),localPlayer=true,recipes=previous.recipes or {},recipeUpdated=previous.recipeUpdated or {},cooldowns=previous.cooldowns or {},cdStamp=previous.cdStamp}
  -- Right after login the skill list can briefly be empty; only prune once the game has reported skills.
  local loaded=#professions>0 or (GetNumSkillLines and GetNumSkillLines()>0)
  if #professions>0 then GF.skillNews(name,previous.professions,professions) end
  if loaded then
    local _,cooldownsDropped=GF.dropRemovedProfessions(db[name])
    if cooldownsDropped then db[name].cdStamp=now() end
  end
end
-- WoW: Forever (Midnight-era API) blocks outgoing addon messages in some situations, such as combat in
-- instances. Messages wait until the lockdown lifts instead of failing and being dropped.
function GF.messagingBlocked()
  local C=C_ChatInfo
  if not C then return false end
  -- Blizzard only restricts addon chat in instances and combat. Outside those, send anyway: Classic Era
  -- answered these checks with a non-boolean, and Forever answers "restricted" with true nearly all the
  -- time while messages still arrive, so a check outside those must never freeze sharing.
  local inInstance=IsInInstance and IsInInstance()
  local inCombat=InCombatLockdown and InCombatLockdown()
  if not inInstance and not inCombat then return false end
  for _,name in ipairs({'AreOutgoingAddonChatMessagesRestricted','InChatMessagingLockdown'}) do
    local check=C[name]
    if check then
      local blocked=check()
      if blocked==true then return true end
    end
  end
  return false
end
-- Outgoing messages wait in one queue per channel and leave at Blizzard's pace (see GF.drainChannel),
-- so the game never has to refuse one. This queue is the professions channel; recipeQueue is the other.
GF.profQueue={}
local function addonSend(payload)
  if not (IsInGuild and IsInGuild()) then return false end
  GF.profQueue[#GF.profQueue+1]=payload
  return true
end
local function announce(force)
  if not (IsInGuild and IsInGuild()) then return end
  local t=now()
  -- Skill-ups can fire in bursts: wait out the 15 seconds, then send, instead of skipping the change.
  if not force and t-lastBroadcast<15 then GF.announceDue=lastBroadcast+15; return end
  GF.announceDue=nil
  save()
  local rec=db[key()]
  if not rec then return end
  local entries={}
  for _,p in ipairs(rec.professions) do
    entries[#entries+1]=p.name..':'..p.rank..':'..p.max
  end
  -- Classic addon messages are small; split into one record per profession. B carries the count so
  -- receivers can throw away a set that lost a message instead of thinking a profession was dropped.
  addonSend('B|'..key()..'|'..#entries)
  for _,entry in ipairs(entries) do addonSend('P|'..key()..'|'..entry) end
  addonSend('E|'..key())
  lastBroadcast=t
end
local pending={}
function GF.parseMessage(message,sender)
  if type(message)~='string' then return end
  local action,who,extra=message:match('^([^|]+)|([^|]+)|?(.*)$')
  if not action or not who or who==key() then return end
  if not senderMatches(sender,who) then return end
  if action=='S' then handleSummary(who,extra); return end
  if action=='A' then handleAsk(extra); return end
  if action=='Q' or action=='Z' or action=='X' or action=='Y' then GF.receiveRequest(action,who,extra); return end
  if action=='B' then pending[who]={professions={},updated=now(),expected=tonumber(extra)}; return end
  if action=='P' then
    local record=pending[who]
    if not record then return end
    local name,rank,maximum=extra:match('^([^:]+):(%d+):(%d+)$')
    if name and #record.professions<16 then
      record.professions[#record.professions+1]={name=name,rank=tonumber(rank),max=tonumber(maximum)}
    end
  elseif action=='E' then
    local record=pending[who]
    pending[who]=nil
    if record and (not record.expected or #record.professions==record.expected) then
      record.expected=nil
      table.sort(record.professions,function(a,b) return a.name<b.name end)
      local old=db[who] or {}
      record.recipes=old.recipes or {}
      record.recipeUpdated=old.recipeUpdated or {}
      record.cooldowns=old.cooldowns or {}
      -- Forget recipes and cooldowns for professions they no longer have.
      GF.dropRemovedProfessions(record)
      GF.skillNews(who,old.professions,record.professions)
      db[who]=record
      received=received+1
      requestUpdate()
    end
  end
end
-- Recipe sync uses its own prefix and does not alter the proven profession protocol.
-- Actions: B/I/E full recipe list, D recipe details, H list summary, G pull request, C cooldown, R sync request.
-- Older clients ignore actions they don't know, so every addition stays compatible.
local craftable={Alchemy=true,Blacksmithing=true,Enchanting=true,Engineering=true,Leatherworking=true,Tailoring=true,Cooking=true,['First Aid']=true}
local function clean(value)
  -- '~' and '^' separate packed entries, so they can't appear inside a name.
  return tostring(value or ''):gsub('[|\r\n~%^]',' '):sub(1,110)
end
-- Order-sensitive checksum of a sorted recipe list; equal hashes mean the list doesn't need re-sending.
local function listHash(list)
  local h=#list
  for _,name in ipairs(list) do
    for i=1,#name do h=(h*31+name:byte(i))%16777213 end
    h=(h*31+10)%16777213
  end
  return h
end
-- Returns sent, throttled. Newer clients answer with a result code (0 = sent); older ones with false.
-- Messages sent and received and GuildForge's chat lines, newest last, as plain text: the message log window
-- shows them all and /gf debug the last few.
GF.trace={}
function GF.note(line)
  GF.trace[#GF.trace+1]=((date and date('%H:%M:%S')) or '')..'  '..line
  if #GF.trace>500 then table.remove(GF.trace,1) end
  GF.logDirty=true
end
-- A value as plain text for the log: hidden values say so.
function GF.plainText(value) if isSecret(value) then return '<hidden>' end return tostring(value) end
-- Shows a value in chat as plain text: hidden values say so, and '|' is doubled so chat doesn't read it as a code.
function GF.safeText(value) if isSecret(value) then return '<hidden>' end return (tostring(value):gsub('|','||')) end
function GF.rawSend(prefix,payload)
  local fn=(C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  if not fn then return false,false end
  local result=fn(prefix,payload,'GUILD')
  GF.note('sent '..payload..' -> '..tostring(result))
  if result==false then return false,true end
  if type(result)=='number' and result~=0 then
    local codes=Enum and Enum.SendAddonMessageResult
    local throttled=result==3 or result==8 or (codes and (result==codes.AddonMessageThrottle or result==codes.ChannelThrottle))
    return false,throttled and true or false
  end
  return true,false
end
-- Blizzard gives each channel a burst of 10 messages, refilling at 1 per second. Each channel here keeps a
-- slightly smaller allowance (8, refilling at 0.9 per second) and only sends while it has some left.
GF.channels={{prefix=PREFIX,allowance=8},{prefix=RECIPE_PREFIX,allowance=8}}
function GF.drainChannel(channel,elapsed,canSend)
  channel.allowance=math.min(8,channel.allowance+elapsed*0.9)
  local queue=channel.prefix==PREFIX and GF.profQueue or recipeQueue
  while canSend and #queue>0 and channel.allowance>=1 do
    local ok,throttled=GF.rawSend(channel.prefix,queue[1])
    if ok then
      table.remove(queue,1); channel.allowance=channel.allowance-1; channel.failures=0
      if channel.prefix==PREFIX then sent=sent+1 else recipeSent=recipeSent+1 end
    else
      if throttled then
        channel.allowance=0
      else
        -- A message that keeps failing for another reason is dropped so it can't stall the queue.
        channel.failures=(channel.failures or 0)+1
        if channel.failures>=5 then table.remove(queue,1); channel.failures=0; droppedMessages=droppedMessages+1 end
        channel.allowance=channel.allowance-1
      end
      return
    end
  end
end
function GF.queuedCount() return #GF.profQueue+#recipeQueue end
-- Packs items into as few messages as fit in 250 characters: header..item..sep..item...
function GF.queuePacked(header,items,sep)
  local chunk
  for _,item in ipairs(items) do
    if #header+#item<=250 then
      if chunk and #chunk+#sep+#item<=250 then
        chunk=chunk..sep..item
      else
        if chunk then recipeQueue[#recipeQueue+1]=chunk end
        chunk=header..item
      end
    end
  end
  if chunk then recipeQueue[#recipeQueue+1]=chunk end
end
-- Format: D|who|prof|name~i12345 (or e7418 for enchants)~itemID:count,itemID:count
-- One recipe's details: name~i12345 (or e7418 for enchants)~itemID:count,itemID:count
function GF.detailEntry(prof,name)
  local info=recipeInfo and recipeInfo[prof] and recipeInfo[prof][name]
  if not info then return nil end
  local parts={}
  for _,r in ipairs(info.reagents or {}) do
    if r.id then parts[#parts+1]=r.id..':'..(r.n or 1) end
  end
  return clean(name)..'~'..(info.link or '')..'~'..table.concat(parts,',')..(info.gray and ('~'..info.gray) or '')
end
queueRecipes=function(prof,force)
  local mine=db and db[key()]
  local entries=mine and mine.recipes and mine.recipes[prof]
  if not entries then return end
  -- Several guildmates may pull the same list at once; one broadcast serves them all.
  if not force and fullQueuedAt[prof] and now()-fullQueuedAt[prof]<30 then return end
  fullQueuedAt[prof]=now()
  -- B|count, then names packed several per message (L), then E, then packed details (M).
  local who=key()
  local names,details={},{}
  for _,name in ipairs(entries) do
    names[#names+1]=clean(name)
    details[#details+1]=GF.detailEntry(prof,name)
  end
  recipeQueue[#recipeQueue+1]='B|'..who..'|'..prof..'|'..#entries
  GF.queuePacked('L|'..who..'|'..prof..'|',names,'~')
  recipeQueue[#recipeQueue+1]='E|'..who..'|'..prof
  GF.queuePacked('M|'..who..'|'..prof..'|',details,'^')
end
function GF.shareAllRecipes()
  local mine=db and db[key()]
  if not mine or not mine.recipes then return end
  for prof in pairs(mine.recipes) do if craftable[prof] then queueRecipes(prof) end end
end
-- Recipes catalogued from trainers (or unlearned on Forever) that this client knows about.
function GF.catalogList(prof)
  local list={}
  for name,info in pairs(recipeInfo and recipeInfo[prof] or {}) do
    -- Shared: recipes seen at trainers. Unlearned recipes from your own profession window only show for you.
    if type(info)=='table' and info.source and info.source~='Not learned' and not GF.isRankUpgrade(name,prof) then list[#list+1]=name end
  end
  table.sort(list)
  return list
end
local catalogQueuedAt={}
function GF.queueCatalog(prof)
  if catalogQueuedAt[prof] and now()-catalogQueuedAt[prof]<30 then return end
  catalogQueuedAt[prof]=now()
  local entries={}
  for _,name in ipairs(GF.catalogList(prof)) do
    local info=recipeInfo[prof][name]
    entries[#entries+1]=clean(name)..'~'..(info.req or '')..'~'..(info.link or '')
  end
  GF.queuePacked('W|'..key()..'|'..prof..'|',entries,'^')
end
-- Roll call: one S message per player fingerprints their professions, recipe lists, cooldowns and catalog.
-- S|who|version;p<professions>;c<cooldown stamp>;K<catalog>;<profIndex>:<count>:<hash>;...
function GF.professionHash(list)
  local parts={}
  for _,p in ipairs(type(list)=='table' and list or {}) do
    parts[#parts+1]=tostring(p.name)..':'..tostring(p.rank)..':'..tostring(p.max)
  end
  table.sort(parts)
  return listHash(parts)
end
function GF.catalogHash()
  local all={}
  for prof in pairs(craftable) do
    for _,name in ipairs(GF.catalogList(prof)) do all[#all+1]=prof..'|'..name end
  end
  table.sort(all)
  return #all>0 and listHash(all) or 0
end
-- One-message summary of our own data: version, hashes, and index:count:hash per scanned recipe list.
function GF.summaryPayload()
  local mine=db and db[key()]
  if not mine then return nil end
  local parts={VERSION,'p'..GF.professionHash(mine.professions),'c'..(mine.cdStamp or 0),'K'..GF.catalogHash(),'q'..GF.requestHash(key())}
  for index,prof in ipairs(professions) do
    local list=mine.recipes and mine.recipes[prof]
    if craftable[prof] and type(list)=='table' and #list>0 then
      parts[#parts+1]=index..':'..#list..':'..listHash(list)
    end
  end
  return 'S|'..key()..'|'..table.concat(parts,';')
end
local function sendSummary()
  local payload=GF.summaryPayload()
  if payload and #payload<=250 then addonSend(payload) end
end
function GF.recentlyAsked(askKey,seconds)
  if pullRequestedAt[askKey] and now()-pullRequestedAt[askKey]<seconds then return true end
  pullRequestedAt[askKey]=now()
  return false
end
-- Compare a guildmate's summary with what we saved and request only what differs.
handleSummary=function(who,extra)
  local version,rest=(extra or ''):match('^([^;]*);?(.*)$')
  if not version then return end
  addonVersions[nameId(who)]=version
  local record=db[who]
  local wants=''
  for token in rest:gmatch('[^;]+') do
    local kind,value=token:sub(1,1),token:sub(2)
    if kind=='p' then
      if not record or GF.professionHash(record.professions)~=tonumber(value) then wants=wants..'p' end
    elseif kind=='c' then
      local stamp=tonumber(value)
      if stamp and stamp>0 and cdStampSeen[who]~=stamp then cdStampSeen[who]=stamp; wants=wants..'c' end
    elseif kind=='K' then
      local hash=tonumber(value)
      -- Catalogs merge as a union: pull theirs when it differs; they pull ours from our own summary.
      -- At most every 10 minutes per guildmate, in case the two lists never quite match.
      if hash and hash>0 and hash~=GF.catalogHash() and not GF.recentlyAsked('K|'..who,600) then wants=wants..'K' end
    elseif kind=='q' then
      -- Their open requests: none left means drop ours; otherwise ask for the list when it differs.
      local hash=tonumber(value)
      local board=GF.requestBoard()
      if hash==0 then if board and board[who] then board[who]=nil; requestUpdate() end
      elseif hash and hash~=GF.requestHash(who) then wants=wants..'q' end
    else
      local index,count,hash=token:match('^(%d+):(%d+):(%d+)$')
      local prof=index and professions[tonumber(index)]
      if prof and craftable[prof] then
        local known=record and record.recipes and record.recipes[prof]
        local current=type(known)=='table' and #known==tonumber(count) and listHash(known)==tonumber(hash)
        if not current and not GF.recentlyAsked(who..'|'..prof,60) then
          recipeQueue[#recipeQueue+1]='G|'..key()..'|'..prof..'|'..who
        end
      end
    end
  end
  if wants~='' and not GF.recentlyAsked('A|'..who..'|'..wants,60) then
    addonSend('A|'..key()..'|'..who..'~'..wants)
  end
end

-- Profession cooldowns (Mooncloth, transmutes, Salt Shaker, and anything the trade window reports).
local COOLDOWN_SPELLS={[18560]='Tailoring',[17187]='Alchemy',[11479]='Alchemy',[11480]='Alchemy',
  [17559]='Alchemy',[17560]='Alchemy',[17561]='Alchemy',[17562]='Alchemy',[17563]='Alchemy',[17564]='Alchemy',[17565]='Alchemy',[17566]='Alchemy'}
local COOLDOWN_ITEMS={[15846]='Leatherworking'}
-- Classic transmutes share one timer, so they're tracked as a single "Transmute" entry.
function GF.cooldownName(name)
  if type(name)=='string' and name:find('^Transmute') then return 'Transmute' end
  return name
end
function GF.remainingFrom(start,duration)
  if isSecret(start) or isSecret(duration) then return nil end
  start,duration=tonumber(start),tonumber(duration)
  if not start or not duration or start==0 or duration<=1.5 then return 0 end
  return math.max(0,start+duration-GetTime())
end
-- Returns true when the stored ready time moved by more than a minute.
local function setMyCooldown(name,prof,remaining)
  local mine=db and db[key()]
  if not mine or not name or remaining==nil then return false end
  mine.cooldowns=mine.cooldowns or {}
  local readyAt=remaining>0 and (now()+math.floor(remaining)) or 0
  local old=mine.cooldowns[name]
  mine.cooldowns[name]={prof=prof,readyAt=readyAt,updated=now()}
  local changed=not old or math.abs((old.readyAt or 0)-readyAt)>60
  -- Summaries carry this stamp so guildmates only pull cooldowns after a change.
  if changed then mine.cdStamp=now() end
  return changed
end
local function checkCooldowns()
  if not db then return false end
  local changed=false
  for id,prof in pairs(COOLDOWN_SPELLS) do
    if GF.knowsSpell(id) and setMyCooldown(GF.cooldownName(GF.spellName(id)),prof,GF.remainingFrom(GF.spellCooldown(id))) then changed=true end
  end
  for id,prof in pairs(COOLDOWN_ITEMS) do
    if (GetItemCount and GetItemCount(id) or 0)>0 then
      if setMyCooldown(GetItemInfo(id) or 'Salt Shaker',prof,GF.remainingFrom(GF.itemCooldown(id))) then changed=true end
    end
  end
  return changed
end
local function queueCooldowns()
  local mine=db and db[key()]
  for name,cd in pairs(mine and mine.cooldowns or {}) do
    if type(cd)=='table' and craftable[cd.prof] then
      local remaining=math.max(0,math.floor((cd.readyAt or 0)-now()))
      recipeQueue[#recipeQueue+1]='C|'..key()..'|'..cd.prof..'|'..clean(name)..'~'..remaining
    end
  end
end
local cooldownsAskedAt=0
-- A guildmate asked us for professions (p), cooldowns (c) or our trainer catalog (K).
handleAsk=function(extra)
  local target,wants=(extra or ''):match('^(.-)~(%a*)$')
  if target~=key() then return end
  -- announce() itself skips repeats within 15 seconds, so several askers get one broadcast.
  if wants:find('p',1,true) then announce(false) end
  if wants:find('c',1,true) and now()-cooldownsAskedAt>=30 then cooldownsAskedAt=now(); queueCooldowns() end
  if wants:find('K',1,true) then for prof in pairs(craftable) do GF.queueCatalog(prof) end end
  if wants:find('q',1,true) and not GF.recentlyAsked('q-sent',20) then GF.queueMyRequests() end
end

function GF.applyDetail(prof,entry)
  local name,link,reagentText,gray=entry:match('^([^~]+)~([^~]*)~([^~]*)~?(%d*)$')
  if not name then return end
  name=clean(name)
  recipeInfo[prof]=recipeInfo[prof] or {}
  -- Details scanned on one of your own characters carry reagent names; keep them.
  local existing=recipeInfo[prof][name]
  if existing and not existing.remote then return end
  if not link:match('^[ie]%d+$') then link=nil end
  local reagents={}
  for id,count in reagentText:gmatch('(%d+):(%d+)') do
    if #reagents<12 then reagents[#reagents+1]={id=tonumber(id),n=tonumber(count)} end
  end
  recipeInfo[prof][name]={link=link,reagents=reagents,remote=true,gray=tonumber(gray)}
  requestUpdate()
end
function GF.applyCatalog(prof,entry)
  local name,req,link=entry:match('^([^~]+)~(%d*)~([^~]*)$')
  if not name then return end
  name=clean(name)
  if GF.isRankUpgrade(name,prof) then return end
  recipeInfo[prof]=recipeInfo[prof] or {}
  if not recipeInfo[prof][name] then
    recipeInfo[prof][name]={link=link:match('^[ie]%d+$') and link or nil,reagents={},remote=true,source='Trainer',req=tonumber(req)}
    requestUpdate()
  end
end
function GF.receiveRecipe(msg,sender)
  if type(msg)~='string' then return end
  local action,who,prof,extra=msg:match('^([^|]+)|([^|]+)|([^|]+)|?(.*)$')
  if not action or not who or not craftable[prof] or who==key() then return end
  if not senderMatches(sender,who) then return end
  local pendingKey=who..'|'..prof
  if action=='B' then
    local expected=tonumber(extra)
    if not expected or expected<0 or expected>500 then return end
    recipePending[pendingKey]={items={},seen={},expected=expected}
  elseif action=='I' or action=='L' then
    -- I carries one recipe name; L carries several, separated by '~'.
    local pending=recipePending[pendingKey]
    if not pending or not extra then return end
    for raw in extra:gmatch(action=='L' and '[^~]+' or '.+') do
      local item=clean(raw)
      -- A dropped E/B can splice two broadcasts together; repeats mean the list is unreliable, so skip them.
      if not pending.seen[item] and #pending.items<pending.expected then
        pending.seen[item]=true
        pending.items[#pending.items+1]=item
      end
    end
  elseif action=='E' then
    local pending=recipePending[pendingKey]
    if pending and #pending.items==pending.expected then
      local record=db[who] or {professions={},updated=now()}
      record.recipes=record.recipes or {}
      record.recipeUpdated=record.recipeUpdated or {}
      table.sort(pending.items)
      GF.recipeNews(who,prof,record.recipes[prof],pending.items)
      record.recipes[prof]=pending.items
      record.recipeUpdated[prof]=now()
      db[who]=record
      recipeReceived=recipeReceived+1
      requestUpdate()
    end
    recipePending[pendingKey]=nil
  elseif action=='D' or action=='M' then
    -- D carries one recipe's details; M carries several, separated by '^'.
    for entry in (extra or ''):gmatch(action=='M' and '[^%^]+' or '.+') do GF.applyDetail(prof,entry) end
  elseif action=='G' then
    if extra==key() then queueRecipes(prof) end
  elseif action=='W' then
    -- Trainer recipes, separated by '^'. 1.0.9 and earlier sent T/U with Forever's unlearned recipes; ignored.
    for entry in (extra or ''):gmatch('[^%^]+') do GF.applyCatalog(prof,entry) end
  elseif action=='C' then
    local name,remaining=(extra or ''):match('^([^~]+)~(%d+)$')
    if not name then return end
    remaining=tonumber(remaining)
    local record=db[who] or {professions={},updated=now()}
    record.cooldowns=record.cooldowns or {}
    -- A "ready" cooldown we never saw running is one of the global-cooldown blips older versions shared.
    if remaining==0 and not record.cooldowns[clean(name)] then return end
    record.cooldowns[clean(name)]={prof=prof,readyAt=remaining>0 and (now()+remaining) or 0,updated=now()}
    db[who]=record
    requestUpdate()
  end
end
local function linkCode(link)
  if type(link)~='string' then return nil end
  local id=link:match('item:(%d+)')
  if id then return 'i'..id end
  id=link:match('enchant:(%d+)') or link:match('spell:(%d+)')
  if id then return 'e'..id end
end
local function itemId(link)
  return type(link)=='string' and tonumber(link:match('item:(%d+)')) or nil
end
local function storeInfo(prof,name,link,icon,reagents,gray)
  recipeInfo[prof]=recipeInfo[prof] or {}
  recipeInfo[prof][name]={link=link,icon=icon,reagents=reagents,gray=gray}
end
-- The skill level a recipe sorts by: where it turns gray (Forever's profession window), else what a trainer asks.
function GF.recipeLevel(info) return info and (info.gray or info.req) or nil end
-- Saves a finished scan and queues it for the guild when the recipe list changed.
local function commitScan(prof,recipes,warnFiltered,levels)
  if #recipes==0 then return end
  table.sort(recipes)
  local record=db and db[key()]
  if not record then return end
  record.recipes=record.recipes or {}
  record.recipeUpdated=record.recipeUpdated or {}
  local old=record.recipes[prof]
  -- Filtered windows may show fewer entries; don't erase a larger saved list.
  if old and #recipes<#old then
    if warnFiltered then log('Recipe scan for '..prof..' showed fewer recipes than saved; check profession filters. Saved list preserved.') end
    return
  end
  local changed=not old or #old~=#recipes
  if not changed then for i,name in ipairs(recipes) do if old[i]~=name then changed=true; break end end end
  if changed then
    GF.recipeNews(key(),prof,old,recipes)
    record.recipes[prof]=recipes
    record.recipeUpdated[prof]=now()
    queueRecipes(prof,true)
    log('Scanned '..#recipes..' visible '..prof..' recipes; queued guild sharing.')
  elseif levels and not (record.levelsShared and record.levelsShared[prof]) then
    -- Lists shared before 1.2.0 had no recipe levels; send this one again once so guildmates can sort by level.
    queueRecipes(prof,true)
  end
  if levels then record.levelsShared=record.levelsShared or {}; record.levelsShared[prof]=true end
  requestUpdate()
end
-- Records a recipe cooldown seen in the trade window; a recipe that had one and now reports none is ready.
function GF.noteRecipeCooldown(prof,recipe,remaining)
  -- Forever reports a few seconds on every recipe right after crafting (the global cooldown); profession
  -- cooldowns run hours or days, so anything under a minute isn't one.
  if remaining and remaining<60 then remaining=0 end
  local name=GF.cooldownName(recipe)
  local mine=db and db[key()]
  local tracked=mine and mine.cooldowns and mine.cooldowns[name]
  if (remaining and remaining>0) or tracked then
    if setMyCooldown(name,prof,remaining or 0) then queueCooldowns() end
  end
end
function GF.scanTradeSkill()
  if not (GetNumTradeSkills and GetTradeSkillInfo) then return end
  local prof=GetTradeSkillLine and GetTradeSkillLine()
  if not craftable[prof] then return end
  local recipes,seen={},{}
  for i=1,GetNumTradeSkills() do
    local name,kind=GetTradeSkillInfo(i)
    if name and kind~='header' and not seen[name] then
      local recipe=clean(name)
      seen[name]=true; recipes[#recipes+1]=recipe
      local reagents={}
      for r=1,(GetTradeSkillNumReagents and GetTradeSkillNumReagents(i) or 0) do
        local reagentName,_,count=GetTradeSkillReagentInfo(i,r)
        local reagentLink=GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(i,r)
        reagents[#reagents+1]={id=itemId(reagentLink),n=tonumber(count) or 1,name=reagentName}
      end
      storeInfo(prof,recipe,linkCode(GetTradeSkillItemLink and GetTradeSkillItemLink(i)),GetTradeSkillIcon and GetTradeSkillIcon(i),reagents)
      if GetTradeSkillCooldown then GF.noteRecipeCooldown(prof,recipe,tonumber(GetTradeSkillCooldown(i))) end
    end
  end
  commitScan(prof,recipes,true)
end
function GF.scanCraft()
  if not (GetNumCrafts and GetCraftInfo) then return end
  local prof=GetCraftDisplaySkillLine and GetCraftDisplaySkillLine()
  if not craftable[prof] then return end
  local recipes,seen={},{}
  for i=1,GetNumCrafts() do
    local name,_,kind=GetCraftInfo(i)
    if name and kind~='header' and not seen[name] then
      local recipe=clean(name)
      seen[name]=true; recipes[#recipes+1]=recipe
      local reagents={}
      for r=1,(GetCraftNumReagents and GetCraftNumReagents(i) or 0) do
        local reagentName,_,count=GetCraftReagentInfo(i,r)
        local reagentLink=GetCraftReagentItemLink and GetCraftReagentItemLink(i,r)
        reagents[#reagents+1]={id=itemId(reagentLink),n=tonumber(count) or 1,name=reagentName}
      end
      storeInfo(prof,recipe,linkCode(GetCraftItemLink and GetCraftItemLink(i)),GetCraftIcon and GetCraftIcon(i),reagents)
    end
  end
  commitScan(prof,recipes,false)
end
-- WoW: Forever uses the modern profession window (C_TradeSkillUI) instead of GetTradeSkillInfo.
function GF.schematicDetails(recipeID)
  local T=C_TradeSkillUI
  local schematic=T.GetRecipeSchematic and T.GetRecipeSchematic(recipeID,false)
  local basicReagent=Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
  local reagents={}
  for _,slot in ipairs(schematic and schematic.reagentSlotSchematics or {}) do
    local first=slot.reagents and slot.reagents[1]
    if first and first.itemID and (not basicReagent or slot.reagentType==basicReagent) then
      reagents[#reagents+1]={id=first.itemID,n=tonumber(slot.quantityRequired) or 1}
    end
  end
  local output=schematic and schematic.outputItemID
  return output and ('i'..output) or ('e'..recipeID),reagents
end
function GF.scanModernTradeSkill()
  local T=C_TradeSkillUI
  if GetTradeSkillInfo or not (T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return end
  -- Skip other players' linked or guild profession windows; only your own recipes are yours to share.
  if (T.IsTradeSkillLinked and T.IsTradeSkillLinked()) or (T.IsTradeSkillGuild and T.IsTradeSkillGuild()) then return end
  local base=T.GetBaseProfessionInfo and T.GetBaseProfessionInfo()
  local prof=base and base.professionName
  if not craftable[prof] then return end
  recipeInfo[prof]=recipeInfo[prof] or {}
  local recipes,seen={},{}
  for _,recipeID in ipairs(T.GetAllRecipeIDs() or {}) do
    local info=T.GetRecipeInfo(recipeID)
    if info and info.name and not seen[info.name] then
      local recipe=clean(info.name)
      seen[info.name]=true
      if info.learned then
        recipes[#recipes+1]=recipe
        local link,reagents=GF.schematicDetails(recipeID)
        storeInfo(prof,recipe,link,info.icon,reagents,tonumber(info.maxTrivialLevel))
        if T.GetRecipeCooldown then GF.noteRecipeCooldown(prof,recipe,tonumber((T.GetRecipeCooldown(recipeID)))) end
      elseif not recipeInfo[prof][recipe] or recipeInfo[prof][recipe].source=='Not learned' then
        -- Unlearned recipes feed your own "not known in guild" list. Forever doesn't give the skill a recipe
        -- needs, only the skill where it turns gray (maxTrivialLevel), which orders the list nearly the same.
        local link,reagents=GF.schematicDetails(recipeID)
        recipeInfo[prof][recipe]={link=link,icon=info.icon,reagents=reagents,remote=true,source='Not learned',gray=tonumber(info.maxTrivialLevel)}
      end
    end
  end
  commitScan(prof,recipes,true,true)
end
-- Trainers list recipes nobody may know yet; catalogue them for the "not known in guild" list.
local RANK_UPGRADES={Apprentice=true,Journeyman=true,Expert=true,Artisan=true,Master=true,Grand=true}
-- Trainers sell profession ranks as "Tailoring" + "Journeyman", or as "Journeyman Cook"; neither is a recipe.
function GF.isRankUpgrade(name,prof,subText)
  if type(name)~='string' then return false end
  if name==prof or RANK_UPGRADES[subText or ''] then return true end
  local first=name:match('^(%a+)%s')
  return first~=nil and RANK_UPGRADES[first]==true
end
-- Clears rank upgrades that older scans saved (and shared) as trainer recipes.
function GF.purgeRankUpgrades()
  for prof,list in pairs(recipeInfo or {}) do
    for name,info in pairs(list) do
      if type(info)=='table' and info.source and GF.isRankUpgrade(name,prof) then list[name]=nil end
    end
  end
end
function GF.scanTrainer()
  if not (GetNumTrainerServices and GetTrainerServiceInfo) then return end
  local added=0
  for i=1,GetNumTrainerServices() do
    local name,subText,category=GetTrainerServiceInfo(i)
    -- Classic trainers may not report a skill line; the "Requires: Enchanting (10)" skill names it too.
    local prof=GetTrainerServiceSkillLine and GetTrainerServiceSkillLine(i)
    local reqSkill,req
    if GetTrainerServiceSkillReq then reqSkill,req=GetTrainerServiceSkillReq(i) end
    if not craftable[prof] then prof=reqSkill end
    -- Rank upgrades are listed under the profession's own name with a rank as the subtext.
    if name and category~='header' and craftable[prof] and not GF.isRankUpgrade(name,prof,subText) then
      local recipe=clean(name)
      recipeInfo[prof]=recipeInfo[prof] or {}
      if not recipeInfo[prof][recipe] then
        -- Classic Era trainers don't list reagents; they fill in when a crafter shares the recipe.
        local reagents={}
        for r=1,(GetTrainerServiceNumReagents and GetTrainerServiceNumReagents(i) or 0) do
          local reagentName,_,n
          if GetTrainerServiceReagentInfo then reagentName,_,n=GetTrainerServiceReagentInfo(i,r) end
          if reagentName then reagents[#reagents+1]={name=reagentName,n=tonumber(n) or 1} end
        end
        recipeInfo[prof][recipe]={link=linkCode(GetTrainerServiceItemLink and GetTrainerServiceItemLink(i)),icon=GetTrainerServiceIcon and GetTrainerServiceIcon(i),reagents=reagents,remote=true,source='Trainer',req=tonumber(req)}
        added=added+1
      end
    end
  end
  if added>0 then log('Catalogued '..added..' trainer recipes; sharing with the guild.'); sendSummary(); requestUpdate() end
end
local scanScheduled=false
-- /gf scan: run with a profession window open to see what each scanner reads from it.
function GF.scanReport()
  local function say(s) log(s,true) end
  local function v(fn,...) if not fn then return 'missing' end local ok,a=pcall(fn,...); return ok and GF.safeText(a) or 'error' end
  say('classic window: GetTradeSkillLine='..v(GetTradeSkillLine)..', GetNumTradeSkills='..v(GetNumTradeSkills)
    ..', GetCraftDisplaySkillLine='..v(GetCraftDisplaySkillLine)..', GetNumCrafts='..v(GetNumCrafts))
  local T=C_TradeSkillUI or {}
  local ok,base=pcall(T.GetBaseProfessionInfo or function() end)
  local ok2,child=pcall(T.GetChildProfessionInfo or function() end)
  local ok3,ids=pcall(T.GetAllRecipeIDs or function() end)
  local learned,total,sample=0,0,nil
  if ok3 and type(ids)=='table' then
    for _,id in ipairs(ids) do
      total=total+1
      local info=T.GetRecipeInfo and T.GetRecipeInfo(id)
      if info and info.learned then learned=learned+1 elseif info and not sample then sample=info end
    end
  end
  if sample then say('first unlearned: '..GF.safeText(sample.name)..', turns gray at '..GF.safeText(sample.maxTrivialLevel)) end
  say('modern window: base='..GF.safeText(ok and type(base)=='table' and base.professionName)..', child='..GF.safeText(ok2 and type(child)=='table' and child.professionName)
    ..', recipes='..total..' ('..learned..' learned), linked='..v(T.IsTradeSkillLinked)..', guild='..v(T.IsTradeSkillGuild)..', ready='..v(T.IsTradeSkillReady))
  say('scanner used: '..((GetTradeSkillInfo or not (T.GetAllRecipeIDs and T.GetRecipeInfo)) and 'classic' or 'modern')
    ..'; GuildForge shares: '..table.concat((function() local t={} for k in pairs(craftable) do t[#t+1]=k end table.sort(t) return t end)(),', '))
  scanRecipes()
  local mine=db and db[key()]
  local lists={}
  for prof,list in pairs(mine and mine.recipes or {}) do lists[#lists+1]=prof..' '..#list end
  say('saved for you after scanning: '..(#lists>0 and table.concat(lists,', ') or 'none'))
end
scanRecipes=function()
  scanScheduled=false
  GF.scanTradeSkill()
  GF.scanCraft()
  GF.scanModernTradeSkill()
end
-- Sync asks for summaries; guildmates pull only the lists that differ. Older clients still get full lists.
-- Roll call: V|who|version|r asks everyone online to reply with their one-message summary.
local lastRollCall=0
local function rollCall(force)
  if not force and now()-lastRollCall<30 then return end
  lastRollCall=now()
  addonSend('V|'..key()..'|'..VERSION..'|r')
  sendSummary()
end
-- Once a second: while the game blocks our messages (instances, combat), drop what's queued (it would never
-- arrive). Returns true when the block lifts, so the caller can check in with the guild and catch up.
GF.sinceBlockCheck=1
function GF.watchBlocked(elapsed)
  GF.sinceBlockCheck=GF.sinceBlockCheck+elapsed
  if GF.sinceBlockCheck<1 then return end
  GF.sinceBlockCheck=0
  local blocked=GF.messagingBlocked()
  if blocked then
    if not GF.held then
      GF.held=true
    end
    GF.heldDropped=(GF.heldDropped or 0)+GF.queuedCount()
    wipe(GF.profQueue); wipe(recipeQueue)
  elseif GF.held then
    GF.held=false
    return true
  end
end
local function doSync()
  save()
  if checkCooldowns() then queueCooldowns() end
  rollCall(true); requestUpdate()
  log('Guild sync request sent.')
end
function GF.doPush()
  save(); fullQueuedAt={}; catalogQueuedAt={}; GF.shareAllRecipes(); checkCooldowns(); queueCooldowns()
  for prof in pairs(craftable) do GF.queueCatalog(prof) end
  log('Sharing all of your recipes with the guild ('..GF.queuedCount()..' messages queued).',true)
end
function GF.doRefresh()
  save(); announce(true); scanRecipes(); checkCooldowns(); requestUpdate()
  log('Local professions refreshed and shared.')
end
-- The window's Sync button: rescan and share your own professions, then ask the guild what changed.
function GF.syncNow()
  save(); announce(true); scanRecipes(); if checkCooldowns() then queueCooldowns() end
  rollCall(true); requestUpdate()
  log('Your professions shared; guild sync request sent.')
end

-- Guild roster: who is online, when offline members were last seen, and who runs GuildForge.
function GF.refreshRoster()
  wipe(guildOnline); wipe(guildLastSeen); wipe(guildMembers); rosterHasOffline=false
  if not (IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo) then return end
  for i=1,GetNumGuildMembers() do
    local name,_,_,_,_,_,_,_,online=GetGuildRosterInfo(i)
    local id=nameId(name)
    if id then
      guildMembers[id]=true
      if online then
        guildOnline[id]=true; guildLastSeen[id]=0
      else
        rosterHasOffline=true
      end
      if not online and GetGuildRosterLastOnline then
        local years,months,days,hours=GetGuildRosterLastOnline(i)
        if tonumber(years) then
          guildLastSeen[id]=((((years*365)+(months or 0)*30+(days or 0))*24)+(hours or 0))*3600
        end
      end
    end
  end
end
function GF.guildBucketKey()
  if not (IsInGuild and IsInGuild()) then return GF.forever and 'No guild' or 'No guild - '..realm() end
  local name=GetGuildInfo and GetGuildInfo('player')
  if not name or isSecret(name) then return nil end
  if GF.forever then return name end
  return name..' - '..realm()
end
-- 1.0.7 and earlier saved Forever guilds and members with the realm; move them to realmless keys.
function GF.dropForeverRealms(bucket)
  local guilds=GuildForgeDB.guilds
  local old=guilds[bucket..' - '..realm()]
  if old and old.members then
    guilds[bucket]=guilds[bucket] or {members={}}
    for k,v in pairs(old.members) do if not guilds[bucket].members[k] then guilds[bucket].members[k]=v end end
    guilds[bucket..' - '..realm()]=nil
  end
  local members=guilds[bucket] and guilds[bucket].members
  if not members then return end
  local renames={}
  for k in pairs(members) do
    local character=splitName(k)
    if character and character~=k then renames[k]=character end
  end
  for k,character in pairs(renames) do
    local record=members[k]; members[k]=nil
    local current=members[character]
    if not current or (record.updated or 0)>(current.updated or 0) then members[character]=record end
  end
end
-- Points db at the current guild's members; returns true when the guild changed.
local function selectGuild()
  if not GuildForgeDB or not playerName() then return false end
  local bucket=GF.guildBucketKey()
  if not bucket or bucket==currentGuild then return false end
  if GF.forever then GF.dropForeverRealms(bucket) end
  GuildForgeDB.guilds[bucket]=GuildForgeDB.guilds[bucket] or {members={}}
  local members=GuildForgeDB.guilds[bucket].members
  for k,v in pairs(tempMembers) do if not members[k] then members[k]=v end end
  wipe(tempMembers)
  -- Bring your own recipes along from the old shared list or from a guild this character left.
  local me=key()
  if not members[me] then
    local mine=GuildForgeDB.members and GuildForgeDB.members[me]
    if not mine then
      for _,guild in pairs(GuildForgeDB.guilds) do
        if guild.members and guild.members[me] then mine=guild.members[me]; break end
      end
    end
    if mine then
      members[me]={professions=mine.professions or {},updated=mine.updated,localPlayer=true,recipes=mine.recipes or {},recipeUpdated=mine.recipeUpdated or {},cooldowns=mine.cooldowns or {},cdStamp=mine.cdStamp}
    end
  end
  currentGuild=bucket; db=members
  wipe(activeSeen); wipe(selectedCrafter)
  return true
end
-- Older versions kept every guild in one list; move each member into the guild whose roster has them.
function GF.migrateLegacy()
  local legacy=GuildForgeDB and GuildForgeDB.members
  if type(legacy)~='table' or not currentGuild then return end
  local inGuild=IsInGuild and IsInGuild()
  if inGuild and next(guildMembers)==nil then return end
  local moved=0
  for k,v in pairs(legacy) do
    if k==key() or (inGuild and guildMembers[nameId(k)]) then
      if not db[k] then db[k]=v; moved=moved+1 end
      legacy[k]=nil
    end
  end
  if next(legacy)==nil then GuildForgeDB.members=nil end
  if moved>0 then requestUpdate() end
end
-- Saved data keeps people who have since left the guild; only show current roster members.
-- The roster is only trusted when it's known to include offline members ("Show Offline" on, or offline entries seen).
function GF.rosterComplete()
  return next(guildMembers)~=nil and (rosterHasOffline or (GetGuildRosterShowOffline and GetGuildRosterShowOffline()))
end
local function currentMembers()
  if not db or not GF.rosterComplete() then return db or {} end
  local me=key()
  local list={}
  for who,record in pairs(db) do
    if who==me or guildMembers[nameId(who)] then list[who]=record end
  end
  return list
end
-- Deletes saved records for people who have left the guild.
function GF.pruneFormerMembers()
  if not db or db==tempMembers or not GF.rosterComplete() then return end
  local me=key()
  for who in pairs(db) do
    if who~=me and not guildMembers[nameId(who)] then db[who]=nil end
  end
end
local function requestRoster()
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
  elseif GuildRoster then GuildRoster() end
end
-- /gf debug: how names are read from the game, the roster and saved data, and the last messages.
function GF.debugReport()
  local function say(s) log(s,true) end
  local first,second=UnitName('player')
  local iface=GetBuildInfo and select(4,GetBuildInfo())
  say(string.format('client: interface %s (%s); UnitName: %s / %s; realm: %s',GF.safeText(iface),GF.forever and 'Forever' or 'Classic',GF.safeText(first),GF.safeText(second),realm()))
  say('you: '..key()..'  id='..tostring(nameId(key())))
  local C=C_ChatInfo or {}
  local function flag(fn) if not fn then return 'n/a' end return GF.safeText(fn()) end
  say(string.format('sending held: %s (WoW says restricted=%s, lockdown=%s, in instance=%s; restricted is true on Forever even when sending works); messages not sent while held: %d',
    tostring(GF.messagingBlocked()),flag(C.AreOutgoingAddonChatMessagesRestricted),flag(C.InChatMessagingLockdown),GF.safeText(IsInInstance and IsInInstance()),GF.heldDropped or 0))
  local count=0; for _ in pairs(guildMembers) do count=count+1 end
  say(string.format('roster: %d members read; complete=%s; you found in roster=%s',count,tostring(GF.rosterComplete() and true or false),tostring(guildMembers[nameId(key())]==true)))
  if GetNumGuildMembers and GetGuildRosterInfo then
    for i=1,math.min(4,GetNumGuildMembers()) do
      local name=GetGuildRosterInfo(i)
      say('   roster #'..i..': "'..GF.safeText(name)..'"  id='..tostring(nameId(name)))
    end
  end
  for who,record in pairs(db or {}) do
    local id=nameId(who)
    local profs,lists={},{}
    for _,p in ipairs(record.professions or {}) do profs[#profs+1]=p.name end
    for prof,list in pairs(record.recipes or {}) do lists[#lists+1]=prof..' '..#list end
    say('   saved: "'..who..'"  professions: '..(#profs>0 and table.concat(profs,', ') or 'none')..'; recipes: '..(#lists>0 and table.concat(lists,', ') or 'none')
      ..(guildMembers[id] and '' or '  |cffff5a5aNOT IN ROSTER (hidden, will be pruned)|r'))
  end
  say('your summary: '..GF.safeText(GF.summaryPayload() or 'none yet')..'  (recipe lists show as number:count:hash; none means no profession window scanned yet)')
  local registered=C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered
  say(string.format('prefixes: registered=%s/%s (results %s/%s); addon messages heard: %d from any addon, %d GuildForge',
    tostring(registered and registered(PREFIX)),tostring(registered and registered(RECIPE_PREFIX)),
    tostring(GF.prefixResults and GF.prefixResults[1]),tostring(GF.prefixResults and GF.prefixResults[2]),GF.addonEvents or 0,GF.ourEvents or 0))
  say('last messages (all of them: /gf log):')
  for i=math.max(1,#GF.trace-11),#GF.trace do
    say('   '..GF.trace[i]:gsub('|','||'):gsub('REJECTED','|cffff5a5aREJECTED|r'))
  end
end
function GF.versionLabel(id)
  local version=addonVersions[id]
  if version==nil then return 'version unknown' end
  if version=='' then return 'older version' end
  return 'v'..version
end
-- Names of guildmates online with GuildForge (you first); withVersions appends each one's version.
local function activeUsers(withVersions)
  local me=nameId(key())
  local list={}
  local rosterKnown=next(guildOnline)~=nil
  for id,name in pairs(activeSeen) do
    if id~=me and (not rosterKnown or guildOnline[id]) then
      list[#list+1]=withVersions and (name..'  |cff909090'..GF.versionLabel(id)..'|r') or name
    end
  end
  table.sort(list)
  table.insert(list,1,(playerName() or 'You')..(withVersions and ('  |cff909090v'..VERSION..'|r') or ''))
  return list
end
function GF.markSeen(who)
  local id=nameId(who)
  if id and not activeSeen[id] then activeSeen[id]=displayName(who); if refreshMinimap then refreshMinimap() end end
end


-- Guild news: skill milestones, newly learned recipes and finished requests, found by comparing what
-- arrives with what was saved. Kept per guild, newest last, for the Home tab and the Discord bot.
GF.NEWS_MAX=150
function GF.guildStore()
  if not currentGuild or db==tempMembers or not GuildForgeDB then return nil end
  return GuildForgeDB.guilds[currentGuild]
end
function GF.newsList()
  local store=GF.guildStore()
  if not store then return {} end
  store.news=store.news or {}
  return store.news
end
function GF.addNews(entry)
  local store=GF.guildStore()
  if not store then return end
  store.news=store.news or {}
  local list=store.news
  entry.t=entry.t or now()
  for i=#list,math.max(1,#list-40),-1 do
    local e=list[i]
    if e.who==entry.who and e.kind==entry.kind and e.prof==entry.prof then
      -- A skill milestone within 6 hours of the last one replaces it, so a leveling spree is one line.
      if entry.kind=='skill' then
        if entry.t-(e.t or 0)<21600 then table.remove(list,i) end
        break
      end
      if entry.name and e.name==entry.name then return end
    end
  end
  list[#list+1]=entry
  while #list>GF.NEWS_MAX do table.remove(list,1) end
  requestUpdate()
end
-- Every 25 skill points is a milestone; a profession that wasn't there before was taken up.
-- No news the first time we hear about someone: that's catching up, not something new.
function GF.skillNews(who,old,new)
  if type(old)~='table' or #old==0 or type(new)~='table' then return end
  local before={}
  for _,p in ipairs(old) do before[p.name]=tonumber(p.rank) or 0 end
  for _,p in ipairs(new) do
    local was,rank=before[p.name],tonumber(p.rank) or 0
    if not was then GF.addNews({who=who,kind='took',prof=p.name,value=rank})
    elseif rank>=25 and math.floor(rank/25)>math.floor(was/25) then
      GF.addNews({who=who,kind='skill',prof=p.name,value=math.floor(rank/25)*25})
    end
  end
end
function GF.othersKnow(who,prof,name)
  for other,record in pairs(db or {}) do
    local list=other~=who and record.recipes and record.recipes[prof]
    if type(list)=='table' then for _,n in ipairs(list) do if n==name then return true end end end
  end
  return false
end
-- New recipes in a list: each one by name, or a count when there are many (plus any nobody else knows).
function GF.recipeNews(who,prof,old,new)
  if type(old)~='table' or #old==0 or type(new)~='table' then return end
  local had={}
  for _,n in ipairs(old) do had[n]=true end
  local fresh={}
  for _,n in ipairs(new) do if not had[n] then fresh[#fresh+1]=n end end
  if #fresh==0 then return end
  if #fresh>3 then GF.addNews({who=who,kind='learnedMany',prof=prof,value=#fresh}) end
  local firsts=0
  for _,n in ipairs(fresh) do
    local first=not GF.othersKnow(who,prof,n)
    if #fresh<=3 or (first and firsts<3) then
      if first then firsts=firsts+1 end
      GF.addNews({who=who,kind='learned',prof=prof,name=n,first=first or nil})
    end
  end
end
function GF.whoText(who)
  if who==key() then return '|cff40ff40You|r' end
  return '|cffffffff'..displayName(who)..'|r'
end
function GF.newsText(e)
  local who=GF.whoText(e.who)
  if e.kind=='skill' then return who..' reached |cffffd100'..e.value..'|r '..e.prof end
  if e.kind=='took' then return who..' took up '..e.prof end
  if e.kind=='learned' then
    local info=recipeInfo and recipeInfo[e.prof] and recipeInfo[e.prof][e.name]
    return who..' learned '..GF.recipeLabel(e.name,info)..(e.first and '  |cffff9933first in the guild|r' or '')
  end
  if e.kind=='learnedMany' then return who..' learned '..e.value..' '..e.prof..' recipes' end
  if e.kind=='filled' then
    return who..' made '..((e.value or 1)>1 and (e.value..'× ') or '')..'|cffffd100'..e.name..'|r for '..GF.whoText(e.other)
  end
  return who
end

-- Request board: guildmates post what they need crafted, a crafter takes it, and the poster marks it done.
-- The poster's copy is the real one. Q|who|id~prof~name~qty~age~takenBy~note posts or updates a request;
-- Z|who|ids lists the poster's open ones (others are dropped); Y|crafter|poster~id takes one (~0 gives it
-- back); X|who|id~d or ~c closes one as done or cancelled. Summaries carry q<hash> so late logins catch up.
-- Older versions ignore all of these.
GF.REQUEST_DAYS=3
GF.REQUEST_MAX=5
function GF.requestBoard()
  local store=GF.guildStore()
  if not store then return nil end
  store.requests=store.requests or {}
  return store.requests
end
-- One poster's open requests by id, dropping expired ones.
function GF.requestsOf(who)
  local board=GF.requestBoard()
  local posted=board and board[who]
  local list={}
  for id,r in pairs(posted or {}) do
    if now()-(r.t or 0)>GF.REQUEST_DAYS*86400 then posted[id]=nil else r.who=who; list[#list+1]=r end
  end
  table.sort(list,function(a,b) return a.id<b.id end)
  return list
end
function GF.requestHash(who)
  local parts={}
  for _,r in ipairs(GF.requestsOf(who)) do parts[#parts+1]=r.id..':'..(r.takenBy or '') end
  return #parts>0 and listHash(parts) or 0
end
function GF.requestPayload(r)
  -- The note goes last, so a long recipe name only shortens the note.
  return ('Q|'..key()..'|'..r.id..'~'..r.prof..'~'..r.name..'~'..r.qty..'~'..math.max(0,now()-r.t)..'~'..(r.takenBy or '')..'~'..(r.note or '')):sub(1,250)
end
function GF.queueMyRequests()
  local list=GF.requestsOf(key())
  local ids={}
  for _,r in ipairs(list) do ids[#ids+1]=r.id end
  addonSend('Z|'..key()..'|'..table.concat(ids,','))
  for _,r in ipairs(list) do addonSend(GF.requestPayload(r)) end
end
function GF.knowsRecipe(prof,name)
  local list=db and db[key()] and db[key()].recipes and db[key()].recipes[prof]
  for _,n in ipairs(type(list)=='table' and list or {}) do if n==name then return true end end
  return false
end
function GF.isOnline(who) return who==key() or guildOnline[nameId(who)]==true end
function GF.postRequest(prof,name,qty,note)
  local board=GF.requestBoard()
  if not board or not craftable[prof] then log('Requests need a guild.',true); return nil end
  if #GF.requestsOf(key())>=GF.REQUEST_MAX then
    log('You can have '..GF.REQUEST_MAX..' open requests. Mark one done or cancel it first.',true)
    return nil
  end
  GuildForgeDB.requestSeq=(GuildForgeDB.requestSeq or 0)+1
  local r={id=GuildForgeDB.requestSeq,prof=prof,name=clean(name),qty=math.max(1,math.min(99,math.floor(tonumber(qty) or 1))),
    note=clean(note or ''):sub(1,60),t=now()}
  if r.note=='' then r.note=nil end
  board[key()]=board[key()] or {}
  board[key()][r.id]=r
  addonSend(GF.requestPayload(r))
  log('Posted '..r.qty..'× '..r.name..' on the request board.',true)
  requestUpdate()
  return r
end
function GF.closeRequest(id,done)
  local board=GF.requestBoard()
  local r=board and board[key()] and board[key()][id]
  if not r then return end
  board[key()][id]=nil
  addonSend('X|'..key()..'|'..id..'~'..(done and 'd' or 'c'))
  if done and r.takenBy then GF.addNews({who=r.takenBy,kind='filled',prof=r.prof,name=r.name,value=r.qty,other=key()}) end
  requestUpdate()
end
-- Take a request (or give it back). The crafter whispers the poster, who has to be online to take it.
function GF.takeRequest(r,giveBack)
  if giveBack then
    if r.takenBy==key() then r.takenBy=nil end
  else
    if r.takenBy or not GF.isOnline(r.who) then return end
    r.takenBy=key()
    if SendChat then
      SendChat('[GuildForge] I can make '..r.qty..'× '..r.name..' for you (from the request board).','WHISPER',nil,displayName(r.who))
    end
  end
  addonSend('Y|'..key()..'|'..r.who..'~'..r.id..(giveBack and '~0' or ''))
  requestUpdate()
end
function GF.receiveRequest(action,who,extra)
  local board=GF.requestBoard()
  if not board then return end
  extra=extra or ''
  if action=='Q' then
    local id,prof,name,qty,age,taken,note=extra:match('^(%d+)~([^~]*)~([^~]+)~(%d+)~(%d+)~([^~]*)~?(.*)$')
    if not id or not craftable[prof] or tonumber(age)>GF.REQUEST_DAYS*86400 then return end
    id=tonumber(id)
    board[who]=board[who] or {}
    local isNew=not board[who][id]
    local r={id=id,prof=prof,name=clean(name),qty=math.max(1,tonumber(qty) or 1),t=now()-tonumber(age),
      takenBy=taken~='' and taken or nil,note=note~='' and clean(note):sub(1,60) or nil}
    board[who][id]=r
    -- Only fresh posts are announced, not the ones caught up on at login.
    if isNew and tonumber(age)<600 and not r.takenBy and GF.knowsRecipe(prof,r.name) then
      log(displayName(who)..' needs '..r.qty..'× '..r.name..', which you can make. See Requests in GuildForge.')
    end
  elseif action=='Z' then
    local keep={}
    for id in extra:gmatch('%d+') do keep[tonumber(id)]=true end
    for id in pairs(board[who] or {}) do if not keep[id] then board[who][id]=nil end end
  elseif action=='X' then
    local id,how=extra:match('^(%d+)~?(%a?)$')
    local list=board[who]
    local r=list and id and list[tonumber(id)]
    if not r then return end
    list[r.id]=nil
    if how=='d' and r.takenBy then GF.addNews({who=r.takenBy,kind='filled',prof=r.prof,name=r.name,value=r.qty,other=who}) end
  elseif action=='Y' then
    local poster,id,back=extra:match('^(.-)~(%d+)~?(%d?)$')
    local list=poster and board[poster]
    local r=list and list[tonumber(id)]
    if not r then return end
    if back=='0' then
      if r.takenBy==who then r.takenBy=nil end
    elseif not r.takenBy then
      r.takenBy=who
      if poster==key() then log(displayName(who)..' will make your '..r.name..'.',true) end
    end
    -- The poster settles who has it when two crafters answer at once.
    if poster==key() then addonSend(GF.requestPayload(r)) end
  end
  requestUpdate()
end
-- Everyone's open requests (current guild members only), oldest first, filtered by a search term.
function GF.allRequests(term)
  local board=GF.requestBoard()
  local members=currentMembers()
  local list={}
  for who in pairs(board or {}) do
    if who==key() or members[who] or not GF.rosterComplete() then
      for _,r in ipairs(GF.requestsOf(who)) do
        local text=(r.name..' '..r.prof..' '..displayName(who)..' '..(r.note or '')):lower()
        if not term or term=='' or text:find(term,1,true) then list[#list+1]=r end
      end
    end
  end
  table.sort(list,function(a,b) return a.t<b.t end)
  return list
end
function GF.requestsYouCanMake()
  local n=0
  for _,r in ipairs(GF.allRequests()) do
    if r.who~=key() and not r.takenBy and GF.knowsRecipe(r.prof,r.name) then n=n+1 end
  end
  return n
end

-- Display helpers
function GF.agoText(age)
  if age<60 then return 'just now' end
  if age<3600 then return math.floor(age/60)..'m ago' end
  if age<86400 then return math.floor(age/3600)..'h ago' end
  return math.floor(age/86400)..'d ago'
end
function GF.updatedLabel(timestamp)
  if not timestamp or timestamp<=0 then return 'unknown' end
  return GF.agoText(math.max(0,now()-timestamp))
end
function GF.durationText(seconds)
  seconds=math.max(0,math.floor(seconds))
  if seconds>=86400 then return math.floor(seconds/86400)..'d '..math.floor((seconds%86400)/3600)..'h' end
  if seconds>=3600 then return math.floor(seconds/3600)..'h '..math.floor((seconds%3600)/60)..'m' end
  return math.max(1,math.floor(seconds/60))..'m'
end
function GF.availabilityText(c)
  if c.online then return '|cff40ff40Online|r' end
  local ago=guildLastSeen[c.id]
  if ago then return '|cffa0a0a0Seen '..(ago<3600 and 'within 1h' or GF.agoText(ago))..'|r' end
  return '|cff808080Offline|r'
end
function GF.setDot(texture,online)
  if online then texture:SetVertexColor(.2,1,.2) else texture:SetVertexColor(.4,.4,.4) end
end
function GF.rankColor(rank)
  if rank>=300 then return 1,.5,0 end
  if rank>=225 then return .64,.21,.93 end
  if rank>=150 then return 0,.44,.87 end
  if rank>=75 then return .12,1,0 end
  return .62,.62,.62
end
function GF.rankTitle(max)
  if max>=300 then return 'Artisan' elseif max>=225 then return 'Expert' elseif max>=150 then return 'Journeyman' end
  return 'Apprentice'
end
local function splitLink(link)
  if type(link)~='string' then return nil end
  local kind,id=link:match('^([ie])(%d+)$')
  return kind,tonumber(id)
end
local function itemIcon(id)
  if not id then return nil end
  if GetItemIcon then return GetItemIcon(id) end
  if GetItemInfoInstant then return select(5,GetItemInfoInstant(id)) end
end
function GF.recipeIcon(prof,info)
  if info and info.icon then return info.icon end
  local kind,id=splitLink(info and info.link)
  if kind=='i' then return itemIcon(id) or QUESTION_ICON end
  if kind=='e' and GetSpellTexture then return GetSpellTexture(id) or professionIcons[prof] end
  return professionIcons[prof] or QUESTION_ICON
end
function GF.recipeLabel(name,info)
  local kind,id=splitLink(info and info.link)
  if kind=='i' then
    local _,_,quality=GetItemInfo(id)
    local color=quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color and color.hex then return color.hex..name..'|r' end
  end
  return '|cffffd100'..name..'|r'
end
local function reagentName(r)
  if r.id then
    local name=GetItemInfo(r.id)
    if name then return name end
  end
  return r.name or (r.id and ('Item #'..r.id)) or 'Unknown reagent'
end
local function bagCount(r)
  local lookup=r.id or r.name
  if not lookup or not GetItemCount then return 0,0 end
  local bags=GetItemCount(lookup) or 0
  local total=GetItemCount(lookup,true) or bags
  return bags,math.max(0,total-bags)
end
-- How many times the recipe can be made from your bags; nil when reagents are unknown.
local function craftableTimes(info)
  if not info or not info.reagents or #info.reagents==0 then return nil end
  local times=math.huge
  for _,r in ipairs(info.reagents) do
    if not r.id and not r.name then return nil end
    local bags=bagCount(r)
    times=math.min(times,math.floor(bags/math.max(1,r.n or 1)))
  end
  return times
end
function GF.showLinkTooltip(owner,link)
  local kind,id=splitLink(link)
  if not kind then return false end
  GameTooltip:SetOwner(owner,'ANCHOR_RIGHT')
  GameTooltip:SetHyperlink((kind=='i' and 'item:' or 'enchant:')..id)
  return true
end
function GF.chatLinkFor(link)
  local kind,id=splitLink(link)
  if kind=='i' then return (select(2,GetItemInfo(id))) end
  if kind=='e' and GetSpellLink then return GetSpellLink(id) end
end
local function insertChatLink(link)
  local chatLink=GF.chatLinkFor(link)
  if chatLink and InsertChatLink then InsertChatLink(chatLink) end
end

-- Craft requests: whisper the best online crafter with the item link and the mats you already have.
function GF.craftTarget(r)
  for _,c in ipairs(r.crafters) do
    if not c.isMe and c.online then return c end
  end
end
-- fromBank: a guild bank craft order was just placed, so say the mats are on their way in the mail.
function GF.requestCraft(r,target,fromBank)
  if not (target and SendChat) then return end
  local message='[GuildForge] Hi '..target.character..'! Could you craft '..(GF.chatLinkFor(r.info and r.info.link) or r.name)..' for me?'
  local have={}
  for _,reagent in ipairs(r.info and r.info.reagents or {}) do
    local bags=bagCount(reagent)
    local need=reagent.n or 1
    if bags>0 then have[#have+1]=math.min(bags,need)..'/'..need..' '..reagentName(reagent) end
  end
  local tail=#have>0 and (' I have '..table.concat(have,', ')..'.') or ' Happy to bring mats or tip.'
  if fromBank then tail=' The guild bank is mailing you the materials (Guild Bank Toons craft order).' end
  if #message+#tail>250 then tail=fromBank and ' The guild bank is mailing you the mats.' or ' I have some of the mats.' end
  SendChat(message..tail,'WHISPER',nil,target.character)
  log('Whispered '..target.character..' about '..r.name..'.',true)
end

-- Guild Bank Toons (optional addon): shows guild bank stock and asks the bank for missing materials.
-- Looked up on every use rather than once at login: the bank addon can load late, and a guild gets its
-- first bank toon mid-session. Everything bank-related hides whenever this returns nil.
function GF.bankAPI()
  local api=GuildBankToonsAPI
  if type(api)~='table' or (tonumber(api.version) or 0)<1 then return nil end
  -- Hook once, even before HasBank is true, so the window redraws the moment a bank appears.
  if not GF.bankHooked and type(api.RegisterCallback)=='function' then
    GF.bankHooked=true
    pcall(api.RegisterCallback,requestRedraw)
  end
  local ok,has=pcall(api.HasBank)
  if ok and has==true then return api end
end
-- How many the guild bank has; nil when there's no bank to ask (or the reagent has no item id).
function GF.bankCount(reagent)
  local api=GF.bankAPI()
  if not (api and reagent and reagent.id) then return nil end
  local ok,n=pcall(api.Available,reagent.id)
  return ok and tonumber(n) or 0
end
-- What's still missing after your bags, from a list of {reagent=,need=}: {[itemID]=count} or nil.
-- The bank only deals in item ids, so reagents known by name alone are skipped.
function GF.bankMissing(list)
  local items,any={},false
  for _,n in ipairs(list) do
    local id,short=n.reagent.id,n.need-(bagCount(n.reagent))
    if id and short>0 then items[id]=(items[id] or 0)+short; any=true end
  end
  return any and items or nil
end
-- A recipe's reagents for qty crafts, in the shape shoppingNeeds and bankMissing use.
function GF.recipeNeeds(info,qty)
  local list={}
  for _,r in ipairs(info and info.reagents or {}) do list[#list+1]={reagent=r,need=(r.n or 1)*qty} end
  return list
end
-- True when the bank has at least one of the missing items; greys the button out otherwise.
function GF.bankHasAny(items)
  for id in pairs(items or {}) do
    if (GF.bankCount({id=id}) or 0)>0 then return true end
  end
  return false
end
function GF.itemCounts(items)
  local parts={}
  for id,count in pairs(items) do parts[#parts+1]=count..'× '..reagentName({id=id}) end
  table.sort(parts)
  return table.concat(parts,', ')
end
-- Places the request and reports it in chat. mailTo makes it a craft order mailed to that crafter.
-- Returns how many requests were made (0 when none).
function GF.bankRequest(items,note,mailTo)
  local api=GF.bankAPI()
  if not (api and items) then return 0 end
  local ok,ids,short,reason=pcall(api.Request,items,note,mailTo)
  if not ok then log('The guild bank request failed: '..tostring(ids),true); return 0 end
  local made=type(ids)=='table' and #ids or 0
  short=type(short)=='table' and short or {}
  if made==0 then
    log('No guild bank request made'..(reason and (': '..tostring(reason)) or '.'),true)
    return 0
  end
  local got={}
  for id,count in pairs(items) do
    local left=count-(tonumber(short[id]) or 0)
    if left>0 then got[id]=left end
  end
  log('Asked the guild bank for '..GF.itemCounts(got)..' ('..note..')'..(mailTo and (', mailed to '..mailTo) or '')
    ..'. '..made..' request'..(made==1 and '' or 's')..' waiting for approval.',true)
  if next(short) then log('The guild bank couldn\'t cover: '..GF.itemCounts(short)..'.',true) end
  return made
end
-- Craft order: the bank mails the missing mats to the crafter, then the crafter gets the usual whisper.
function GF.craftOrder(r,target,qty)
  local items=GF.bankMissing(GF.recipeNeeds(r.info,qty))
  if not (target and items) then return 0 end
  local made=GF.bankRequest(items,'for '..qty..'× '..r.name,target.character)
  if made>0 then GF.requestCraft(r,target,true) end
  return made
end

-- Shopping list: recipes you plan to craft, combined into the mats you still need.
function GF.shoppingKey(prof,name) return prof..'|'..name end
local function changeShopping(prof,name,delta)
  local list=GuildForgeDB.shopping
  local k=GF.shoppingKey(prof,name)
  local qty=(list[k] or 0)+delta
  list[k]=qty>0 and qty or nil
  requestUpdate()
end
local function shoppingEntries()
  local entries={}
  for k,qty in pairs(GuildForgeDB and GuildForgeDB.shopping or {}) do
    local prof,name=k:match('^([^|]+)|(.+)$')
    if prof then entries[#entries+1]={prof=prof,name=name,qty=qty,info=recipeInfo and recipeInfo[prof] and recipeInfo[prof][name]} end
  end
  table.sort(entries,function(a,b) return a.name<b.name end)
  return entries
end
-- Combined reagent needs keyed by item id (or name when the id is unknown), plus a display order.
function GF.shoppingNeeds()
  local needs,order={},{}
  for _,e in ipairs(shoppingEntries()) do
    for _,r in ipairs(e.info and e.info.reagents or {}) do
      local k=r.id or r.name
      if k then
        local need=needs[k]
        if not need then need={reagent=r,need=0}; needs[k]=need; order[#order+1]=need end
        need.need=need.need+(r.n or 1)*e.qty
      end
    end
  end
  table.sort(order,function(a,b) return reagentName(a.reagent)<reagentName(b.reagent) end)
  return needs,order
end

-- Item tooltips: who in the guild crafts an item, which recipes use it, and shopping-list needs.
function GF.buildIndex()
  recipeIndex={craftedBy={},usedIn={}}
  local knownBy={}
  for who,record in pairs(currentMembers()) do
    if type(record)=='table' and type(record.recipes)=='table' then
      local character=displayName(who)
      for prof,list in pairs(record.recipes) do
        local listed={}
        for _,name in ipairs(type(list)=='table' and list or {}) do
          if not listed[name] then
            listed[name]=true
            local k=prof..'|'..name
            knownBy[k]=knownBy[k] or {}
            table.insert(knownBy[k],character)
          end
        end
      end
    end
  end
  for prof,list in pairs(recipeInfo or {}) do
    for name,info in pairs(list) do
      local kind,id=splitLink(info.link)
      local crafters=knownBy[prof..'|'..name]
      if kind=='i' and crafters then recipeIndex.craftedBy[id]=crafters end
      for _,r in ipairs(info.reagents or {}) do
        local k=r.id or r.name
        if k then
          recipeIndex.usedIn[k]=recipeIndex.usedIn[k] or {}
          table.insert(recipeIndex.usedIn[k],name)
        end
      end
    end
  end
  indexDirty=false
end
function GF.shortList(list,limit)
  local out={}
  for i=1,math.min(limit,#list) do out[i]=list[i] end
  return table.concat(out,', ')..(#list>limit and (' +'..(#list-limit)) or '')
end
function GF.addTooltipLines(tooltip,id)
  if not settings().tooltips or not db or type(id)~='number' or isSecret(id) then return end
  if indexDirty or not recipeIndex then GF.buildIndex() end
  local name=GetItemInfo(id)
  local crafters=recipeIndex.craftedBy[id]
  local usedIn=recipeIndex.usedIn[id] or (name and recipeIndex.usedIn[name])
  local needs=GF.shoppingNeeds()
  local need=needs[id] or (name and needs[name])
  if not (crafters or usedIn or need) then return end
  tooltip:AddLine(' ')
  if crafters then tooltip:AddLine('|cffe7c483GuildForge:|r crafted by '..GF.shortList(crafters,4),.85,.85,.85,true) end
  if usedIn then tooltip:AddLine('|cffe7c483GuildForge:|r used in '..GF.shortList(usedIn,3),.85,.85,.85,true) end
  if need then
    local bags=GetItemCount and GetItemCount(id) or 0
    if bags<need.need then
      tooltip:AddLine('|cffe7c483GuildForge:|r need '..(need.need-bags)..' more for your shopping list ('..bags..'/'..need.need..')',1,.4,.4)
    else
      tooltip:AddLine('|cffe7c483GuildForge:|r enough for your shopping list ('..bags..'/'..need.need..')',.4,1,.4)
    end
  end
end
function GF.hookTooltips()
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item,function(tooltip,data)
      if tooltip==GameTooltip or tooltip==ItemRefTooltip then GF.addTooltipLines(tooltip,data and data.id) end
    end)
    return
  end
  for _,tooltip in ipairs({GameTooltip,ItemRefTooltip}) do
    if tooltip and tooltip.HookScript then
      tooltip:HookScript('OnTooltipSetItem',function(self)
        local _,link=self:GetItem()
        GF.addTooltipLines(self,itemId(link))
      end)
    end
  end
end

-- Guild data per profession
function GF.gather(prof)
  local crafters,recipes,byName={},{},{}
  local me=key()
  for who,record in pairs(currentMembers()) do
    if type(record)=='table' then
      local skill
      for _,p in ipairs(record.professions or {}) do if p.name==prof then skill=p; break end end
      local known=record.recipes and record.recipes[prof]
      if type(known)~='table' then known=nil end
      if skill or (known and #known>0) then
        local character=displayName(who)
        local c={key=who,character=character,rank=skill and tonumber(skill.rank) or 0,max=skill and tonumber(skill.max) or 0,updated=record.updated,recipeCount=known and #known or 0,isMe=(who==me)}
        c.id=nameId(who)
        c.online=c.isMe or guildOnline[c.id]==true
        crafters[#crafters+1]=c
        local listed={}
        for _,name in ipairs(known or {}) do
          if type(name)=='string' and not listed[name] then
            listed[name]=true
            local r=byName[name]
            if not r then r={name=name,crafters={}}; byName[name]=r; recipes[#recipes+1]=r end
            r.crafters[#r.crafters+1]=c
            if c.isMe then r.mine=true end
          end
        end
      end
    end
  end
  -- Online crafters first, then highest skill.
  local byAvailability=function(a,b)
    if a.online~=b.online then return a.online end
    if a.rank~=b.rank then return a.rank>b.rank end
    return a.character:lower()<b.character:lower()
  end
  table.sort(crafters,byAvailability)
  for _,r in ipairs(recipes) do table.sort(r.crafters,byAvailability) end
  -- Lowest skill level first, like the Not known in guild list; recipes with no level known go last.
  local info=recipeInfo and recipeInfo[prof] or {}
  for _,r in ipairs(recipes) do r.level=GF.recipeLevel(info[r.name]) or 9999 end
  table.sort(recipes,function(a,b)
    if a.level~=b.level then return a.level<b.level end
    return a.name<b.name
  end)
  return crafters,recipes,byName
end
function GF.hasProfession(prof)
  for _,record in pairs(currentMembers()) do
    if type(record)=='table' then
      for _,p in ipairs(record.professions or {}) do if p.name==prof then return true end end
    end
  end
  return false
end
local function found(text,term) return text and text:lower():find(term,1,true)~=nil end
function GF.recipeMatches(r,prof,term)
  if term=='' or found(prof,term) or found(r.name,term) then return true end
  for _,c in ipairs(r.crafters) do if found(c.character,term) then return true end end
  for _,reagent in ipairs(r.info and r.info.reagents or {}) do
    if found(reagentName(reagent),term) then return true end
  end
  return false
end
function GF.professionData(prof,term)
  local crafters,recipes,byName=GF.gather(prof)
  local filter=selectedCrafter[prof]
  local matsOnly=GuildForgeDB and GuildForgeDB.ui.matsOnly
  local d={crafters=crafters,recipes=recipes,crafterCount=#crafters,recipeCount=#recipes,fc={},fr={},unknown={},unknownTotal=0,ready=0,filter=filter}
  for _,c in ipairs(crafters) do
    if term=='' or found(prof,term) or found(c.character,term) then d.fc[#d.fc+1]=c end
    if c.key==filter then d.filterName=c.character end
    if not d.top or c.rank>d.top.rank then d.top=c end
  end
  for _,r in ipairs(recipes) do
    r.info=recipeInfo and recipeInfo[prof] and recipeInfo[prof][r.name]
    r.times=craftableTimes(r.info)
    if (r.times or 0)>0 then d.ready=d.ready+1 end
    local byFilter=not filter
    if filter then for _,c in ipairs(r.crafters) do if c.key==filter then byFilter=true; break end end end
    if byFilter and GF.recipeMatches(r,prof,term) and (not matsOnly or (r.times or 0)>0) then d.fr[#d.fr+1]=r end
  end
  -- Recipes seen at trainers (or unlearned on Forever) that nobody in the guild has shared.
  for name,info in pairs(recipeInfo and recipeInfo[prof] or {}) do
    if not byName[name] then
      d.unknownTotal=d.unknownTotal+1
      -- Nobody can share reagents for these, so skip the mat counting and leave them out of "Have mats".
      local r={name=name,crafters={},info=info}
      if not filter and not matsOnly and GF.recipeMatches(r,prof,term) then d.unknown[#d.unknown+1]=r end
    end
  end
  -- Lowest profession skill first: the skill a recipe needs (trainers), else where it turns gray (Forever's
  -- profession window); recipes with neither go last.
  table.sort(d.unknown,function(a,b)
    local ra,rb=a.info.req or a.info.gray or 9999,b.info.req or b.info.gray or 9999
    if ra~=rb then return ra<rb end
    return a.name<b.name
  end)
  if filter and not d.filterName then selectedCrafter[prof]=nil; d.filter=nil end
  return d
end
-- Counts and top crafter for every profession in one pass, for the All tab when nothing is searched.
function GF.professionOverview()
  local out={}
  for _,prof in ipairs(professions) do out[prof]={crafterCount=0,recipeCount=0,seen={}} end
  for who,record in pairs(currentMembers()) do
    if type(record)=='table' then
      for _,p in ipairs(record.professions or {}) do
        local o=out[p.name]
        if o then
          o.crafterCount=o.crafterCount+1
          local rank=tonumber(p.rank) or 0
          if not o.top or rank>o.top.rank then o.top={character=displayName(who),rank=rank} end
        end
      end
      for prof,list in pairs(type(record.recipes)=='table' and record.recipes or {}) do
        local o=out[prof]
        if o and type(list)=='table' then
          for _,name in ipairs(list) do
            if not o.seen[name] then o.seen[name]=true; o.recipeCount=o.recipeCount+1 end
          end
        end
      end
    end
  end
  return out
end
function GF.gatherCooldowns(prof,term)
  local list,ready={},0
  local me=key()
  for who,record in pairs(currentMembers()) do
    if type(record)=='table' and type(record.cooldowns)=='table' then
      local character=displayName(who)
      for name,cd in pairs(record.cooldowns) do
        if type(cd)=='table' and (not prof or cd.prof==prof)
          and (term=='' or found(character,term) or found(name,term) or found(cd.prof,term)) then
          local entry={character=character,isMe=(who==me),name=name,prof=cd.prof,readyAt=cd.readyAt or 0,updated=cd.updated}
          entry.online=entry.isMe or guildOnline[nameId(who)]==true
          entry.ready=entry.readyAt<=now()
          if entry.ready then ready=ready+1 end
          list[#list+1]=entry
        end
      end
    end
  end
  table.sort(list,function(a,b)
    if a.ready~=b.ready then return a.ready end
    if a.readyAt~=b.readyAt then return a.readyAt<b.readyAt end
    return a.character<b.character
  end)
  return list,ready
end

-- Widget skinning and pooled list rows
local function skin(f,alpha,r,g,b)
  if not f.SetBackdrop then return end
  f:SetBackdrop({bgFile='Interface\\Tooltips\\UI-Tooltip-Background',edgeFile='Interface\\Tooltips\\UI-Tooltip-Border',tile=true,tileSize=16,edgeSize=12,insets={left=3,right=3,top=3,bottom=3}})
  f:SetBackdropColor(.08,.06,.04,alpha or .9)
  f:SetBackdropBorderColor(r or .78,g or .62,b or .32,1)
end
local function addHighlight(b,alpha)
  local hl=b:CreateTexture(nil,'HIGHLIGHT')
  hl:SetTexture('Interface\\QuestFrame\\UI-QuestTitleHighlight')
  hl:SetBlendMode('ADD'); hl:SetAllPoints(); hl:SetAlpha(alpha or .45)
  return hl
end
local function fontString(parent,template,justify)
  local fs=parent:CreateFontString(nil,'OVERLAY',template)
  fs:SetJustifyH(justify or 'LEFT')
  if fs.SetWordWrap then fs:SetWordWrap(false) end
  return fs
end
local function smallButton(parent,label,width)
  local b=CreateFrame('Button',nil,parent,'UIPanelButtonTemplate')
  b:SetSize(width,20); b:SetText(label)
  return b
end
function GF.iconSlot(b,size)
  b.iconBorder=b:CreateTexture(nil,'BORDER'); b.iconBorder:SetSize(size+2,size+2); b.iconBorder:SetColorTexture(0,0,0,.8)
  b.icon=b:CreateTexture(nil,'ARTWORK'); b.icon:SetSize(size,size); b.icon:SetPoint('CENTER',b.iconBorder,'CENTER'); b.icon:SetTexCoord(.07,.93,.07,.93)
end
local factories={}
factories.profHeader=function()
  local b=CreateFrame('Button',nil,scrollContent)
  b:SetHeight(34)
  local bg=b:CreateTexture(nil,'BACKGROUND'); bg:SetAllPoints(); bg:SetColorTexture(1,1,1,.035)
  b.icon=b:CreateTexture(nil,'ARTWORK'); b.icon:SetSize(26,26); b.icon:SetPoint('LEFT',6,0); b.icon:SetTexCoord(.07,.93,.07,.93)
  b.name=fontString(b,'GameFontNormal'); b.name:SetPoint('LEFT',b.icon,'RIGHT',10,0)
  b.info=fontString(b,'GameFontHighlightSmall','RIGHT'); b.info:SetPoint('RIGHT',-12,0)
  addHighlight(b,.3)
  return b
end
factories.section=function()
  local b=CreateFrame('Button',nil,scrollContent)
  b:SetHeight(24)
  b.toggle=b:CreateTexture(nil,'ARTWORK'); b.toggle:SetSize(16,16); b.toggle:SetPoint('LEFT',2,0)
  b.label=fontString(b,'GameFontNormal'); b.label:SetPoint('LEFT',b.toggle,'RIGHT',6,0)
  b.extra=fontString(b,'GameFontDisableSmall','RIGHT'); b.extra:SetPoint('RIGHT',-6,0)
  local line=b:CreateTexture(nil,'ARTWORK'); line:SetHeight(1); line:SetColorTexture(.85,.68,.3,.55)
  line:SetPoint('BOTTOMLEFT',2,1); line:SetPoint('BOTTOMRIGHT',-2,1)
  addHighlight(b,.3)
  return b
end
factories.crafter=function()
  local b=CreateFrame('Button',nil,scrollContent)
  b:SetHeight(20)
  b.stripe=b:CreateTexture(nil,'BACKGROUND'); b.stripe:SetAllPoints()
  b.selected=b:CreateTexture(nil,'BORDER'); b.selected:SetAllPoints()
  b.selected:SetTexture('Interface\\QuestFrame\\UI-QuestTitleHighlight'); b.selected:SetBlendMode('ADD'); b.selected:SetVertexColor(1,.75,.2)
  b.dot=b:CreateTexture(nil,'ARTWORK'); b.dot:SetTexture(DOT_TEXTURE); b.dot:SetSize(9,9); b.dot:SetPoint('LEFT',6,0)
  b.name=fontString(b,'GameFontHighlight'); b.name:SetPoint('LEFT',22,0); b.name:SetWidth(190)
  b.bar=CreateFrame('StatusBar',nil,b); b.bar:SetSize(160,13); b.bar:SetPoint('LEFT',220,0)
  b.bar:SetStatusBarTexture('Interface\\TargetingFrame\\UI-StatusBar')
  local barBg=b.bar:CreateTexture(nil,'BACKGROUND'); barBg:SetAllPoints(); barBg:SetColorTexture(0,0,0,.55)
  b.bar.text=fontString(b.bar,'GameFontHighlightSmall','CENTER'); b.bar.text:SetPoint('CENTER',0,0)
  b.recipes=fontString(b,'GameFontHighlightSmall'); b.recipes:SetPoint('LEFT',392,0); b.recipes:SetWidth(100)
  b.seen=fontString(b,'GameFontHighlightSmall','RIGHT'); b.seen:SetPoint('RIGHT',-8,0); b.seen:SetWidth(130)
  addHighlight(b)
  return b
end
factories.recipe=function()
  local b=CreateFrame('Button',nil,scrollContent)
  b:SetHeight(26)
  b.stripe=b:CreateTexture(nil,'BACKGROUND'); b.stripe:SetAllPoints()
  b.selected=b:CreateTexture(nil,'BORDER'); b.selected:SetAllPoints()
  b.selected:SetTexture('Interface\\QuestFrame\\UI-QuestTitleHighlight'); b.selected:SetBlendMode('ADD'); b.selected:SetVertexColor(1,.75,.2); b.selected:SetAlpha(.5)
  GF.iconSlot(b,22); b.iconBorder:SetPoint('LEFT',6,0)
  b.name=fontString(b,'GameFontNormal'); b.name:SetPoint('LEFT',b.iconBorder,'RIGHT',8,0); b.name:SetWidth(284)
  b.crafters=fontString(b,'GameFontHighlightSmall'); b.crafters:SetPoint('LEFT',330,0); b.crafters:SetWidth(180)
  b.mats=fontString(b,'GameFontHighlightSmall','RIGHT'); b.mats:SetPoint('RIGHT',-8,0); b.mats:SetWidth(120)
  addHighlight(b)
  return b
end
factories.reagent=function()
  local b=CreateFrame('Button',nil,scrollContent)
  b:SetHeight(19)
  b.icon=b:CreateTexture(nil,'ARTWORK'); b.icon:SetSize(16,16); b.icon:SetPoint('LEFT',0,0); b.icon:SetTexCoord(.07,.93,.07,.93)
  b.name=fontString(b,'GameFontHighlightSmall'); b.name:SetPoint('LEFT',b.icon,'RIGHT',6,0); b.name:SetWidth(220)
  b.count=fontString(b,'GameFontHighlightSmall'); b.count:SetPoint('LEFT',250,0); b.count:SetWidth(320)
  addHighlight(b,.25)
  return b
end
factories.actions=function()
  local f=CreateFrame('Frame',nil,scrollContent)
  f:SetHeight(26)
  f.b1=smallButton(f,'',140); f.b1:SetPoint('LEFT',0,0)
  f.b2=smallButton(f,'',110); f.b2:SetPoint('LEFT',f.b1,'RIGHT',6,0)
  f.b3=smallButton(f,'',110); f.b3:SetPoint('LEFT',f.b2,'RIGHT',6,0)
  f.text=fontString(f,'GameFontDisableSmall'); f.text:SetPoint('LEFT',f.b3,'RIGHT',10,0)
  return f
end
-- Guild bank buttons, a row of their own so the existing actions keep their place when there's no bank.
factories.bankActions=function()
  local f=CreateFrame('Frame',nil,scrollContent)
  f:SetHeight(26)
  f.b1=smallButton(f,'',170); f.b1:SetPoint('LEFT',0,0)
  f.b2=smallButton(f,'',180); f.b2:SetPoint('LEFT',f.b1,'RIGHT',6,0)
  f.text=fontString(f,'GameFontDisableSmall'); f.text:SetPoint('LEFT',f.b2,'RIGHT',10,0)
  return f
end
-- A guild bank button: greyed out with the reason when there's nothing to ask for, the request in its
-- tooltip otherwise. Disabled buttons only show tooltips with motion scripts on.
function GF.setBankButton(b,label,items,why,onClick)
  b:SetText(label); b:Show()
  if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
  if not why and not GF.bankHasAny(items) then why='The guild bank has none of these right now' end
  if why then b:Disable() else b:Enable() end
  b:SetScript('OnClick',function() releaseSearchFocus(); if not why then onClick() end end)
  b:SetScript('OnEnter',function(self)
    GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
    GameTooltip:AddLine(label,1,.82,0)
    if why then GameTooltip:AddLine(why,1,.5,.3,true) else GameTooltip:AddLine('Asks for '..GF.itemCounts(items),.8,.8,.8,true) end
    GameTooltip:Show()
  end)
  b:SetScript('OnLeave',GameTooltip_Hide)
end
-- Guild bank stock after the bag counts on a reagent line; empty when there's no bank.
function GF.bankText(reagent)
  local n=GF.bankCount(reagent)
  if not n then return '' end
  return '  '..(n>0 and '|cffe7c483' or '|cff808080')..'Guild bank: '..n..'|r'
end
factories.shopItem=function()
  local b=CreateFrame('Button',nil,scrollContent)
  b:SetHeight(26)
  b.stripe=b:CreateTexture(nil,'BACKGROUND'); b.stripe:SetAllPoints()
  GF.iconSlot(b,22); b.iconBorder:SetPoint('LEFT',6,0)
  b.name=fontString(b,'GameFontNormal'); b.name:SetPoint('LEFT',b.iconBorder,'RIGHT',8,0); b.name:SetWidth(250)
  b.prof=fontString(b,'GameFontDisableSmall'); b.prof:SetPoint('LEFT',300,0); b.prof:SetWidth(110)
  b.status=fontString(b,'GameFontHighlightSmall'); b.status:SetPoint('LEFT',410,0); b.status:SetWidth(90)
  b.remove=smallButton(b,'X',24); b.remove:SetPoint('RIGHT',-4,0)
  b.plus=smallButton(b,'+',24); b.plus:SetPoint('RIGHT',b.remove,'LEFT',-8,0)
  b.qty=fontString(b,'GameFontHighlight','CENTER'); b.qty:SetPoint('RIGHT',b.plus,'LEFT',-2,0); b.qty:SetWidth(28)
  b.minus=smallButton(b,'-',24); b.minus:SetPoint('RIGHT',b.qty,'LEFT',-2,0)
  addHighlight(b)
  return b
end
factories.cooldown=function()
  local b=CreateFrame('Button',nil,scrollContent)
  b:SetHeight(20)
  b.stripe=b:CreateTexture(nil,'BACKGROUND'); b.stripe:SetAllPoints()
  b.dot=b:CreateTexture(nil,'ARTWORK'); b.dot:SetTexture(DOT_TEXTURE); b.dot:SetSize(9,9); b.dot:SetPoint('LEFT',6,0)
  b.icon=b:CreateTexture(nil,'ARTWORK'); b.icon:SetSize(16,16); b.icon:SetPoint('LEFT',20,0); b.icon:SetTexCoord(.07,.93,.07,.93)
  b.text=fontString(b,'GameFontHighlight'); b.text:SetPoint('LEFT',b.icon,'RIGHT',6,0); b.text:SetWidth(400)
  b.status=fontString(b,'GameFontHighlightSmall','RIGHT'); b.status:SetPoint('RIGHT',-8,0); b.status:SetWidth(150)
  addHighlight(b)
  return b
end
factories.note=function()
  local f=CreateFrame('Frame',nil,scrollContent)
  f.text=f:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
  f.text:SetPoint('TOPLEFT',0,-2); f.text:SetJustifyH('LEFT'); f.text:SetJustifyV('TOP')
  return f
end
factories.news=function()
  local b=CreateFrame('Button',nil,scrollContent)
  b:SetHeight(20)
  b.stripe=b:CreateTexture(nil,'BACKGROUND'); b.stripe:SetAllPoints()
  b.icon=b:CreateTexture(nil,'ARTWORK'); b.icon:SetSize(16,16); b.icon:SetPoint('LEFT',6,0); b.icon:SetTexCoord(.07,.93,.07,.93)
  b.text=fontString(b,'GameFontHighlight'); b.text:SetPoint('LEFT',b.icon,'RIGHT',6,0); b.text:SetWidth(500)
  b.when=fontString(b,'GameFontDisableSmall','RIGHT'); b.when:SetPoint('RIGHT',-8,0); b.when:SetWidth(80)
  addHighlight(b,.25)
  return b
end
factories.request=function()
  local b=CreateFrame('Button',nil,scrollContent)
  b:SetHeight(26)
  b.stripe=b:CreateTexture(nil,'BACKGROUND'); b.stripe:SetAllPoints()
  b.dot=b:CreateTexture(nil,'ARTWORK'); b.dot:SetTexture(DOT_TEXTURE); b.dot:SetSize(9,9); b.dot:SetPoint('LEFT',6,0)
  GF.iconSlot(b,22); b.iconBorder:SetPoint('LEFT',20,0)
  b.name=fontString(b,'GameFontNormal'); b.name:SetPoint('LEFT',b.iconBorder,'RIGHT',8,0); b.name:SetWidth(210)
  b.info=fontString(b,'GameFontHighlightSmall'); b.info:SetPoint('LEFT',270,0); b.info:SetWidth(190)
  b.b1=smallButton(b,'',96); b.b1:SetPoint('RIGHT',-4,0)
  b.b2=smallButton(b,'',76); b.b2:SetPoint('RIGHT',b.b1,'LEFT',-4,0)
  addHighlight(b)
  return b
end
local pools={}
local function acquire(kind)
  local pool=pools[kind]
  if not pool then pool={used=0}; pools[kind]=pool end
  pool.used=pool.used+1
  local w=pool[pool.used]
  if not w then w=factories[kind](); pool[pool.used]=w end
  w:ClearAllPoints(); w:Show()
  return w
end
function GF.releaseAll()
  for _,pool in pairs(pools) do
    for i=1,#pool do pool[i]:Hide() end
    pool.used=0
  end
end
function GF.toggleTexture(open)
  return open and 'Interface\\Buttons\\UI-MinusButton-Up' or 'Interface\\Buttons\\UI-PlusButton-Up'
end
function GF.showCrafterTooltip(owner,prof,c)
  GameTooltip:SetOwner(owner,'ANCHOR_RIGHT')
  GameTooltip:AddLine(c.character..(c.isMe and ' (You)' or ''),1,.82,0)
  GameTooltip:AddLine(prof..'  '..c.rank..' / '..c.max..'  ('..GF.rankTitle(c.max)..')',1,1,1)
  GameTooltip:AddLine(c.recipeCount..' recipes shared',.8,.8,.8)
  GameTooltip:AddLine(GF.availabilityText(c),1,1,1)
  GameTooltip:AddLine('Data updated '..GF.updatedLabel(c.updated),.6,.6,.6)
  if c.isMe then GameTooltip:AddLine('GuildForge v'..VERSION,.6,.6,.6)
  elseif activeSeen[c.id] then GameTooltip:AddLine('GuildForge '..GF.versionLabel(c.id),.6,.6,.6) end
  GameTooltip:AddLine(' ')
  GameTooltip:AddLine('Click to show only their recipes',.4,.8,1)
  GameTooltip:Show()
end

-- A request on the board, with the buttons that fit who's looking: the poster marks it done or cancels it,
-- a guildmate who knows the recipe takes it, and whoever took it can whisper or give it back.
function GF.setRowButton(b,label,enabled,tip,onClick)
  b:SetText(label); b:Show()
  if enabled then b:Enable() else b:Disable() end
  if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
  b:SetScript('OnClick',function() releaseSearchFocus(); if enabled then onClick(); update() end end)
  b:SetScript('OnEnter',function(self)
    GameTooltip:SetOwner(self,'ANCHOR_RIGHT'); GameTooltip:AddLine(label,1,.82,0); GameTooltip:AddLine(tip,.85,.85,.85,true); GameTooltip:Show()
  end)
  b:SetScript('OnLeave',GameTooltip_Hide)
end
function GF.addRequestRow(ctx,r)
  local b=acquire('request')
  ctx.nextStripe(b.stripe,.045)
  local mine=r.who==key()
  local online=GF.isOnline(r.who)
  GF.setDot(b.dot,online)
  local info=recipeInfo[r.prof] and recipeInfo[r.prof][r.name]
  b.icon:SetTexture(GF.recipeIcon(r.prof,info))
  b.name:SetText((r.qty>1 and ('|cffffffff'..r.qty..'×|r ') or '')..GF.recipeLabel(r.name,info))
  local state=''
  if r.takenBy then state='  ·  |cff8fb8ff'..(r.takenBy==key() and 'you are making it' or (displayName(r.takenBy)..' is on it'))..'|r' end
  b.info:SetText('|cffa0a0a0'..(mine and 'You' or displayName(r.who))..'  ·  '..GF.agoText(now()-r.t)..'|r'..state)
  b.b2:Hide()
  if mine then
    GF.setRowButton(b.b1,'Done',true,'You got it: take it off the board'..(r.takenBy and (' and credit '..displayName(r.takenBy)..' in guild news') or '')..'.',
      function() GF.closeRequest(r.id,true) end)
    GF.setRowButton(b.b2,'Cancel',true,'Take it off the board without it being made.',function() GF.closeRequest(r.id,false) end)
  elseif r.takenBy==key() then
    GF.setRowButton(b.b1,'Whisper',online and ChatFrame_SendTell~=nil,online and 'Start a whisper to '..displayName(r.who)..'.' or displayName(r.who)..' is offline.',
      function() ChatFrame_SendTell(displayName(r.who)) end)
    GF.setRowButton(b.b2,'Give back',true,'Let someone else take it.',function() GF.takeRequest(r,true) end)
  elseif r.takenBy then
    GF.setRowButton(b.b1,'Taken',false,displayName(r.takenBy)..' is making this.',nil)
  else
    local knows=GF.knowsRecipe(r.prof,r.name)
    local why=not knows and "You don't know this recipe." or (not online and displayName(r.who)..' is offline; take it when they are on.')
    GF.setRowButton(b.b1,"I'll make it",not why,why or ('Tell '..displayName(r.who).." you'll make it (whispers them) and mark it taken for the guild."),
      function() GF.takeRequest(r) end)
  end
  b:SetScript('OnEnter',function(self)
    if not GF.showLinkTooltip(self,info and info.link) then GameTooltip:SetOwner(self,'ANCHOR_RIGHT'); GameTooltip:AddLine(r.name,1,.82,0) end
    GameTooltip:AddLine(' ')
    GameTooltip:AddLine((mine and 'You' or displayName(r.who))..' asked for '..r.qty..' ('..r.prof..'), '..GF.agoText(now()-r.t),1,1,1)
    if r.note then GameTooltip:AddLine('"'..r.note..'"',.9,.85,.6,true) end
    GameTooltip:AddLine('Requests close after '..GF.REQUEST_DAYS..' days.',.6,.6,.6)
    GameTooltip:Show()
  end)
  b:SetScript('OnLeave',GameTooltip_Hide)
  b:SetScript('OnClick',function()
    releaseSearchFocus()
    if IsModifiedClick and IsModifiedClick('CHATLINK') then insertChatLink(info and info.link) end
  end)
  ctx.place(b,26,8)
end
function GF.drawRequests(ctx)
  local canMake,making,mine,rest={},{},{},{}
  for _,r in ipairs(GF.allRequests(ctx.term)) do
    if r.who==key() then mine[#mine+1]=r
    elseif r.takenBy==key() then making[#making+1]=r
    elseif not r.takenBy and GF.knowsRecipe(r.prof,r.name) then canMake[#canMake+1]=r
    else rest[#rest+1]=r end
  end
  local function group(id,label,list,empty)
    if #list==0 and not empty then return end
    if ctx.addSection(id,label,#list>0 and tostring(#list) or '') then
      if #list==0 then ctx.addNote(empty,16) end
      for _,r in ipairs(list) do GF.addRequestRow(ctx,r) end
    end
  end
  group('req|can','You can make',canMake)
  group('req|making',"You're making",making)
  group('req|mine','Your requests',mine,'Expand any recipe and click |cffffd100Request|r to ask the guild for it. Guildmates who can make it see it here and in chat.')
  group('req|rest','Other requests',rest)
  headerIcon:SetTexture(professionIcons.Requests)
  headerTitle:SetText('Request Board')
  headerSub:SetText((#canMake+#making+#mine+#rest)..' open  ·  |cff40ff40'..#canMake..' you can make|r  ·  requests close after '..GF.REQUEST_DAYS..' days')
end
-- Guildmates online with GuildForge, you first, with their professions.
function GF.onlineMembers()
  local list={}
  local rosterKnown=next(guildOnline)~=nil
  for who,record in pairs(currentMembers()) do
    local id=nameId(who)
    local isMe=who==key()
    if isMe or (activeSeen[id] and (not rosterKnown or guildOnline[id])) then
      list[#list+1]={who=who,record=record,isMe=isMe,name=isMe and (playerName() or who) or displayName(who)}
    end
  end
  table.sort(list,function(a,b) if a.isMe~=b.isMe then return a.isMe end return a.name<b.name end)
  return list
end
function GF.addLinkCard(ctx,tab,label,info)
  local h=acquire('profHeader')
  h.icon:SetTexture(professionIcons[tab]); h.icon:SetDesaturated(false)
  h.name:SetText(label); h.info:SetText(info)
  h:SetScript('OnClick',function() releaseSearchFocus(); selectTab(tab) end)
  ctx.place(h,36)
  return h
end
-- Cooking, First Aid and Fishing are left out of Home's online list to keep it short.
GF.SECONDARY={Cooking=true,['First Aid']=true,Fishing=true}
function GF.countText(shown,total) return shown==total and tostring(total) or (shown..' of '..total) end
function GF.drawHome(ctx)
  local requests=GF.allRequests()
  local canMake,open,mineOpen={},0,0
  for _,r in ipairs(requests) do
    open=open+1
    if r.who==key() then mineOpen=mineOpen+1
    elseif not r.takenBy and GF.knowsRecipe(r.prof,r.name) then canMake[#canMake+1]=r end
  end
  local entries=shoppingEntries()
  local _,order=GF.shoppingNeeds()
  local missing=0
  for _,n in ipairs(order) do if bagCount(n.reagent)<n.need then missing=missing+1 end end
  GF.addLinkCard(ctx,'Requests','Request Board',open..' open'..(#canMake>0 and ('  |cffa0a0a0·|r  |cff40ff40'..#canMake..' you can make|r') or '')..
    (mineOpen>0 and ('  |cffa0a0a0·|r  '..mineOpen..' yours') or ''))
  GF.addLinkCard(ctx,'Shopping','Shopping List',#entries==0 and '|cffa0a0a0empty|r' or
    (#entries..' recipes  |cffa0a0a0·|r  '..(missing>0 and ('|cffff5a5a'..missing..' materials still needed|r') or '|cff40ff40all gathered|r')))
  if #canMake>0 and ctx.addSection('home|canmake','Requests you can make',tostring(#canMake)) then
    for i=1,math.min(5,#canMake) do GF.addRequestRow(ctx,canMake[i]) end
    if #canMake>5 then ctx.addNote('|cffa0a0a0and '..(#canMake-5)..' more on the Request Board|r',16) end
  end
  local online=GF.onlineMembers()
  if ctx.addSection('home|online','Online with GuildForge',tostring(#online)) then
    for _,m in ipairs(online) do
      local b=acquire('news')
      ctx.nextStripe(b.stripe)
      local profs,first={},nil
      for _,p in ipairs(m.record.professions or {}) do
        if not GF.SECONDARY[p.name] then
          first=first or p.name
          profs[#profs+1]=p.name..' |cffffd100'..p.rank..'|r'
        end
      end
      b.icon:SetTexture(professionIcons[first or ''] or QUESTION_ICON)
      b.text:SetText((m.isMe and '|cff40ff40' or '|cffffffff')..m.name..'|r'..(#profs>0 and ('   |cffa0a0a0'..table.concat(profs,'  ·  ')..'|r') or ''))
      b.when:SetText(m.isMe and '|cff40ff40You|r' or '')
      b:SetScript('OnEnter',nil); b:SetScript('OnLeave',nil); b:SetScript('OnClick',nil)
      ctx.place(b,20,8)
    end
  end
  local cds,ready={},0
  for _,cd in ipairs((GF.gatherCooldowns(nil,''))) do if cd.ready then ready=ready+1; cds[#cds+1]=cd end end
  if ready>0 and ctx.addSection('home|cooldowns','Cooldowns ready',tostring(ready)) then
    for _,cd in ipairs(cds) do ctx.addCooldown(cd) end
  end
  local news=GF.newsList()
  if ctx.addSection('home|news','Guild news',#news>0 and tostring(#news) or '') then
    if #news==0 then
      ctx.addNote('Skill milestones, newly learned recipes and finished requests show up here as guildmates share them.',16)
    end
    for i=#news,math.max(1,#news-29),-1 do
      local e=news[i]
      local b=acquire('news')
      ctx.nextStripe(b.stripe)
      b.icon:SetTexture(professionIcons[e.prof or ''] or QUESTION_ICON)
      b.text:SetText(GF.newsText(e))
      b.when:SetText(GF.agoText(math.max(0,now()-(e.t or 0))))
      local info=e.name and recipeInfo[e.prof or ''] and recipeInfo[e.prof][e.name]
      b:SetScript('OnEnter',function(self) if GF.showLinkTooltip(self,info and info.link) then GameTooltip:Show() end end)
      b:SetScript('OnLeave',GameTooltip_Hide)
      b:SetScript('OnClick',function()
        if IsModifiedClick and IsModifiedClick('CHATLINK') then insertChatLink(info and info.link) end
      end)
      ctx.place(b,20,8)
    end
  end
  local guild=(IsInGuild and IsInGuild()) and GetGuildInfo and GetGuildInfo('player')
  headerIcon:SetTexture(professionIcons.Home)
  headerTitle:SetText(type(guild)=='string' and not isSecret(guild) and guild or 'Guild Home')
  headerSub:SetText(#online..' online with GuildForge  ·  '..open..' open requests  ·  '..ready..' cooldowns ready')
end

update=function()
  if not window or not window:IsShown() then return end
  updatePending=false; sinceUpdate=0
  local term=(searchBox and searchBox:GetText() or ''):lower()
  local searching=term~=''
  GF.releaseAll()
  local y=0
  local stripe=0
  local function place(w,h,x)
    x=x or 0
    w:SetPoint('TOPLEFT',scrollContent,'TOPLEFT',x,-y)
    w:SetWidth(CONTENT_W-x)
    y=y+h
  end
  local function addNote(text,x)
    local n=acquire('note')
    n.text:SetWidth(CONTENT_W-(x or 0)-8)
    n.text:SetText(text)
    local h=math.max(16,math.ceil(n.text:GetStringHeight() or 0)+4)
    n:SetHeight(h)
    place(n,h,x)
  end
  -- Sections start open unless defaultClosed; searching opens everything.
  local function addSection(id,label,extra,defaultClosed)
    local open
    if searching then open=true
    elseif sectionCollapsed[id]==nil then open=not defaultClosed
    else open=not sectionCollapsed[id] end
    local b=acquire('section')
    b.toggle:SetTexture(GF.toggleTexture(open))
    b.label:SetText(label)
    b.extra:SetText(extra or '')
    b:SetScript('OnClick',function()
      releaseSearchFocus()
      sectionCollapsed[id]=open
      update()
    end)
    y=y+4
    place(b,26)
    stripe=0
    return open
  end
  local function nextStripe(texture,alpha)
    stripe=stripe+1
    texture:SetColorTexture(1,1,1,stripe%2==0 and (alpha or .04) or 0)
  end
  local function addCrafter(prof,c,index,clickTabs)
    local b=acquire('crafter')
    nextStripe(b.stripe)
    b.selected:SetShown(selectedCrafter[prof]==c.key)
    GF.setDot(b.dot,c.online)
    b.name:SetText(c.character..(c.isMe and ' |cff40ff40(You)|r' or ''))
    b.bar:SetMinMaxValues(0,math.max(1,c.max))
    b.bar:SetValue(c.rank)
    b.bar:SetStatusBarColor(GF.rankColor(c.rank))
    b.bar.text:SetText(c.rank..' / '..c.max)
    b.recipes:SetText(c.recipeCount>0 and ('|cffffd100'..c.recipeCount..'|r recipes') or '|cff808080no recipes|r')
    b.seen:SetText(c.online and '' or GF.availabilityText(c))
    b:SetScript('OnClick',function()
      releaseSearchFocus()
      selectedCrafter[prof]=(selectedCrafter[prof]~=c.key) and c.key or nil
      if clickTabs then selectTab(prof) else update() end
    end)
    b:SetScript('OnEnter',function(self) GF.showCrafterTooltip(self,prof,c) end)
    b:SetScript('OnLeave',GameTooltip_Hide)
    place(b,20,8)
  end
  local function addCooldown(cd)
    local b=acquire('cooldown')
    nextStripe(b.stripe)
    GF.setDot(b.dot,cd.online)
    b.icon:SetTexture(professionIcons[cd.prof] or QUESTION_ICON)
    b.text:SetText(cd.character..(cd.isMe and ' |cff40ff40(You)|r' or '')..'  |cffa0a0a0-|r  |cffffd100'..cd.name..'|r')
    b.status:SetText(cd.ready and '|cff40ff40Ready|r' or ('|cffffb040Ready in '..GF.durationText(cd.readyAt-now())..'|r'))
    b:SetScript('OnEnter',function(self)
      GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
      GameTooltip:AddLine(cd.name,1,.82,0)
      GameTooltip:AddLine(cd.character..'  ('..cd.prof..')',1,1,1)
      GameTooltip:AddLine('Reported '..GF.updatedLabel(cd.updated),.6,.6,.6)
      GameTooltip:Show()
    end)
    b:SetScript('OnLeave',GameTooltip_Hide)
    b:SetScript('OnClick',nil)
    place(b,20,8)
  end
  local function addCooldownSection(id,prof)
    local list,ready=GF.gatherCooldowns(prof,term)
    if #list==0 then return end
    if addSection(id,'Cooldowns',ready..' of '..#list..' ready') then
      for _,cd in ipairs(list) do addCooldown(cd) end
    end
  end
  -- Not known in guild is a plain list: nobody knows these recipes, so there are no reagents to expand.
  local function addUnknown(prof,r)
    local info=r.info or {}
    local b=acquire('recipe')
    nextStripe(b.stripe,.045)
    b.selected:Hide()
    b.icon:SetTexture(GF.recipeIcon(prof,r.info))
    b.name:SetText(GF.recipeLabel(r.name,r.info))
    local level=info.req and ('Req '..info.req..'  ·  ') or (info.gray and ('Gray at '..info.gray..'  ·  ')) or ''
    b.crafters:SetText('|cff808080'..level..(info.source or 'Trainer')..'|r')
    b.mats:SetText('')
    b:SetScript('OnClick',function()
      releaseSearchFocus()
      if IsModifiedClick and IsModifiedClick('CHATLINK') then insertChatLink(info.link) end
    end)
    b:SetScript('OnEnter',function(self)
      if not GF.showLinkTooltip(self,info.link) then
        GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
        GameTooltip:AddLine(r.name,1,.82,0)
      end
      GameTooltip:AddLine(' ')
      GameTooltip:AddLine('Nobody in the guild knows this yet',1,.5,.3)
      if info.req then GameTooltip:AddLine('Learn it from a trainer at skill '..info.req,.8,.8,.8) end
      GameTooltip:Show()
    end)
    b:SetScript('OnLeave',GameTooltip_Hide)
    place(b,26,8)
  end
  local function addRecipe(prof,r)
    local id=prof..'|'..r.name
    local open=recipeOpen[id]==true
    local b=acquire('recipe')
    nextStripe(b.stripe,.045)
    b.selected:SetShown(open)
    b.icon:SetTexture(GF.recipeIcon(prof,r.info))
    b.name:SetText(GF.recipeLabel(r.name,r.info))
    if #r.crafters>0 then
      local names={}
      for i=1,math.min(2,#r.crafters) do
        local c=r.crafters[i]
        names[#names+1]=c.isMe and '|cff40ff40You|r' or (c.online and ('|cffffffff'..c.character..'|r') or c.character)
      end
      local more=#r.crafters>2 and (' +'..(#r.crafters-2)) or ''
      b.crafters:SetText('|cffa0a0a0'..table.concat(names,', ')..more..'|r')
    else
      local info=r.info or {}
      b.crafters:SetText('|cff808080'..(info.req and ('Req '..info.req..'  ·  ') or '')..(info.source or 'Nobody yet')..'|r')
    end
    b.mats:SetText((r.times or 0)>0 and ('|cff40ff40Mats ready'..(r.times>1 and (' x'..r.times) or '')..'|r') or '')
    b:SetScript('OnClick',function()
      releaseSearchFocus()
      if IsModifiedClick and IsModifiedClick('CHATLINK') then insertChatLink(r.info and r.info.link); return end
      recipeOpen[id]=not open
      update()
    end)
    b:SetScript('OnEnter',function(self)
      if not GF.showLinkTooltip(self,r.info and r.info.link) then
        GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
        GameTooltip:AddLine(r.name,1,.82,0)
      end
      GameTooltip:AddLine(' ')
      if #r.crafters>0 then
        GameTooltip:AddLine('Crafted by '..#r.crafters..' guildmate'..(#r.crafters==1 and '' or 's'),.4,.8,1)
      else
        GameTooltip:AddLine('Nobody in the guild has shared this recipe yet',1,.5,.3)
      end
      GameTooltip:AddLine('Click for reagents, Shift-click to link',.6,.6,.6)
      GameTooltip:Show()
    end)
    b:SetScript('OnLeave',GameTooltip_Hide)
    place(b,26,8)
    if not open then return end
    local reagents=r.info and r.info.reagents
    if reagents and #reagents>0 then
      for _,reagent in ipairs(reagents) do
        local rb=acquire('reagent')
        rb.icon:SetTexture(itemIcon(reagent.id) or QUESTION_ICON)
        rb.name:SetText(reagentName(reagent))
        local bags,bank=bagCount(reagent)
        local need=reagent.n or 1
        local color=bags>=need and '|cff40ff40' or '|cffff5a5a'
        rb.count:SetText(color..bags..' / '..need..'|r'..(bank>0 and ('  |cff8fb8ff(+'..bank..' in bank)|r') or '')..GF.bankText(reagent))
        rb:SetScript('OnEnter',function(self)
          if reagent.id then
            GameTooltip:SetOwner(self,'ANCHOR_RIGHT'); GameTooltip:SetHyperlink('item:'..reagent.id); GameTooltip:Show()
          end
        end)
        rb:SetScript('OnLeave',GameTooltip_Hide)
        rb:SetScript('OnClick',function()
          if reagent.id and IsModifiedClick and IsModifiedClick('CHATLINK') then insertChatLink('i'..reagent.id) end
        end)
        place(rb,19,56)
      end
    else
      addNote('|cff808080Reagents not shared yet. They appear once a crafter on GuildForge '..VERSION..'+ opens this profession and syncs.|r',56)
    end
    if #r.crafters>0 then
      local list={}
      for _,c in ipairs(r.crafters) do
        list[#list+1]=(c.isMe and '|cff40ff40You|r' or (c.online and ('|cffffffff'..c.character..'|r') or ('|cff909090'..c.character..'|r')))..' |cff808080('..c.rank..')|r'
      end
      addNote('|cffffd100Crafted by:|r '..table.concat(list,', '),56)
    end
    local a=acquire('actions')
    local target=GF.craftTarget(r)
    if target then
      a.b1:SetText('Ask '..target.character); a.b1:Enable()
    else
      a.b1:SetText(r.mine and 'You know this' or (#r.crafters>0 and 'No crafter online' or 'No crafter yet')); a.b1:Disable()
    end
    a.b1:SetScript('OnClick',function() releaseSearchFocus(); GF.requestCraft(r,target) end)
    a.b2:SetText('Add to list'); a.b2:Enable(); a.b2:Show()
    a.b2:SetScript('OnClick',function() releaseSearchFocus(); changeShopping(prof,r.name,1); update() end)
    local onList=GuildForgeDB.shopping[GF.shoppingKey(prof,r.name)]
    if r.mine or not craftable[prof] then a.b3:Hide()
    else
      a.b3:SetText('Request'); a.b3:Enable(); a.b3:Show()
      a.b3:SetScript('OnClick',function() releaseSearchFocus(); GF.askRequest(prof,r.name,onList or 1) end)
      a.b3:SetScript('OnEnter',function(self)
        GameTooltip:SetOwner(self,'ANCHOR_RIGHT'); GameTooltip:AddLine('Post to the request board',1,.82,0)
        GameTooltip:AddLine('Guildmates who can make it see it on their Request Board and in chat, even when nobody is online right now.',.85,.85,.85,true)
        GameTooltip:Show()
      end)
      a.b3:SetScript('OnLeave',GameTooltip_Hide)
    end
    a.text:SetText(onList and ('On your shopping list: '..onList) or '')
    place(a,28,56)
    -- Guild bank: ask for what your bags are missing, for as many as are on your shopping list (or one),
    -- or have it mailed straight to the crafter as a craft order.
    if reagents and #reagents>0 and GF.bankAPI() then
      local qty=onList or 1
      local items=GF.bankMissing(GF.recipeNeeds(r.info,qty))
      local full=not items and 'Your bags already hold the materials'..(qty>1 and (' for '..qty) or '')
      local ba=acquire('bankActions')
      GF.setBankButton(ba.b1,'Get mats from guild bank',items,full,function() GF.bankRequest(items,'for '..qty..'× '..r.name); update() end)
      if r.mine then ba.b2:Hide()
      else
        GF.setBankButton(ba.b2,'Craft order via guild bank',items,full or (not target and 'No crafter online to take the order'),
          function() GF.craftOrder(r,target,qty); update() end)
      end
      ba.text:SetText(qty>1 and ('For '..qty..', from your shopping list') or '')
      place(ba,28,56)
    end
    y=y+4
  end

  local ctx={place=place,addNote=addNote,addSection=addSection,nextStripe=nextStripe,addCooldown=addCooldown,term=term}
  local selected=selectedTab
  -- Searching from Home searches everything, like the All tab.
  if selected=='Home' and searching then selected='All' end
  if selected=='Home' then GF.drawHome(ctx)
  elseif selected=='Requests' then GF.drawRequests(ctx)
  elseif selected=='All' then
    local totalCrafters,totalRecipes=0,0
    addCooldownSection('all|cooldowns',nil)
    local any=false
    local overview=not searching and GF.professionOverview()
    for _,prof in ipairs(professions) do
      local d=overview and overview[prof] or GF.professionData(prof,term)
      totalCrafters=totalCrafters+d.crafterCount; totalRecipes=totalRecipes+d.recipeCount
      local profMatch=searching and found(prof,term)
      if not searching or profMatch or #d.fc>0 or #d.fr>0 then
        any=true
        local h=acquire('profHeader')
        h.icon:SetTexture(professionIcons[prof])
        h.name:SetText(prof)
        local info=d.crafterCount..' crafters'
        if d.recipeCount>0 then info=info..'  |cffa0a0a0·|r  '..d.recipeCount..' recipes' end
        if d.top then info=info..'  |cffa0a0a0·|r  Top: |cffffd100'..d.top.character..'|r ('..d.top.rank..')' end
        h.info:SetText(info)
        h.icon:SetDesaturated(d.crafterCount==0)
        h:SetScript('OnClick',function() releaseSearchFocus(); selectTab(prof) end)
        y=y+2
        place(h,34)
        if searching then
          stripe=0
          for i,c in ipairs(d.fc) do addCrafter(prof,c,i,true) end
          stripe=0
          for _,r in ipairs(d.fr) do addRecipe(prof,r) end
          y=y+6
        end
      end
    end
    if not any then addNote('No matching professions, guild members, recipes, or reagents.',8) end
    headerIcon:SetTexture(professionIcons.All)
    headerTitle:SetText('Guild Professions')
    headerSub:SetText(string.format('%d crafter entries  ·  %d recipes shared  ·  %d online with GuildForge',totalCrafters,totalRecipes,#activeUsers()))
  elseif selected=='Shopping' then
    local entries={}
    for _,e in ipairs(shoppingEntries()) do
      if not searching or found(e.name,term) or found(e.prof,term) then entries[#entries+1]=e end
    end
    if addSection('shop|recipes','Recipes to craft',#entries..' recipes') then
      if #entries==0 then addNote('Your shopping list is empty. Expand any recipe and click "Add to list".',16) end
      for _,e in ipairs(entries) do
        local b=acquire('shopItem')
        nextStripe(b.stripe,.045)
        b.icon:SetTexture(GF.recipeIcon(e.prof,e.info))
        b.name:SetText(GF.recipeLabel(e.name,e.info))
        b.prof:SetText(e.prof)
        local times=craftableTimes(e.info)
        b.status:SetText(times==nil and '|cff808080Reagents unknown|r' or (times>=e.qty and '|cff40ff40Mats ready|r' or '|cffff5a5aMissing mats|r'))
        b.qty:SetText('x'..e.qty)
        b.minus:SetScript('OnClick',function() changeShopping(e.prof,e.name,-1); update() end)
        b.plus:SetScript('OnClick',function() changeShopping(e.prof,e.name,1); update() end)
        b.remove:SetScript('OnClick',function() changeShopping(e.prof,e.name,-e.qty); update() end)
        b:SetScript('OnEnter',function(self) if GF.showLinkTooltip(self,e.info and e.info.link) then GameTooltip:Show() end end)
        b:SetScript('OnLeave',GameTooltip_Hide)
        b:SetScript('OnClick',function()
          if IsModifiedClick and IsModifiedClick('CHATLINK') then insertChatLink(e.info and e.info.link) end
        end)
        place(b,26,8)
      end
    end
    local _,order=GF.shoppingNeeds()
    local missing=0
    for _,n in ipairs(order) do if bagCount(n.reagent)<n.need then missing=missing+1 end end
    if addSection('shop|mats','Materials',missing==0 and (#order>0 and '|cff40ff40All gathered|r' or '') or ('|cffff5a5a'..missing..' still needed|r')) then
      if #order==0 then addNote('Materials for the recipes on your list will appear here.',16) end
      for _,n in ipairs(order) do
        local reagent=n.reagent
        local rb=acquire('reagent')
        rb.icon:SetTexture(itemIcon(reagent.id) or QUESTION_ICON)
        rb.name:SetText(reagentName(reagent))
        local bags,bank=bagCount(reagent)
        local text
        if bags>=n.need then text='|cff40ff40'..bags..' / '..n.need..'  done|r'
        else text='|cffff5a5a'..bags..' / '..n.need..'  need '..(n.need-bags)..' more|r' end
        if bank>0 then text=text..'  |cff8fb8ff(+'..bank..' in bank)|r' end
        rb.count:SetText(text..GF.bankText(reagent))
        rb:SetScript('OnEnter',function(self)
          if reagent.id then GameTooltip:SetOwner(self,'ANCHOR_RIGHT'); GameTooltip:SetHyperlink('item:'..reagent.id); GameTooltip:Show() end
        end)
        rb:SetScript('OnLeave',GameTooltip_Hide)
        rb:SetScript('OnClick',function()
          if reagent.id and IsModifiedClick and IsModifiedClick('CHATLINK') then insertChatLink('i'..reagent.id) end
        end)
        place(rb,19,24)
      end
    end
    if #order>0 and GF.bankAPI() then
      y=y+6
      local items=GF.bankMissing(order)
      local names={}
      for _,e in ipairs(shoppingEntries()) do names[#names+1]=e.qty..'× '..e.name end
      local note='for '..table.concat(names,', ')
      if #note>100 then note='for '..#names..' recipes on my shopping list' end
      local ba=acquire('bankActions')
      GF.setBankButton(ba.b1,'Get mats from guild bank',items,not items and 'Your bags already hold everything on the list',
        function() GF.bankRequest(items,note); update() end)
      ba.b2:Hide(); ba.text:SetText('Asks for everything still needed')
      place(ba,28,8)
    end
    if #shoppingEntries()>0 then
      y=y+6
      local a=acquire('actions')
      a.b1:SetText('Clear list'); a.b1:Enable()
      a.b1:SetScript('OnClick',function() releaseSearchFocus(); wipe(GuildForgeDB.shopping); requestUpdate(); update() end)
      a.b2:Hide(); a.b3:Hide()
      a.text:SetText('Item tooltips also show what you still need.')
      place(a,28,8)
    end
    headerIcon:SetTexture(professionIcons.Shopping)
    headerTitle:SetText('Shopping List')
    headerSub:SetText(#shoppingEntries()..' recipes  ·  '..#order..' materials  ·  '..(missing>0 and ('|cffff5a5a'..missing..' still needed|r') or '|cff40ff40nothing missing|r'))
  else
    local prof=selected
    local d=GF.professionData(prof,term)
    if addSection(prof..'|crafters','Crafters',GF.countText(#d.fc,#d.crafters)) then
      if #d.fc==0 then addNote('No guildmates have shared '..prof..' yet.',16) end
      for i,c in ipairs(d.fc) do addCrafter(prof,c,i,false) end
    end
    addCooldownSection(prof..'|cooldowns',prof)
    if craftable[prof] or #d.recipes>0 then
      local extra=GF.countText(#d.fr,#d.recipes)
      if d.filterName then extra='|cffffd100'..d.filterName..'|r only  ·  '..extra end
      if addSection(prof..'|recipes','Recipes',extra) then
        if #d.fr==0 then
          addNote(#d.recipes==0 and 'No recipes shared yet. Open the profession window on a character that knows it.' or 'No recipes match the current filters.',16)
        end
        for _,r in ipairs(d.fr) do addRecipe(prof,r) end
      end
    end
    if craftable[prof] and not d.filter then
      if addSection(prof..'|unknown','Not known in guild',GF.countText(#d.unknown,d.unknownTotal),true) then
        if d.unknownTotal==0 then
          addNote('Visit a '..prof..' trainer (or open the profession on Forever) to list recipes nobody in the guild knows yet.',16)
        end
        for _,r in ipairs(d.unknown) do addUnknown(prof,r) end
      end
    end
    headerIcon:SetTexture(professionIcons[prof])
    headerTitle:SetText(prof)
    local sub=#d.crafters..' crafters  ·  '..#d.recipes..' recipes'
    if craftable[prof] and d.ready>0 then sub=sub..'  ·  |cff40ff40'..d.ready..' you can craft now|r' end
    if d.filterName then sub=sub..'  ·  showing |cffffd100'..d.filterName..'|r (click again to clear)' end
    headerSub:SetText(sub)
  end
  scrollContent:SetHeight(math.max(100,y+10))
  for _,t in ipairs(tabs) do
    t:SetChecked(t.name==selectedTab)
    if not specialTabs[t.name] then t:GetNormalTexture():SetDesaturated(not GF.hasProfession(t.name)) end
  end
  local guild=(IsInGuild and IsInGuild()) and (GetGuildInfo and GetGuildInfo('player') or 'In guild') or 'Not in guild'
  local queued=GF.queuedCount()>0 and ('  |cffa0a0a0·  sharing '..GF.queuedCount()..' messages|r') or ''
  status:SetText('|cffffd100'..guild..'|r'..queued)
end

selectTab=function(name)
  selectedTab=name
  if GuildForgeDB then GuildForgeDB.ui.tab=name end
  if scrollFrame then scrollFrame:SetVerticalScroll(0) end
  update()
end

local function makeTab(index,name)
  local t=CreateFrame('CheckButton',nil,window)
  t.name=name
  t:SetSize(32,32)
  t:SetPoint('TOPLEFT',window,'TOPRIGHT',-6,-26-(index-1)*32)
  local bg=t:CreateTexture(nil,'BACKGROUND')
  bg:SetTexture('Interface\\SpellBook\\SpellBook-SkillLineTab'); bg:SetSize(64,64); bg:SetPoint('TOPLEFT',-3,11)
  t:SetNormalTexture(professionIcons[name])
  t:SetHighlightTexture('Interface\\Buttons\\ButtonHilight-Square','ADD')
  t:SetCheckedTexture('Interface\\Buttons\\CheckButtonHilight')
  t:GetCheckedTexture():SetBlendMode('ADD')
  -- A search left in the box would turn Home and All into search results, so a new tab starts clear.
  t:SetScript('OnClick',function()
    releaseSearchFocus()
    if searchBox and searchBox:GetText()~='' then searchBox:SetText('') end
    selectTab(name)
  end)
  t:SetScript('OnEnter',function(self)
    GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
    GameTooltip:AddLine(specialTabs[name] or name,1,.82,0)
    if name=='Requests' then
      local n=GF.requestsYouCanMake()
      GameTooltip:AddLine(n>0 and (n..' you can make') or 'What guildmates need crafted',.85,.85,.85)
    end
    if not specialTabs[name] and not GF.hasProfession(name) then GameTooltip:AddLine('No guildmates recorded yet',.6,.6,.6) end
    GameTooltip:Show()
  end)
  t:SetScript('OnLeave',GameTooltip_Hide)
  tabs[#tabs+1]=t
end

local function setScale(value)
  value=math.max(.7,math.min(1.4,math.floor(value*20+.5)/20))
  GuildForgeDB.settings.scale=value
  if window then window:SetScale(value) end
  return value
end
function GF.makeSettingsPanel(f,inset)
  local panel=CreateFrame('Frame',nil,f,BACKDROP_TEMPLATE)
  panel:SetPoint('TOPLEFT',inset,'TOPLEFT'); panel:SetPoint('BOTTOMRIGHT',inset,'BOTTOMRIGHT')
  -- A higher strata keeps list rows from drawing through the panel when the window is raised or rows are rebuilt.
  panel:SetFrameStrata('FULLSCREEN_DIALOG'); skin(panel,1)
  local backing=panel:CreateTexture(nil,'BACKGROUND',nil,-8)
  backing:SetPoint('TOPLEFT',3,-3); backing:SetPoint('BOTTOMRIGHT',-3,3); backing:SetColorTexture(.07,.05,.035,1)
  panel:EnableMouse(true); panel:Hide()
  -- Swallow the wheel so the list underneath doesn't scroll while settings are open.
  panel:EnableMouseWheel(true); panel:SetScript('OnMouseWheel',function() end)
  local title=panel:CreateFontString(nil,'OVERLAY','GameFontNormalLarge'); title:SetPoint('TOPLEFT',18,-16); title:SetText('Settings')
  local y=-50
  local checks={}
  local function check(label,hint,get,set)
    local c=CreateFrame('CheckButton',nil,panel,'UICheckButtonTemplate')
    c:SetSize(26,26); c:SetPoint('TOPLEFT',16,y)
    local text=panel:CreateFontString(nil,'OVERLAY','GameFontHighlight'); text:SetPoint('LEFT',c,'RIGHT',4,1); text:SetText(label)
    local sub=panel:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); sub:SetPoint('TOPLEFT',text,'BOTTOMLEFT',0,-2); sub:SetText(hint)
    c.get=get
    c:SetScript('OnClick',function(self) set(self:GetChecked() and true or false); requestUpdate() end)
    checks[#checks+1]=c
    y=y-44
  end
  check('Show minimap button','Left-click opens GuildForge, right-click syncs. Also /guildforge minimap.',
    function() return not GuildForgeDB.minimap.hide end,
    function(v) GuildForgeDB.minimap.hide=not v; if minimapButton then minimapButton:SetShown(v) end end)
  check('Show GuildForge info in item tooltips','Who crafts an item, which recipes use it, and shopping-list needs.',
    function() return GuildForgeDB.settings.tooltips end,
    function(v) GuildForgeDB.settings.tooltips=v end)
  check('Sync with the guild when you log in','Sends your professions and asks guildmates for changed recipe lists.',
    function() return GuildForgeDB.settings.syncOnLogin end,
    function(v) GuildForgeDB.settings.syncOnLogin=v end)
  check('Quiet mode','Hide routine chat messages such as scans and sync notices.',
    function() return GuildForgeDB.settings.quiet end,
    function(v) GuildForgeDB.settings.quiet=v end)

  local scaleLabel=panel:CreateFontString(nil,'OVERLAY','GameFontHighlight'); scaleLabel:SetPoint('TOPLEFT',22,y-6); scaleLabel:SetText('Window scale')
  local minus=smallButton(panel,'-',26); minus:SetPoint('LEFT',scaleLabel,'RIGHT',14,0)
  local value=panel:CreateFontString(nil,'OVERLAY','GameFontNormal'); value:SetPoint('LEFT',minus,'RIGHT',8,0); value:SetWidth(44)
  local plus=smallButton(panel,'+',26); plus:SetPoint('LEFT',value,'RIGHT',8,0)
  local function showScale() value:SetText(math.floor(GuildForgeDB.settings.scale*100+.5)..'%') end
  minus:SetScript('OnClick',function() setScale(GuildForgeDB.settings.scale-.05); showScale() end)
  plus:SetScript('OnClick',function() setScale(GuildForgeDB.settings.scale+.05); showScale() end)
  y=y-48

  local push=smallButton(panel,'Re-share all my recipes',180); push:SetPoint('TOPLEFT',22,y)
  push:SetScript('OnClick',GF.doPush)
  local pushHint=panel:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); pushHint:SetPoint('LEFT',push,'RIGHT',10,0)
  pushHint:SetText('Normal syncs only send lists that changed; use this if someone is missing yours.')
  y=y-36
  local clear=smallButton(panel,'Clear my data',180); clear:SetPoint('TOPLEFT',22,y)
  clear:SetScript('OnClick',function() StaticPopup_Show('GUILDFORGE_CLEAR') end)
  local clearHint=panel:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); clearHint:SetPoint('LEFT',clear,'RIGHT',10,0)
  clearHint:SetText('Forget what you have received from guildmates and download it again fresh.')
  y=y-36
  local logButton=smallButton(panel,'Message log',180); logButton:SetPoint('TOPLEFT',22,y)
  logButton:SetScript('OnClick',function() GF.openLog() end)
  local logHint=panel:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); logHint:SetPoint('LEFT',logButton,'RIGHT',10,0)
  logHint:SetText('Every GuildForge message as it is sent and received, with a copy button for bug reports.')
  local done=smallButton(panel,'Done',90); done:SetPoint('BOTTOMRIGHT',-16,14)
  local version=panel:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); version:SetPoint('BOTTOMLEFT',22,20)
  version:SetText('GuildForge v'..VERSION)
  done:SetScript('OnClick',function() panel:Hide() end)
  panel:SetScript('OnShow',function()
    for _,c in ipairs(checks) do c:SetChecked(c.get()) end
    showScale()
  end)
  return panel
end

-- Message log: a header for bug reports, then every line GF.note kept.
function GF.logReport()
  local iface=GetBuildInfo and select(4,GetBuildInfo())
  local lines={'GuildForge v'..VERSION..' message log, '..((date and date('%Y-%m-%d %H:%M')) or ''),
    string.format('client: %s (interface %s); you: %s; guild: %s',GF.forever and 'WoW Forever' or 'Classic Era',GF.plainText(iface),key(),GF.plainText(GF.guildBucketKey())),
    string.format('messages sent: %d; recipe messages sent: %d; syncs received: %d; queued: %d; held: %s',sent,recipeSent,received,GF.queuedCount(),tostring(GF.held==true)),
    ''}
  for _,line in ipairs(GF.trace) do lines[#lines+1]=line end
  return table.concat(lines,'\n')
end
-- WoW reads '|' in text as a formatting code, so the window shows it as '¦'.
function GF.logText(text) return (text:gsub('|','¦')) end
function GF.openLog()
  local f=GF.logWindow
  if not f then
    f=CreateFrame('Frame','GuildForgeLogWindow',UIParent,BACKDROP_TEMPLATE)
    GF.logWindow=f
    f.since,f.stick,f.copying,f.text=0,false,false,''
    f:SetSize(660,440); f:SetPoint('CENTER',60,-30); f:SetFrameStrata('DIALOG'); f:SetToplevel(true)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag('LeftButton'); f:SetClampedToScreen(true)
    f:SetScript('OnDragStart',f.StartMoving); f:SetScript('OnDragStop',f.StopMovingOrSizing)
    if f.SetBackdrop then
      f:SetBackdrop({bgFile='Interface\\DialogFrame\\UI-DialogBox-Background',edgeFile='Interface\\DialogFrame\\UI-DialogBox-Border',tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
    end
    local backing=f:CreateTexture(nil,'BACKGROUND',nil,-8)
    backing:SetPoint('TOPLEFT',11,-12); backing:SetPoint('BOTTOMRIGHT',-12,11); backing:SetColorTexture(.07,.05,.035,1)
    tinsert(UISpecialFrames,'GuildForgeLogWindow')
    local title=f:CreateFontString(nil,'OVERLAY','GameFontNormalLarge'); title:SetPoint('TOPLEFT',24,-22); title:SetText('GuildForge Message Log')
    local sub=f:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); sub:SetPoint('LEFT',title,'RIGHT',12,-1)
    sub:SetText('Live: everything GuildForge sends and receives. ¦ stands for |.')
    local close=CreateFrame('Button',nil,f,'UIPanelCloseButton'); close:SetPoint('TOPRIGHT',-6,-6)
    local scroll=CreateFrame('ScrollFrame','GuildForgeLogScroll',f,'UIPanelScrollFrameTemplate')
    scroll:SetPoint('TOPLEFT',24,-52); scroll:SetPoint('BOTTOMRIGHT',-42,52)
    local edit=CreateFrame('EditBox',nil,scroll)
    edit:SetMultiLine(true); edit:SetAutoFocus(false); edit:SetFontObject(ChatFontNormal); edit:SetWidth(590)
    edit:SetScript('OnEscapePressed',function(self) self:ClearFocus() end)
    -- Read-only: anything typed is put back.
    edit:SetScript('OnTextChanged',function(self,userInput) if userInput then self:SetText(f.text or '') end end)
    -- Leaving the copy view goes back to the live log.
    edit:SetScript('OnEditFocusLost',function() if f.copying then f.copying=false; f.hint:SetText(''); GF.logDirty=true end end)
    scroll:SetScrollChild(edit)
    local copy=smallButton(f,'Copy',100); copy:SetPoint('BOTTOMLEFT',24,20)
    copy:SetScript('OnClick',function()
      f.copying=true
      f.text='```\n'..GF.logText(GF.logReport())..'\n```'
      edit:SetText(f.text); edit:SetFocus(); edit:HighlightText()
      f.hint:SetText('Press Ctrl+C (Cmd+C on a Mac) to copy, then paste it into Discord or a GitHub issue.')
    end)
    local clear=smallButton(f,'Clear',80); clear:SetPoint('LEFT',copy,'RIGHT',8,0)
    clear:SetScript('OnClick',function() wipe(GF.trace); f.copying=false; f.hint:SetText(''); GF.logDirty=true end)
    f.hint=f:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall'); f.hint:SetPoint('LEFT',clear,'RIGHT',12,0)
    f:SetScript('OnUpdate',function(self,elapsed)
      if self.stick then self.stick=nil; scroll:SetVerticalScroll(scroll:GetVerticalScrollRange() or 0) end
      self.since=self.since+elapsed
      if self.copying or not GF.logDirty or self.since<0.25 then return end
      self.since=0; GF.logDirty=false
      -- Follow new lines while scrolled to the bottom; stay put while reading further up.
      self.stick=(scroll:GetVerticalScroll() or 0)>=(scroll:GetVerticalScrollRange() or 0)-4
      self.text=GF.logText(table.concat(GF.trace,'\n'))
      edit:SetText(self.text)
    end)
  end
  GF.logDirty=true; f.copying=false; f.hint:SetText('')
  f:Show()
end

local function makeWindow()
  local f=CreateFrame('Frame','GuildForgeWindow',UIParent,BACKDROP_TEMPLATE)
  window=f
  f:SetSize(720,560); f:SetPoint('CENTER'); f:SetFrameStrata('DIALOG'); f:SetToplevel(true)
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag('LeftButton'); f:SetClampedToScreen(true)
  f:SetScript('OnDragStart',f.StartMoving); f:SetScript('OnDragStop',f.StopMovingOrSizing)
  f:SetScale(GuildForgeDB.settings.scale or 1)
  if f.SetBackdrop then
    f:SetBackdrop({bgFile='Interface\\DialogFrame\\UI-DialogBox-Background',edgeFile='Interface\\DialogFrame\\UI-DialogBox-Border',tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
  end
  local tint=f:CreateTexture(nil,'BACKGROUND',nil,1)
  tint:SetPoint('TOPLEFT',11,-12); tint:SetPoint('BOTTOMRIGHT',-12,11); tint:SetColorTexture(.16,.11,.06,.55)
  tinsert(UISpecialFrames,'GuildForgeWindow')

  local banner=f:CreateTexture(nil,'ARTWORK')
  banner:SetTexture('Interface\\DialogFrame\\UI-DialogBox-Header'); banner:SetSize(320,64); banner:SetPoint('TOP',0,12)
  local title=f:CreateFontString(nil,'OVERLAY','GameFontNormal')
  title:SetPoint('TOP',banner,'TOP',0,-14); title:SetText('GuildForge')
  local close=CreateFrame('Button',nil,f,'UIPanelCloseButton')
  close:SetPoint('TOPRIGHT',-6,-6)

  local function button(label,width,anchor,fn)
    local b=CreateFrame('Button',nil,f,'UIPanelButtonTemplate')
    b:SetSize(width,22); b:SetPoint(unpack(anchor)); b:SetText(label)
    b:SetScript('OnClick',function(...) releaseSearchFocus(); fn(...) end)
    return b
  end
  local sync=button('Sync',70,{'TOPLEFT',22,-36},GF.syncNow)
  sync:SetScript('OnEnter',function(self)
    GameTooltip:SetOwner(self,'ANCHOR_RIGHT'); GameTooltip:AddLine('Sync',1,.82,0)
    GameTooltip:AddLine('Share your professions and ask the guild for anything new. This also happens on its own when you log in.',.85,.85,.85,true)
    GameTooltip:Show()
  end)
  sync:SetScript('OnLeave',GameTooltip_Hide)
  local gear=CreateFrame('Button',nil,f)
  gear:SetSize(22,22); gear:SetPoint('LEFT',sync,'RIGHT',8,0)
  gear:SetNormalTexture('Interface\\Icons\\INV_Misc_Gear_01')
  gear:SetHighlightTexture('Interface\\Buttons\\ButtonHilight-Square','ADD')
  gear:SetScript('OnEnter',function(self) GameTooltip:SetOwner(self,'ANCHOR_RIGHT'); GameTooltip:AddLine('Settings',1,.82,0); GameTooltip:Show() end)
  gear:SetScript('OnLeave',GameTooltip_Hide)

  searchBox=CreateFrame('EditBox',nil,f,'InputBoxTemplate')
  searchBox:SetSize(220,20); searchBox:SetPoint('TOPRIGHT',-148,-37); searchBox:SetAutoFocus(false)
  local searchIcon=searchBox:CreateTexture(nil,'OVERLAY')
  searchIcon:SetTexture('Interface\\Common\\UI-Searchbox-Icon'); searchIcon:SetSize(14,14); searchIcon:SetPoint('RIGHT',-4,-1); searchIcon:SetVertexColor(.7,.7,.7)
  local placeholder=searchBox:CreateFontString(nil,'OVERLAY','GameFontDisableSmall')
  placeholder:SetPoint('LEFT',2,0); placeholder:SetText('Search recipes, crafters, reagents...')
  local function syncPlaceholder(self) placeholder:SetShown(self:GetText()=='' and not self:HasFocus()) end
  searchBox:SetScript('OnTextChanged',function(self) syncPlaceholder(self); update() end)
  searchBox:SetScript('OnEscapePressed',function(self) self:ClearFocus() end)
  searchBox:SetScript('OnEnterPressed',function(self) self:ClearFocus() end)
  searchBox:SetScript('OnEditFocusGained',syncPlaceholder)
  searchBox:SetScript('OnEditFocusLost',function(self) self:HighlightText(0,0); syncPlaceholder(self) end)

  matsCheck=CreateFrame('CheckButton',nil,f,'UICheckButtonTemplate')
  matsCheck:SetSize(24,24); matsCheck:SetPoint('LEFT',searchBox,'RIGHT',8,0)
  matsCheck:SetChecked(GuildForgeDB.ui.matsOnly)
  local matsLabel=f:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
  matsLabel:SetPoint('LEFT',matsCheck,'RIGHT',0,1); matsLabel:SetText('Have mats')
  matsCheck:SetScript('OnClick',function(self) releaseSearchFocus(); GuildForgeDB.ui.matsOnly=self:GetChecked() and true or false; update() end)
  matsCheck:SetScript('OnEnter',function(self)
    GameTooltip:SetOwner(self,'ANCHOR_RIGHT'); GameTooltip:AddLine('Only show recipes you have the reagents for in your bags',1,1,1,true); GameTooltip:Show()
  end)
  matsCheck:SetScript('OnLeave',GameTooltip_Hide)

  local header=CreateFrame('Frame',nil,f,BACKDROP_TEMPLATE)
  header:SetPoint('TOPLEFT',16,-64); header:SetPoint('TOPRIGHT',-16,-64); header:SetHeight(40)
  headerIcon=header:CreateTexture(nil,'ARTWORK'); headerIcon:SetSize(32,32); headerIcon:SetPoint('LEFT',6,0); headerIcon:SetTexCoord(.07,.93,.07,.93)
  headerTitle=header:CreateFontString(nil,'OVERLAY','GameFontNormalLarge'); headerTitle:SetPoint('TOPLEFT',headerIcon,'TOPRIGHT',10,-2)
  headerSub=header:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall'); headerSub:SetPoint('BOTTOMLEFT',headerIcon,'BOTTOMRIGHT',10,3)

  local inset=CreateFrame('Frame',nil,f,BACKDROP_TEMPLATE)
  inset:SetPoint('TOPLEFT',16,-108); inset:SetPoint('BOTTOMRIGHT',-16,34); skin(inset,.75,.55,.45,.28)
  scrollFrame=CreateFrame('ScrollFrame','GuildForgeScrollFrame',inset,'UIPanelScrollFrameTemplate')
  scrollFrame:SetPoint('TOPLEFT',8,-8); scrollFrame:SetPoint('BOTTOMRIGHT',-30,8)
  scrollFrame:SetScript('OnMouseDown',releaseSearchFocus)
  scrollContent=CreateFrame('Frame',nil,scrollFrame); scrollContent:SetSize(CONTENT_W,100)
  scrollContent:EnableMouse(true); scrollContent:SetScript('OnMouseDown',releaseSearchFocus)
  scrollFrame:SetScrollChild(scrollContent)

  f.settingsPanel=GF.makeSettingsPanel(f,inset)
  gear:SetScript('OnClick',function() releaseSearchFocus(); f.settingsPanel:SetShown(not f.settingsPanel:IsShown()) end)

  status=f:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall'); status:SetPoint('BOTTOMLEFT',22,16)

  makeTab(1,'Home')
  makeTab(2,'All')
  for i,prof in ipairs(professions) do makeTab(i+2,prof) end
  makeTab(#professions+3,'Shopping')
  makeTab(#professions+4,'Requests')

  f:SetScript('OnMouseDown',releaseSearchFocus)
  f:SetScript('OnHide',releaseSearchFocus)
  if WorldFrame and WorldFrame.HookScript then
    WorldFrame:HookScript('OnMouseDown',releaseSearchFocus)
  end
  f:Hide()
end
local function toggle()
  if not window then makeWindow() end
  if window:IsShown() then window:Hide() else save(); window:Show(); update() end
end
local function openSettings()
  if not window then makeWindow() end
  if not window:IsShown() then save(); window:Show(); update() end
  window.settingsPanel:Show()
end
-- Esc > Options > AddOns entry on clients with the modern Settings panel (WoW: Forever).
function GF.registerOptions()
  if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
  local panel=CreateFrame('Frame')
  local title=panel:CreateFontString(nil,'OVERLAY','GameFontNormalLarge'); title:SetPoint('TOPLEFT',16,-16); title:SetText('GuildForge')
  local text=panel:CreateFontString(nil,'OVERLAY','GameFontHighlight'); text:SetPoint('TOPLEFT',title,'BOTTOMLEFT',0,-8)
  text:SetText('Settings live in the GuildForge window. You can also use the GF minimap button or /guildforge.')
  local open=CreateFrame('Button',nil,panel,'UIPanelButtonTemplate')
  open:SetSize(200,24); open:SetPoint('TOPLEFT',text,'BOTTOMLEFT',0,-12); open:SetText('Open GuildForge settings')
  open:SetScript('OnClick',function()
    if SettingsPanel and HideUIPanel then HideUIPanel(SettingsPanel) end
    openSettings()
  end)
  Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel,'GuildForge'))
end

-- Minimap button: a "GF" bubble with a badge counting guildmates online with GuildForge.
-- It sits on the same ring as LibDBIcon buttons (most addons' minimap buttons) and follows
-- square minimaps. Which quarters of the minimap are round, per shape (LibDBIcon's table):
GF.minimapShapes={
  ROUND={true,true,true,true}, SQUARE={false,false,false,false},
  ['CORNER-TOPLEFT']={false,false,false,true}, ['CORNER-TOPRIGHT']={false,false,true,false},
  ['CORNER-BOTTOMLEFT']={false,true,false,false}, ['CORNER-BOTTOMRIGHT']={true,false,false,false},
  ['SIDE-LEFT']={false,true,false,true}, ['SIDE-RIGHT']={true,false,true,false},
  ['SIDE-TOP']={false,false,true,true}, ['SIDE-BOTTOM']={true,true,false,false},
  ['TRICORNER-TOPLEFT']={false,true,true,true}, ['TRICORNER-TOPRIGHT']={true,false,true,true},
  ['TRICORNER-BOTTOMLEFT']={true,true,false,true}, ['TRICORNER-BOTTOMRIGHT']={true,true,true,false},
}
function GF.minimapOffset(degrees)
  local angle=math.rad(degrees or 200)
  local x,y=math.cos(angle),math.sin(angle)
  local q=1
  if x<0 then q=q+1 end
  if y>0 then q=q+2 end
  local shape=GetMinimapShape and GetMinimapShape() or 'ROUND'
  local round=(GF.minimapShapes[shape] or GF.minimapShapes.ROUND)[q]
  local w,h=Minimap:GetWidth()/2+5,Minimap:GetHeight()/2+5
  if round then return x*w,y*h end
  local dw,dh=math.sqrt(2*w*w)-10,math.sqrt(2*h*h)-10
  return math.max(-w,math.min(x*dw,w)),math.max(-h,math.min(y*dh,h))
end
local function positionMinimap()
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint('CENTER',Minimap,'CENTER',GF.minimapOffset(GuildForgeDB.minimap.angle))
end
local function showMinimapTooltip(self)
  GameTooltip:SetOwner(self,'ANCHOR_LEFT')
  GameTooltip:AddLine('GuildForge',1,.82,0)
  local users=activeUsers(true)
  GameTooltip:AddLine(#users..' online with GuildForge',1,1,1)
  for i=1,math.min(#users,15) do GameTooltip:AddLine('   '..users[i],.55,.9,.55) end
  if #users>15 then GameTooltip:AddLine('   and '..(#users-15)..' more',.6,.6,.6) end
  local _,ready=GF.gatherCooldowns(nil,'')
  if ready>0 then GameTooltip:AddLine(ready..' profession cooldown'..(ready==1 and '' or 's')..' ready',.4,1,.4) end
  local canMake=GF.requestsYouCanMake()
  if canMake>0 then GameTooltip:AddLine(canMake..' request'..(canMake==1 and '' or 's')..' you can make',.4,1,.4) end
  GameTooltip:AddLine(' ')
  GameTooltip:AddLine('|cffffd100Left-click|r  open GuildForge',.85,.85,.85)
  GameTooltip:AddLine('|cffffd100Right-click|r  sync with guild',.85,.85,.85)
  GameTooltip:AddLine('|cffffd100Drag|r  move this button',.85,.85,.85)
  GameTooltip:Show()
end
refreshMinimap=function()
  if not minimapButton then return end
  minimapButton.count:SetText(#activeUsers())
  if GameTooltip:IsOwned(minimapButton) then showMinimapTooltip(minimapButton) end
end
function GF.makeMinimapButton()
  local b=CreateFrame('Button','GuildForgeMinimapButton',Minimap)
  minimapButton=b
  b:SetSize(31,31); b:SetFrameStrata('MEDIUM'); b:SetFrameLevel(8)
  b:RegisterForClicks('LeftButtonUp','RightButtonUp'); b:RegisterForDrag('LeftButton')
  b:SetHighlightTexture('Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight')
  local bg=b:CreateTexture(nil,'BACKGROUND')
  bg:SetTexture('Interface\\Minimap\\UI-Minimap-Background'); bg:SetSize(24,24); bg:SetPoint('CENTER')
  bg:SetVertexColor(.35,.2,.08)
  local border=b:CreateTexture(nil,'OVERLAY')
  border:SetTexture('Interface\\Minimap\\MiniMap-TrackingBorder'); border:SetSize(50,50); border:SetPoint('TOPLEFT')
  local text=b:CreateFontString(nil,'ARTWORK')
  text:SetFont('Fonts\\FRIZQT__.TTF',10,'OUTLINE'); text:SetPoint('CENTER',bg,'CENTER',0,0)
  text:SetTextColor(1,.82,0); text:SetText('GF')
  local badge=CreateFrame('Frame',nil,b)
  badge:SetSize(15,15); badge:SetPoint('CENTER',b,'TOPLEFT',28,-26); badge:SetFrameLevel(b:GetFrameLevel()+2)
  local badgeBg=badge:CreateTexture(nil,'ARTWORK')
  -- Green like the online dots in the list, so the count doesn't read as unread notifications.
  badgeBg:SetTexture(DOT_TEXTURE); badgeBg:SetAllPoints(); badgeBg:SetVertexColor(.1,.5,.1)
  b.count=badge:CreateFontString(nil,'OVERLAY')
  b.count:SetFont('Fonts\\FRIZQT__.TTF',8,'OUTLINE'); b.count:SetPoint('CENTER',0,0); b.count:SetTextColor(1,1,1)
  b:SetScript('OnClick',function(_,mouse) if mouse=='RightButton' then doSync() else toggle() end end)
  b:SetScript('OnEnter',showMinimapTooltip)
  b:SetScript('OnLeave',GameTooltip_Hide)
  b:SetScript('OnDragStart',function(self)
    self:SetScript('OnUpdate',function()
      local mx,my=Minimap:GetCenter()
      local px,py=GetCursorPosition()
      local scale=Minimap:GetEffectiveScale()
      GuildForgeDB.minimap.angle=math.deg(math.atan2(py/scale-my,px/scale-mx))
      positionMinimap()
    end)
  end)
  b:SetScript('OnDragStop',function(self) self:SetScript('OnUpdate',nil) end)
  positionMinimap()
  b:SetShown(not GuildForgeDB.minimap.hide)
  refreshMinimap()
end

-- Forever/modern clients list addons in the minimap's addon compartment; the TOC points here.
function GuildForge_OnAddonCompartmentClick(_,mouse)
  if mouse=='RightButton' then doSync() else toggle() end
end
-- /guildcraft stays as an alias for people used to the old name.
SLASH_GUILDFORGE1='/guildforge'; SLASH_GUILDFORGE2='/gforge'; SLASH_GUILDFORGE3='/guildprof'; SLASH_GUILDFORGE4='/guildcraft'; SLASH_GUILDFORGE5='/gf'
SlashCmdList['GUILDFORGE']=function(message)
  message=(message or ''):lower():match('^%s*(.-)%s*$')
  if message=='status' then
    local count=0; for _ in pairs(db or {}) do count=count+1 end
    log(string.format('v%s; guild=%s; saved members=%d; messages sent=%d; completed syncs=%d; online with addon=%d',VERSION,tostring(IsInGuild and IsInGuild()),count,sent,received,#activeUsers()),true)
    log(string.format('recipe batches received=%d; recipe messages sent=%d; queued=%d; dropped after retries=%d; sending held=%s',recipeReceived,recipeSent,GF.queuedCount(),droppedMessages,tostring(GF.held==true)),true)
    log(string.format('sharing as %s (%s)',key(),GF.forever and 'WoW Forever' or 'Classic'),true)
  elseif message=='debug' then GF.debugReport()
  elseif message=='log' then GF.openLog()
  elseif message=='requests' or message=='home' then
    if not window then makeWindow() end
    if not window:IsShown() then save(); window:Show() end
    selectTab(message=='home' and 'Home' or 'Requests')
  elseif message=='scan' then GF.scanReport()
  elseif message=='clear' then StaticPopup_Show('GUILDFORGE_CLEAR')
  elseif message=='who' then
    local users=activeUsers(true)
    log(#users..' online with GuildForge:',true)
    for _,line in ipairs(users) do log('   '..line,true) end
  elseif message=='sync' then doSync()
  elseif message=='push' then GF.doPush()
  elseif message=='refresh' then GF.doRefresh()
  elseif message=='config' or message=='settings' or message=='options' then openSettings()
  elseif message=='minimap' then
    GuildForgeDB.minimap.hide=not GuildForgeDB.minimap.hide
    if minimapButton then minimapButton:SetShown(not GuildForgeDB.minimap.hide) end
    log('Minimap button '..(GuildForgeDB.minimap.hide and 'hidden' or 'shown')..'.',true)
  elseif message=='help' then
    log('/guildforge opens the window; sync asks the guild for changes; push re-shares all your recipes; settings opens options; home and requests open those tabs; clear forgets received data and re-downloads it; minimap toggles the button; who lists guildmates and their versions; status shows counters; debug shows how names and messages are read; log opens the live message log.',true)
  else toggle() end
end
-- Each client lacks some of these events, and registering an unknown one throws.
for _,event in ipairs({'PLAYER_LOGIN','SKILL_LINES_CHANGED','CHAT_MSG_ADDON','PLAYER_GUILD_UPDATE',
  'TRADE_SKILL_SHOW','TRADE_SKILL_UPDATE','TRADE_SKILL_LIST_UPDATE','TRADE_SKILL_DATA_SOURCE_CHANGED','CRAFT_SHOW','CRAFT_UPDATE',
  'TRAINER_SHOW','TRAINER_UPDATE','UNIT_SPELLCAST_SUCCEEDED',
  'GUILD_ROSTER_UPDATE','BAG_UPDATE','GET_ITEM_INFO_RECEIVED','ITEM_DATA_LOAD_RESULT'}) do
  pcall(frame.RegisterEvent,frame,event)
end
local syncReady=false
local summaryScheduled=false
local function later(seconds,fn)
  if C_Timer and C_Timer.After then C_Timer.After(seconds,fn) else fn() end
end

-- Clear my data: forget everything received from guildmates in this guild (and shared recipe details),
-- keep your own scans, then sync so the guild's current data downloads fresh.
clearMyData=function()
  if db and db~=tempMembers then
    local me=key()
    local mine=db[me]
    wipe(db)
    if mine then db[me]=mine end
  end
  wipe(tempMembers); wipe(recipePending); wipe(pullRequestedAt); wipe(selectedCrafter); wipe(cdStampSeen)
  local board=GF.requestBoard()
  for who in pairs(board or {}) do if who~=key() then board[who]=nil end end
  GuildForgeDB.members=nil
  for _,list in pairs(recipeInfo or {}) do
    for name,info in pairs(list) do
      if type(info)~='table' or info.remote then list[name]=nil end
    end
  end
  log('Cleared your GuildForge data. Downloading fresh data from the guild...',true)
  doSync()
end
-- Post a request: how many (1 to 99) and an optional note, both sent to everyone with the request.
function GF.requestQty(text) return math.max(1,math.min(99,math.floor(tonumber(text) or 1))) end
function GF.requestDialog()
  if GF.reqDialog then return GF.reqDialog end
  local d=CreateFrame('Frame','GuildForgeRequestDialog',UIParent,BACKDROP_TEMPLATE)
  GF.reqDialog=d
  d:SetSize(340,156); d:SetPoint('CENTER',0,80); d:SetFrameStrata('FULLSCREEN_DIALOG'); d:SetToplevel(true); d:EnableMouse(true)
  if d.SetBackdrop then
    d:SetBackdrop({bgFile='Interface\\DialogFrame\\UI-DialogBox-Background',edgeFile='Interface\\DialogFrame\\UI-DialogBox-Border',tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
  end
  tinsert(UISpecialFrames,'GuildForgeRequestDialog')
  d.title=fontString(d,'GameFontNormal','CENTER'); d.title:SetPoint('TOP',0,-20); d.title:SetWidth(300)
  local hint=fontString(d,'GameFontDisableSmall','CENTER'); hint:SetPoint('TOP',d.title,'BOTTOM',0,-4)
  hint:SetText('Guildmates who can make it will see it.')
  local amountLabel=fontString(d,'GameFontHighlightSmall'); amountLabel:SetPoint('TOPLEFT',26,-66); amountLabel:SetText('Amount')
  d.minus=smallButton(d,'-',24); d.minus:SetPoint('LEFT',d,'TOPLEFT',120,-71)
  d.qty=CreateFrame('EditBox',nil,d,'InputBoxTemplate')
  d.qty:SetSize(30,20); d.qty:SetPoint('LEFT',d.minus,'RIGHT',10,0); d.qty:SetAutoFocus(false)
  d.qty:SetNumeric(true); d.qty:SetMaxLetters(2); d.qty:SetJustifyH('CENTER')
  d.plus=smallButton(d,'+',24); d.plus:SetPoint('LEFT',d.qty,'RIGHT',4,0)
  local noteLabel=fontString(d,'GameFontHighlightSmall'); noteLabel:SetPoint('TOPLEFT',26,-94); noteLabel:SetText('Note (optional)')
  d.note=CreateFrame('EditBox',nil,d,'InputBoxTemplate')
  d.note:SetSize(190,20); d.note:SetPoint('LEFT',d,'TOPLEFT',126,-99); d.note:SetAutoFocus(false); d.note:SetMaxLetters(60)
  d.post=smallButton(d,'Post',90); d.post:SetPoint('BOTTOMRIGHT',d,'BOTTOM',-4,18)
  d.cancel=smallButton(d,CANCEL or 'Cancel',90); d.cancel:SetPoint('BOTTOMLEFT',d,'BOTTOM',4,18)
  local function step(n) d.qty:SetText(tostring(GF.requestQty(GF.requestQty(d.qty:GetText())+n))) end
  local function post()
    local data=d.data
    d:Hide()
    if data and GF.postRequest(data.prof,data.name,GF.requestQty(d.qty:GetText()),d.note:GetText()) then selectTab('Requests') end
  end
  d.minus:SetScript('OnClick',function() step(-1) end)
  d.plus:SetScript('OnClick',function() step(1) end)
  d.post:SetScript('OnClick',post)
  d.cancel:SetScript('OnClick',function() d:Hide() end)
  for _,box in ipairs({d.qty,d.note}) do
    box:SetScript('OnEnterPressed',post)
    box:SetScript('OnEscapePressed',function() d:Hide() end)
    box:SetScript('OnTabPressed',function(self) (self==d.qty and d.note or d.qty):SetFocus() end)
  end
  d:SetScript('OnHide',function() d.qty:ClearFocus(); d.note:ClearFocus() end)
  d:Hide()
  return d
end
function GF.askRequest(prof,name,qty)
  local d=GF.requestDialog()
  d.data={prof=prof,name=name}
  d.title:SetText('Request '..name)
  d.qty:SetText(tostring(GF.requestQty(qty))); d.note:SetText('')
  d:Show()
  d.qty:SetFocus(); d.qty:HighlightText()
end
StaticPopupDialogs['GUILDFORGE_CLEAR']={
  text='Clear your GuildForge data?\n\nEverything received from guildmates is removed and downloaded again. Your own professions and recipes are kept.',
  button1=YES, button2=NO,
  OnAccept=function() clearMyData() end,
  timeout=0, whileDead=true, hideOnEscape=true,
}
frame:SetScript('OnEvent',function(_,event,...)
  if event=='PLAYER_LOGIN' then
    GF.initDB(); GF.purgeRankUpgrades(); selectGuild(); save(); GF.migrateLegacy()
    local register=(C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
    if register then GF.prefixResults={register(PREFIX),register(RECIPE_PREFIX)} end
    GF.makeMinimapButton()
    GF.registerOptions()
    GF.hookTooltips()
    requestRoster()
    log('v'..VERSION..' loaded. Click the GF minimap button or type /guildforge to open.')
    -- Probe first so our name matches what guildmates see before the real sync goes out.
    later(2,function() addonSend('V|'..key()..'|'..VERSION) end)
    later(5,function()
      syncReady=true
      checkCooldowns()
      if GuildForgeDB.settings.syncOnLogin then rollCall(true) else sendSummary() end
    end)
  elseif event=='TRADE_SKILL_SHOW' or event=='TRADE_SKILL_UPDATE' or event=='TRADE_SKILL_LIST_UPDATE' or event=='TRADE_SKILL_DATA_SOURCE_CHANGED' or event=='CRAFT_SHOW' or event=='CRAFT_UPDATE' then
    if not scanScheduled then scanScheduled=true; later(0.3,scanRecipes) end
    -- Forever's profession window opens before its recipes load; look again once they have.
    if event=='TRADE_SKILL_SHOW' then later(2,scanRecipes); later(5,scanRecipes) end
  elseif event=='TRAINER_SHOW' or event=='TRAINER_UPDATE' then
    later(0.3,GF.scanTrainer)
  elseif event=='UNIT_SPELLCAST_SUCCEEDED' then
    local unit,_,spellID=...
    if unit=='player' and not isSecret(spellID) and COOLDOWN_SPELLS[spellID] then
      later(1,function() if checkCooldowns() then queueCooldowns(); requestUpdate() end end)
    end
  elseif event=='SKILL_LINES_CHANGED' then
    save(); requestUpdate(); announce(false)
  elseif event=='PLAYER_GUILD_UPDATE' then
    -- Joining a guild mid-session needs a fresh roll call; at login the 5-second sync handles it.
    if selectGuild() then save(); if syncReady then rollCall(true) end end
    requestRoster(); requestUpdate()
  elseif event=='GUILD_ROSTER_UPDATE' then
    GF.refreshRoster()
    if selectGuild() then save() end
    GF.migrateLegacy(); GF.pruneFormerMembers(); refreshMinimap(); requestUpdate()
  elseif event=='BAG_UPDATE' or event=='GET_ITEM_INFO_RECEIVED' or event=='ITEM_DATA_LOAD_RESULT' then
    requestRedraw()
  elseif event=='CHAT_MSG_ADDON' then
    local prefix,msg,channel,sender=...
    -- Counts for /gf debug: every addon's messages, and ours that arrive somewhere unexpected.
    GF.addonEvents=(GF.addonEvents or 0)+1
    if prefix==PREFIX or prefix==RECIPE_PREFIX then
      GF.ourEvents=(GF.ourEvents or 0)+1
      if channel~='GUILD' or type(msg)~='string' or isSecret(msg) then
        GF.note('got on '..GF.plainText(channel)..' from '..GF.plainText(sender)..(isSecret(msg) and ' (message hidden by the game)' or ''))
      end
    end
    if channel=='GUILD' and prefix==PREFIX and type(msg)=='string' and not isSecret(msg) and msg:sub(1,2)=='V|' then
      local who,version,flag=msg:match('^V|([^|]+)|?([^|]*)|?(.*)$')
      if who==key() and not isSecret(sender) then GF.learnOwnName(sender); requestUpdate(); return end
      if who and senderMatches(sender,who) then
        addonVersions[nameId(who)]=version
        -- Reply to a roll call after a random delay so a big guild's answers trickle in.
        if flag=='r' and syncReady and not summaryScheduled then
          summaryScheduled=true
          later(1+math.random()*9,function() summaryScheduled=false; sendSummary() end)
        end
      end
    end
    if channel=='GUILD' and (prefix==PREFIX or prefix==RECIPE_PREFIX) and type(msg)=='string' then
      if not isSecret(msg) then
        local named=msg:match('^[^|]+|([^|]+)')
        GF.note('got from '..GF.plainText(sender)..': '..msg..(senderMatches(sender,named) and '' or '  REJECTED: sender is not '..tostring(named)))
      end
      -- Count by the name in the payload when the client hides the sender.
      local who=isSecret(sender) and msg:match('^[^|]+|([^|]+)') or sender
      if senderMatches(sender,who) and nameId(who)~=nameId(key()) then GF.markSeen(who) end
    end
    if channel=='GUILD' then
      if prefix==PREFIX then GF.parseMessage(msg,sender); requestUpdate() end
      if prefix==RECIPE_PREFIX then GF.receiveRecipe(msg,sender) end
    end
  end
end)
frame:SetScript('OnUpdate',function(_,elapsed)
  -- Professions channel first: it carries the small, time-sensitive messages.
  if GF.watchBlocked(elapsed) and syncReady then rollCall(true) end
  local canSend=GF.queuedCount()>0 and IsInGuild and IsInGuild() and not GF.held
  for _,channel in ipairs(GF.channels) do GF.drainChannel(channel,elapsed,canSend) end
  if GF.announceDue and now()>=GF.announceDue then announce(false) end
  -- Coalesce bursts of sync messages and bag events into one redraw.
  sinceUpdate=sinceUpdate+elapsed
  if updatePending and sinceUpdate>=0.2 then update() end
  sinceRoster=sinceRoster+elapsed
  if sinceRoster>=60 then
    sinceRoster=0; requestRoster()
    if checkCooldowns() then queueCooldowns() end
    -- Keeps cooldown countdowns and "seen" times current while the window is open.
    requestRedraw()
  end
end)
print('|cff00ff00GuildForge: v'..VERSION..' Lua loaded; slash commands registered.|r')
