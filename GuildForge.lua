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
-- Helper functions live in one table: WoW's Lua allows at most 200 locals at the top of a file.
local GF={}
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
local lastRecipeSend = 0
local sendFailures, droppedMessages = 0, 0
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
}
local specialTabs={All='All Professions',Shopping='Shopping List'}
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
  if not always and settings().quiet then return end
  print('|cffd8aa55GuildForge:|r '..tostring(s))
end
local function realm() return (GetRealmName and GetRealmName()) or 'Unknown' end
local cachedPlayer
-- WoW: Forever adds surnames, and UnitName may not match the name other players see on our messages.
-- GF.learnOwnName() records the name the server puts on our own messages, keyed by UnitName.
local function playerName()
  if cachedPlayer then return cachedPlayer end
  local name=UnitName('player')
  if name and not isSecret(name) then
    local learned=GuildForgeDB and GuildForgeDB.knownAs and GuildForgeDB.knownAs[name..'-'..realm()]
    cachedPlayer=learned or name
  end
  return cachedPlayer
end
local function key() return (playerName() or 'Unknown')..'-'..realm() end
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
    if normalizeRealm(name:sub(dash+1))==own then return name:sub(1,dash-1),realm() end
    start=dash+1
  end
  local character,server=name:match('^([^-]+)%-(.+)$')
  if not character then return name,realm() end
  return character,server
end
local function nameId(name)
  local character,server=splitName(name)
  if not character then return nil end
  return character:gsub('%s',''):lower()..'-'..normalizeRealm(server)
end
-- "Bob" for your own realm, "Bob-Faerlina" for anyone from another realm.
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
  selectedTab=professionIcons[GuildForgeDB.ui.tab or ''] and GuildForgeDB.ui.tab or 'All'
end
local function save()
  if not db then GF.initDB() end
  if not playerName() or db==tempMembers then return end
  local name=key()
  local previous=db[name] or {}
  db[name]={professions=scan(),updated=now(),localPlayer=true,recipes=previous.recipes or {},recipeUpdated=previous.recipeUpdated or {},cooldowns=previous.cooldowns or {},cdStamp=previous.cdStamp}
end
-- WoW: Forever (Midnight-era API) blocks outgoing addon messages in some situations, such as combat in
-- instances. Messages wait until the lockdown lifts instead of failing and being dropped.
function GF.messagingBlocked()
  local C=C_ChatInfo
  if not C then return false end
  -- Blizzard only restricts addon chat in instances and combat. Outside those, send anyway, so a
  -- check that misreports (Classic Era returned a non-boolean here) can never freeze sharing.
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
local heldMessages={}
local function addonSend(payload)
  if not (IsInGuild and IsInGuild()) then return false end
  local fn=(C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  if not fn then return false end
  if GF.messagingBlocked() then
    if #heldMessages<50 then heldMessages[#heldMessages+1]=payload end
    return false
  end
  fn(PREFIX,payload,'GUILD')
  sent=sent+1
  return true
end
local function announce(force)
  if not (IsInGuild and IsInGuild()) then return end
  local t=now()
  if not force and t-lastBroadcast<15 then return end
  save()
  local rec=db[key()]
  if not rec then return end
  local entries={}
  for _,p in ipairs(rec.professions) do
    entries[#entries+1]=p.name..':'..p.rank..':'..p.max
  end
  -- Classic addon messages are small; split into one record per profession.
  addonSend('B|'..key())
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
  if action=='B' then pending[who]={professions={},updated=now()}; return end
  if action=='P' then
    local record=pending[who]
    if not record then return end
    local name,rank,maximum=extra:match('^([^:]+):(%d+):(%d+)$')
    if name and #record.professions<16 then
      record.professions[#record.professions+1]={name=name,rank=tonumber(rank),max=tonumber(maximum)}
    end
  elseif action=='E' then
    local record=pending[who]
    if record then
      table.sort(record.professions,function(a,b) return a.name<b.name end)
      local old=db[who] or {}
      record.recipes=old.recipes or {}
      record.recipeUpdated=old.recipeUpdated or {}
      record.cooldowns=old.cooldowns or {}
      db[who]=record
      pending[who]=nil
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
  return tostring(value or ''):gsub('[|\r\n]',' '):sub(1,110)
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
function GF.recipeSend(payload)
  if not (IsInGuild and IsInGuild()) then return false end
  local fn=(C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  if not fn then return false end
  local result=fn(RECIPE_PREFIX,payload,'GUILD')
  -- Newer clients return false or a non-zero result code when the message was throttled and not sent.
  if result==false or (type(result)=='number' and result~=0) then return false end
  recipeSent=recipeSent+1
  return true
end
-- Format: D|who|prof|name~i12345 (or e7418 for enchants)~itemID:count,itemID:count
function GF.detailPayload(who,prof,name)
  local info=recipeInfo and recipeInfo[prof] and recipeInfo[prof][name]
  if not info then return nil end
  local parts={}
  for _,r in ipairs(info.reagents or {}) do
    if r.id then parts[#parts+1]=r.id..':'..(r.n or 1) end
  end
  local payload='D|'..who..'|'..prof..'|'..clean(name)..'~'..(info.link or '')..'~'..table.concat(parts,',')
  if #payload<=250 then return payload end
end
queueRecipes=function(prof,force)
  local mine=db and db[key()]
  local entries=mine and mine.recipes and mine.recipes[prof]
  if not entries then return end
  -- Several guildmates may pull the same list at once; one broadcast serves them all.
  if not force and fullQueuedAt[prof] and now()-fullQueuedAt[prof]<30 then return end
  fullQueuedAt[prof]=now()
  local who=key()
  recipeQueue[#recipeQueue+1]='B|'..who..'|'..prof..'|'..#entries
  for _,name in ipairs(entries) do
    recipeQueue[#recipeQueue+1]='I|'..who..'|'..prof..'|'..clean(name)
  end
  recipeQueue[#recipeQueue+1]='E|'..who..'|'..prof
  for _,name in ipairs(entries) do
    local detail=GF.detailPayload(who,prof,name)
    if detail then recipeQueue[#recipeQueue+1]=detail end
  end
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
    if type(info)=='table' and info.source then list[#list+1]=name end
  end
  table.sort(list)
  return list
end
local catalogQueuedAt={}
function GF.queueCatalog(prof)
  if catalogQueuedAt[prof] and now()-catalogQueuedAt[prof]<30 then return end
  catalogQueuedAt[prof]=now()
  for _,name in ipairs(GF.catalogList(prof)) do
    local info=recipeInfo[prof][name]
    local payload='T|'..key()..'|'..prof..'|'..clean(name)..'~'..(info.req or '')..'~'..(info.link or '')
    if #payload<=250 then recipeQueue[#recipeQueue+1]=payload end
  end
end
-- Roll call: one S message per player fingerprints their professions, recipe lists, cooldowns and catalog.
-- S|who|version;p<professions>;c<cooldown stamp>;k<catalog>;<profIndex>:<count>:<hash>;...
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
local function sendSummary()
  local mine=db and db[key()]
  if not mine then return end
  local parts={VERSION,'p'..GF.professionHash(mine.professions),'c'..(mine.cdStamp or 0),'k'..GF.catalogHash()}
  for index,prof in ipairs(professions) do
    local list=mine.recipes and mine.recipes[prof]
    if craftable[prof] and type(list)=='table' and #list>0 then
      parts[#parts+1]=index..':'..#list..':'..listHash(list)
    end
  end
  local payload='S|'..key()..'|'..table.concat(parts,';')
  if #payload<=250 then addonSend(payload) end
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
    elseif kind=='k' then
      local hash=tonumber(value)
      -- Catalogs merge as a union: pull theirs when it differs; they pull ours from our own summary.
      if hash and hash>0 and hash~=GF.catalogHash() then wants=wants..'k' end
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
-- A guildmate asked us for professions (p), cooldowns (c) or our trainer catalog (k).
handleAsk=function(extra)
  local target,wants=(extra or ''):match('^(.-)~(%a*)$')
  if target~=key() then return end
  -- announce() itself skips repeats within 15 seconds, so several askers get one broadcast.
  if wants:find('p',1,true) then announce(false) end
  if wants:find('c',1,true) and now()-cooldownsAskedAt>=30 then cooldownsAskedAt=now(); queueCooldowns() end
  if wants:find('k',1,true) then for prof in pairs(craftable) do GF.queueCatalog(prof) end end
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
  elseif action=='I' then
    local pending=recipePending[pendingKey]
    local item=extra and clean(extra)
    -- A dropped E/B can splice two broadcasts together; repeats mean the list is unreliable, so skip them.
    if pending and item and not pending.seen[item] and #pending.items<pending.expected then
      pending.seen[item]=true
      pending.items[#pending.items+1]=item
    end
  elseif action=='E' then
    local pending=recipePending[pendingKey]
    if pending and #pending.items==pending.expected then
      local record=db[who] or {professions={},updated=now()}
      record.recipes=record.recipes or {}
      record.recipeUpdated=record.recipeUpdated or {}
      table.sort(pending.items)
      record.recipes[prof]=pending.items
      record.recipeUpdated[prof]=now()
      db[who]=record
      recipeReceived=recipeReceived+1
      requestUpdate()
    end
    recipePending[pendingKey]=nil
  elseif action=='D' then
    local name,link,reagentText=(extra or ''):match('^([^~]+)~([^~]*)~(.*)$')
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
    recipeInfo[prof][name]={link=link,reagents=reagents,remote=true}
    requestUpdate()
  elseif action=='G' then
    if extra==key() then queueRecipes(prof) end
  elseif action=='T' then
    local name,req,link=(extra or ''):match('^([^~]+)~(%d*)~([^~]*)$')
    if not name then return end
    name=clean(name)
    recipeInfo[prof]=recipeInfo[prof] or {}
    if not recipeInfo[prof][name] then
      recipeInfo[prof][name]={link=link:match('^[ie]%d+$') and link or nil,reagents={},remote=true,source='Trainer',req=tonumber(req)}
      requestUpdate()
    end
  elseif action=='C' then
    local name,remaining=(extra or ''):match('^([^~]+)~(%d+)$')
    if not name then return end
    remaining=tonumber(remaining)
    local record=db[who] or {professions={},updated=now()}
    record.cooldowns=record.cooldowns or {}
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
local function storeInfo(prof,name,link,icon,reagents)
  recipeInfo[prof]=recipeInfo[prof] or {}
  recipeInfo[prof][name]={link=link,icon=icon,reagents=reagents}
end
-- Saves a finished scan and queues it for the guild when the recipe list changed.
local function commitScan(prof,recipes,warnFiltered)
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
    record.recipes[prof]=recipes
    record.recipeUpdated[prof]=now()
    queueRecipes(prof,true)
    log('Scanned '..#recipes..' visible '..prof..' recipes; queued guild sharing.')
  end
  requestUpdate()
end
-- Records a recipe cooldown seen in the trade window; a recipe that had one and now reports none is ready.
function GF.noteRecipeCooldown(prof,recipe,remaining)
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
        storeInfo(prof,recipe,link,info.icon,reagents)
        if T.GetRecipeCooldown then GF.noteRecipeCooldown(prof,recipe,tonumber((T.GetRecipeCooldown(recipeID)))) end
      elseif not recipeInfo[prof][recipe] then
        -- Unlearned recipes feed the "not known in guild" list.
        local link,reagents=GF.schematicDetails(recipeID)
        recipeInfo[prof][recipe]={link=link,icon=info.icon,reagents=reagents,remote=true,source='Not learned'}
      end
    end
  end
  commitScan(prof,recipes,true)
end
-- Trainers list recipes nobody may know yet; catalogue them for the "not known in guild" list.
local RANK_UPGRADES={Apprentice=true,Journeyman=true,Expert=true,Artisan=true,Master=true}
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
    local isRankUpgrade=name==prof or RANK_UPGRADES[subText or '']
    if name and category~='header' and craftable[prof] and not isRankUpgrade then
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
local function doSync()
  save()
  if checkCooldowns() then queueCooldowns() end
  rollCall(true); requestUpdate()
  log('Guild sync request sent.')
end
function GF.doPush()
  save(); fullQueuedAt={}; catalogQueuedAt={}; GF.shareAllRecipes(); checkCooldowns(); queueCooldowns()
  for prof in pairs(craftable) do GF.queueCatalog(prof) end
  log('Sharing all of your recipes with the guild ('..#recipeQueue..' messages queued).',true)
end
function GF.doRefresh()
  save(); announce(true); scanRecipes(); checkCooldowns(); requestUpdate()
  log('Local professions refreshed and shared.')
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
  if not (IsInGuild and IsInGuild()) then return 'No guild - '..realm() end
  local name=GetGuildInfo and GetGuildInfo('player')
  if not name or isSecret(name) then return nil end
  return name..' - '..realm()
end
-- Points db at the current guild's members; returns true when the guild changed.
local function selectGuild()
  if not GuildForgeDB or not playerName() then return false end
  local bucket=GF.guildBucketKey()
  if not bucket or bucket==currentGuild then return false end
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
function GF.requestCraft(r,target)
  if not (target and SendChat) then return end
  local message='[GuildForge] Hi '..target.character..'! Could you craft '..(GF.chatLinkFor(r.info and r.info.link) or r.name)..' for me?'
  local have={}
  for _,reagent in ipairs(r.info and r.info.reagents or {}) do
    local bags=bagCount(reagent)
    local need=reagent.n or 1
    if bags>0 then have[#have+1]=math.min(bags,need)..'/'..need..' '..reagentName(reagent) end
  end
  local tail=#have>0 and (' I have '..table.concat(have,', ')..'.') or ' Happy to bring mats or tip.'
  if #message+#tail>250 then tail=' I have some of the mats.' end
  SendChat(message..tail,'WHISPER',nil,target.character)
  log('Whispered '..target.character..' about '..r.name..'.',true)
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
  table.sort(recipes,function(a,b) return a.name<b.name end)
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
      local r={name=name,crafters={},info=info}
      r.times=craftableTimes(info)
      if not filter and GF.recipeMatches(r,prof,term) and (not matsOnly or (r.times or 0)>0) then d.unknown[#d.unknown+1]=r end
    end
  end
  table.sort(d.unknown,function(a,b)
    local ra,rb=a.info.req or 0,b.info.req or 0
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
  local b=CreateFrame('Button',nil,scrollContent,BACKDROP_TEMPLATE)
  b:SetHeight(40); skin(b,.85)
  b.icon=b:CreateTexture(nil,'ARTWORK'); b.icon:SetSize(30,30); b.icon:SetPoint('LEFT',6,0); b.icon:SetTexCoord(.07,.93,.07,.93)
  b.name=fontString(b,'GameFontNormalLarge'); b.name:SetPoint('LEFT',b.icon,'RIGHT',10,0)
  b.info=fontString(b,'GameFontHighlightSmall','RIGHT'); b.info:SetPoint('RIGHT',-12,0)
  local hl=addHighlight(b,.35); hl:ClearAllPoints(); hl:SetPoint('TOPLEFT',4,-4); hl:SetPoint('BOTTOMRIGHT',-4,4)
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
  b.place=fontString(b,'GameFontDisableSmall','RIGHT'); b.place:SetPoint('LEFT',2,0); b.place:SetWidth(22)
  b.dot=b:CreateTexture(nil,'ARTWORK'); b.dot:SetTexture(DOT_TEXTURE); b.dot:SetSize(9,9); b.dot:SetPoint('LEFT',30,0)
  b.name=fontString(b,'GameFontHighlight'); b.name:SetPoint('LEFT',44,0); b.name:SetWidth(170)
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
  b.toggle=b:CreateTexture(nil,'ARTWORK'); b.toggle:SetSize(14,14); b.toggle:SetPoint('LEFT',3,0)
  GF.iconSlot(b,22); b.iconBorder:SetPoint('LEFT',20,0)
  b.name=fontString(b,'GameFontNormal'); b.name:SetPoint('LEFT',b.iconBorder,'RIGHT',8,0); b.name:SetWidth(270)
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
  f.text=fontString(f,'GameFontDisableSmall'); f.text:SetPoint('LEFT',f.b2,'RIGHT',10,0)
  return f
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
    b.place:SetText(index..'.')
    GF.setDot(b.dot,c.online)
    b.name:SetText(c.character..(c.isMe and ' |cff40ff40(You)|r' or ''))
    b.bar:SetMinMaxValues(0,math.max(1,c.max))
    b.bar:SetValue(c.rank)
    b.bar:SetStatusBarColor(GF.rankColor(c.rank))
    b.bar.text:SetText(c.rank..' / '..c.max)
    b.recipes:SetText(c.recipeCount>0 and ('|cffffd100'..c.recipeCount..'|r recipes') or '|cff808080no recipes|r')
    b.seen:SetText(GF.availabilityText(c))
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
  local function addRecipe(prof,r)
    local id=prof..'|'..r.name
    local open=recipeOpen[id]==true
    local b=acquire('recipe')
    nextStripe(b.stripe,.045)
    b.toggle:SetTexture(GF.toggleTexture(open))
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
    if r.times==nil then
      b.mats:SetText('|cff808080Reagents unknown|r')
    elseif r.times>0 then
      b.mats:SetText('|cff40ff40Mats ready'..(r.times>1 and (' x'..r.times) or '')..'|r')
    else
      b.mats:SetText('|cffff5a5aMissing mats|r')
    end
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
        rb.count:SetText(color..bags..' / '..need..'|r'..(bank>0 and ('  |cff8fb8ff(+'..bank..' in bank)|r') or ''))
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
    a.text:SetText(onList and ('On your shopping list: '..onList) or '')
    place(a,28,56)
    y=y+4
  end

  local selected=selectedTab
  if selected=='All' then
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
        place(h,42)
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
        rb.count:SetText(text)
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
    if #shoppingEntries()>0 then
      y=y+6
      local a=acquire('actions')
      a.b1:SetText('Clear list'); a.b1:Enable()
      a.b1:SetScript('OnClick',function() releaseSearchFocus(); wipe(GuildForgeDB.shopping); requestUpdate(); update() end)
      a.b2:Hide()
      a.text:SetText('Item tooltips also show what you still need.')
      place(a,28,8)
    end
    headerIcon:SetTexture(professionIcons.Shopping)
    headerTitle:SetText('Shopping List')
    headerSub:SetText(#shoppingEntries()..' recipes  ·  '..#order..' materials  ·  '..(missing>0 and ('|cffff5a5a'..missing..' still needed|r') or '|cff40ff40nothing missing|r'))
  else
    local prof=selected
    local d=GF.professionData(prof,term)
    if addSection(prof..'|crafters','Crafters',#d.fc..' of '..#d.crafters) then
      if #d.fc==0 then addNote('No guildmates have shared '..prof..' yet.',16) end
      for i,c in ipairs(d.fc) do addCrafter(prof,c,i,false) end
    end
    addCooldownSection(prof..'|cooldowns',prof)
    if craftable[prof] or #d.recipes>0 then
      local extra=#d.fr..' of '..#d.recipes
      if d.filterName then extra='|cffffd100'..d.filterName..'|r only  ·  '..extra end
      if addSection(prof..'|recipes','Recipes',extra) then
        if #d.fr==0 then
          addNote(#d.recipes==0 and 'No recipes shared yet. Open the profession window on a character that knows it.' or 'No recipes match the current filters.',16)
        end
        for _,r in ipairs(d.fr) do addRecipe(prof,r) end
      end
    end
    if craftable[prof] and not d.filter then
      if addSection(prof..'|unknown','Not known in guild',#d.unknown..' of '..d.unknownTotal,true) then
        if d.unknownTotal==0 then
          addNote('Visit a '..prof..' trainer (or open the profession on Forever) to list recipes nobody in the guild knows yet.',16)
        end
        for _,r in ipairs(d.unknown) do addRecipe(prof,r) end
      end
    end
    headerIcon:SetTexture(professionIcons[prof])
    headerTitle:SetText(prof)
    local sub=#d.crafters..' crafters  ·  '..#d.recipes..' recipes'
    if craftable[prof] then sub=sub..'  ·  |cff40ff40'..d.ready..' you can craft now|r' end
    if d.filterName then sub=sub..'  ·  showing |cffffd100'..d.filterName..'|r (click again to clear)' end
    headerSub:SetText(sub)
  end
  scrollContent:SetHeight(math.max(100,y+10))
  for _,t in ipairs(tabs) do
    t:SetChecked(t.name==selectedTab)
    if not specialTabs[t.name] then t:GetNormalTexture():SetDesaturated(not GF.hasProfession(t.name)) end
  end
  local guild=(IsInGuild and IsInGuild()) and (GetGuildInfo and GetGuildInfo('player') or 'In guild') or 'Not in guild'
  local queued=#recipeQueue>0 and ('  |  sharing '..#recipeQueue..' queued') or ''
  status:SetText(string.format('|cffffd100%s|r  |  %d syncs  |  %d recipe batches%s',guild,received,recipeReceived,queued))
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
  t:SetPoint('TOPLEFT',window,'TOPRIGHT',-6,-44-(index-1)*35)
  local bg=t:CreateTexture(nil,'BACKGROUND')
  bg:SetTexture('Interface\\SpellBook\\SpellBook-SkillLineTab'); bg:SetSize(64,64); bg:SetPoint('TOPLEFT',-3,11)
  t:SetNormalTexture(professionIcons[name])
  t:SetHighlightTexture('Interface\\Buttons\\ButtonHilight-Square','ADD')
  t:SetCheckedTexture('Interface\\Buttons\\CheckButtonHilight')
  t:GetCheckedTexture():SetBlendMode('ADD')
  t:SetScript('OnClick',function() releaseSearchFocus(); selectTab(name) end)
  t:SetScript('OnEnter',function(self)
    GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
    GameTooltip:AddLine(specialTabs[name] or name,1,.82,0)
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
  local refresh=button('Refresh',80,{'TOPLEFT',22,-36},GF.doRefresh)
  local sync=button('Sync Guild',90,{'LEFT',refresh,'RIGHT',6,0},doSync)
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
  header:SetPoint('TOPLEFT',16,-64); header:SetPoint('TOPRIGHT',-16,-64); header:SetHeight(52); skin(header,.8)
  headerIcon=header:CreateTexture(nil,'ARTWORK'); headerIcon:SetSize(38,38); headerIcon:SetPoint('LEFT',8,0); headerIcon:SetTexCoord(.07,.93,.07,.93)
  headerTitle=header:CreateFontString(nil,'OVERLAY','GameFontNormalLarge'); headerTitle:SetPoint('TOPLEFT',headerIcon,'TOPRIGHT',10,-2)
  headerSub=header:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall'); headerSub:SetPoint('BOTTOMLEFT',headerIcon,'BOTTOMRIGHT',10,3)

  local inset=CreateFrame('Frame',nil,f,BACKDROP_TEMPLATE)
  inset:SetPoint('TOPLEFT',16,-120); inset:SetPoint('BOTTOMRIGHT',-16,36); skin(inset,.75,.55,.45,.28)
  scrollFrame=CreateFrame('ScrollFrame','GuildForgeScrollFrame',inset,'UIPanelScrollFrameTemplate')
  scrollFrame:SetPoint('TOPLEFT',8,-8); scrollFrame:SetPoint('BOTTOMRIGHT',-30,8)
  scrollFrame:SetScript('OnMouseDown',releaseSearchFocus)
  scrollContent=CreateFrame('Frame',nil,scrollFrame); scrollContent:SetSize(CONTENT_W,100)
  scrollContent:EnableMouse(true); scrollContent:SetScript('OnMouseDown',releaseSearchFocus)
  scrollFrame:SetScrollChild(scrollContent)

  f.settingsPanel=GF.makeSettingsPanel(f,inset)
  gear:SetScript('OnClick',function() releaseSearchFocus(); f.settingsPanel:SetShown(not f.settingsPanel:IsShown()) end)

  status=f:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall'); status:SetPoint('BOTTOMLEFT',22,17)
  local hint=f:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); hint:SetPoint('BOTTOMRIGHT',-22,17)
  hint:SetText('Shift-click a recipe or reagent to link it')

  makeTab(1,'All')
  for i,prof in ipairs(professions) do makeTab(i+1,prof) end
  makeTab(#professions+2,'Shopping')

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
local function positionMinimap()
  local angle=math.rad(GuildForgeDB.minimap.angle or 200)
  local radius=(Minimap:GetWidth()/2)+10
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint('CENTER',Minimap,'CENTER',math.cos(angle)*radius,math.sin(angle)*radius)
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
  bg:SetTexture('Interface\\Minimap\\UI-Minimap-Background'); bg:SetSize(21,21); bg:SetPoint('TOPLEFT',6,-5)
  bg:SetVertexColor(.35,.2,.08)
  local border=b:CreateTexture(nil,'OVERLAY')
  border:SetTexture('Interface\\Minimap\\MiniMap-TrackingBorder'); border:SetSize(53,53); border:SetPoint('TOPLEFT')
  local text=b:CreateFontString(nil,'ARTWORK')
  text:SetFont('Fonts\\FRIZQT__.TTF',10,'OUTLINE'); text:SetPoint('CENTER',bg,'CENTER',0,0)
  text:SetTextColor(1,.82,0); text:SetText('GF')
  local badge=CreateFrame('Frame',nil,b)
  badge:SetSize(15,15); badge:SetPoint('CENTER',b,'TOPLEFT',28,-26); badge:SetFrameLevel(b:GetFrameLevel()+2)
  local badgeBg=badge:CreateTexture(nil,'ARTWORK')
  badgeBg:SetTexture(DOT_TEXTURE); badgeBg:SetAllPoints(); badgeBg:SetVertexColor(.75,.08,.05)
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
    log(string.format('recipe batches received=%d; recipe messages sent=%d; queued=%d; dropped after retries=%d; sending held=%s',recipeReceived,recipeSent,#recipeQueue,droppedMessages,tostring(GF.messagingBlocked())),true)
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
    log('/guildforge opens the window; sync asks the guild for changes; push re-shares all your recipes; settings opens options; clear forgets received data and re-downloads it; minimap toggles the button; who lists guildmates and their versions; status shows counters.',true)
  else toggle() end
end
-- Each client lacks some of these events, and registering an unknown one throws.
for _,event in ipairs({'PLAYER_LOGIN','SKILL_LINES_CHANGED','CHAT_MSG_ADDON','PLAYER_GUILD_UPDATE',
  'TRADE_SKILL_SHOW','TRADE_SKILL_UPDATE','TRADE_SKILL_LIST_UPDATE','CRAFT_SHOW','CRAFT_UPDATE',
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
  GuildForgeDB.members=nil
  for _,list in pairs(recipeInfo or {}) do
    for name,info in pairs(list) do
      if type(info)~='table' or info.remote then list[name]=nil end
    end
  end
  log('Cleared your GuildForge data. Downloading fresh data from the guild...',true)
  doSync()
end
StaticPopupDialogs['GUILDFORGE_CLEAR']={
  text='Clear your GuildForge data?\n\nEverything received from guildmates is removed and downloaded again. Your own professions and recipes are kept.',
  button1=YES, button2=NO,
  OnAccept=function() clearMyData() end,
  timeout=0, whileDead=true, hideOnEscape=true,
}
frame:SetScript('OnEvent',function(_,event,...)
  if event=='PLAYER_LOGIN' then
    GF.initDB(); selectGuild(); save(); GF.migrateLegacy()
    local register=(C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
    if register then register(PREFIX); register(RECIPE_PREFIX) end
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
  elseif event=='TRADE_SKILL_SHOW' or event=='TRADE_SKILL_UPDATE' or event=='TRADE_SKILL_LIST_UPDATE' or event=='CRAFT_SHOW' or event=='CRAFT_UPDATE' then
    if not scanScheduled then scanScheduled=true; later(0.3,scanRecipes) end
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
  local blocked=(#recipeQueue>0 or #heldMessages>0) and GF.messagingBlocked()
  if #heldMessages>0 and not blocked then
    local held=heldMessages; heldMessages={}
    for _,payload in ipairs(held) do addonSend(payload) end
  end
  if #recipeQueue>0 and now()~=0 and not blocked then
    lastRecipeSend=lastRecipeSend+elapsed
    if lastRecipeSend>=0.25 then
      lastRecipeSend=0
      if IsInGuild and IsInGuild() then
        if GF.recipeSend(recipeQueue[1]) then
          table.remove(recipeQueue,1); sendFailures=0
        else
          -- Throttled messages go through on a later try; one that keeps failing is dropped so it can't stall the queue.
          sendFailures=sendFailures+1
          if sendFailures>=5 then table.remove(recipeQueue,1); sendFailures=0; droppedMessages=droppedMessages+1 end
          lastRecipeSend=-1
        end
      end
    end
  end
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
