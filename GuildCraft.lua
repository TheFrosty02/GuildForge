-- GuildCraft 0.10.0 - Classic Era WoW-styled window, profession tabs, recipe reagents, minimap button
local VERSION='0.10.0'
local PREFIX='GCRFT96' -- preserve working profession sync protocol
local RECIPE_PREFIX='GCRFT10'
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
local updatePending, sinceUpdate, sinceRoster = false, 0, 0
local activeSeen, guildOnline = {}, {}
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
}
local QUESTION_ICON='Interface\\Icons\\INV_Misc_QuestionMark'
local BACKDROP_TEMPLATE=BackdropTemplateMixin and 'BackdropTemplate' or nil
local CONTENT_W=646
local update, refreshMinimap
local function releaseSearchFocus()
  if searchBox and searchBox:HasFocus() then searchBox:ClearFocus() end
end
local function requestUpdate() updatePending=true end
local scanRecipes, queueRecipes
local db, recipeInfo, lastBroadcast= nil, nil, 0
local received, sent=0,0
local function log(s) print('|cffd8aa55GuildCraft:|r '..tostring(s)) end
local function realm() return (GetRealmName and GetRealmName()) or 'Unknown' end
local function key() return (UnitName('player') or 'Unknown')..'-'..realm() end
local function now() return (time and time()) or 0 end
local function shortName(name) return type(name)=='string' and name:match('^[^-]+') or nil end
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
local function initDB()
  GuildCraftDB=GuildCraftDB or {}
  GuildCraftDB.members=GuildCraftDB.members or {}
  -- Recipe details (crafted item + reagents) are shared by name, independent of who knows them.
  GuildCraftDB.recipeInfo=GuildCraftDB.recipeInfo or {}
  GuildCraftDB.minimap=GuildCraftDB.minimap or {angle=200,hide=false}
  GuildCraftDB.ui=GuildCraftDB.ui or {tab='All',matsOnly=false}
  db=GuildCraftDB.members
  recipeInfo=GuildCraftDB.recipeInfo
  selectedTab=professionIcons[GuildCraftDB.ui.tab or ''] and GuildCraftDB.ui.tab or 'All'
end
local function save()
  if not db then initDB() end
  if not UnitName('player') then return end
  local name=key()
  local previous=db[name] or {}
  db[name]={professions=scan(),updated=now(),localPlayer=true,recipes=previous.recipes or {},recipeUpdated=previous.recipeUpdated or {}}
end
local function addonSend(payload)
  if not (IsInGuild and IsInGuild()) then return false end
  local fn=(C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  if not fn then return false end
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
local function parseMessage(message,sender)
  if type(message)~='string' then return end
  local action,who,extra=message:match('^([^|]+)|([^|]+)|?(.*)$')
  if not action or not who or who==key() then return end
  local senderName=sender and sender:match('^[^-]+')
  local declaredName=who:match('^[^-]+')
  if not senderName or senderName~=declaredName then return end
  if action=='Q' then announce(true); return end
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
      db[who]=record
      pending[who]=nil
      received=received+1
      requestUpdate()
    end
  end
end
-- Recipe sync uses its own prefix and does not alter the proven profession protocol.
local craftable={Alchemy=true,Blacksmithing=true,Enchanting=true,Engineering=true,Leatherworking=true,Tailoring=true,Cooking=true,['First Aid']=true}
local function clean(value)
  return tostring(value or ''):gsub('[|\r\n]',' '):sub(1,110)
end
local function recipeSend(payload)
  if not (IsInGuild and IsInGuild()) then return false end
  local fn=(C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  if not fn then return false end
  fn(RECIPE_PREFIX,payload,'GUILD')
  recipeSent=recipeSent+1
  return true
end
-- 'D' detail records ride alongside 'I'; older clients ignore the unknown action.
-- Format: D|who|prof|name~i12345 (or e7418 for enchants)~itemID:count,itemID:count
local function detailPayload(who,prof,name)
  local info=recipeInfo and recipeInfo[prof] and recipeInfo[prof][name]
  if not info then return nil end
  local parts={}
  for _,r in ipairs(info.reagents or {}) do
    if r.id then parts[#parts+1]=r.id..':'..(r.n or 1) end
  end
  local payload='D|'..who..'|'..prof..'|'..clean(name)..'~'..(info.link or '')..'~'..table.concat(parts,',')
  if #payload<=250 then return payload end
end
queueRecipes=function(prof)
  local mine=db and db[key()]
  local entries=mine and mine.recipes and mine.recipes[prof]
  if not entries then return end
  local who=key()
  recipeQueue[#recipeQueue+1]='B|'..who..'|'..prof..'|'..#entries
  for _,name in ipairs(entries) do
    recipeQueue[#recipeQueue+1]='I|'..who..'|'..prof..'|'..clean(name)
  end
  recipeQueue[#recipeQueue+1]='E|'..who..'|'..prof
  for _,name in ipairs(entries) do
    local detail=detailPayload(who,prof,name)
    if detail then recipeQueue[#recipeQueue+1]=detail end
  end
end
local function shareAllRecipes()
  local mine=db and db[key()]
  if not mine or not mine.recipes then return end
  for prof in pairs(mine.recipes) do if craftable[prof] then queueRecipes(prof) end end
end
local function receiveRecipe(msg,sender)
  if type(msg)~='string' then return end
  local action,who,prof,extra=msg:match('^([^|]+)|([^|]+)|([^|]+)|?(.*)$')
  if not action or not who or not craftable[prof] or who==key() then return end
  if not sender or sender:match('^[^-]+')~=who:match('^[^-]+') then return end
  local pendingKey=who..'|'..prof
  if action=='B' then
    local expected=tonumber(extra)
    if not expected or expected<0 or expected>500 then return end
    recipePending[pendingKey]={items={},expected=expected}
  elseif action=='I' then
    local pending=recipePending[pendingKey]
    if pending and extra and #pending.items<pending.expected then
      pending.items[#pending.items+1]=clean(extra)
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
local function scanTradeSkill()
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
    end
  end
  if #recipes==0 then return end
  table.sort(recipes)
  local record=db and db[key()]
  if not record then return end
  record.recipes=record.recipes or {}
  record.recipeUpdated=record.recipeUpdated or {}
  local old=record.recipes[prof]
  -- Filtered windows may show fewer entries; don't erase a larger saved list.
  if old and #recipes<#old then
    log('Recipe scan for '..prof..' showed fewer recipes than saved; check profession filters. Saved list preserved.')
    return
  end
  local changed=not old or #old~=#recipes
  if not changed then for i,name in ipairs(recipes) do if old[i]~=name then changed=true; break end end end
  if changed then
    record.recipes[prof]=recipes
    record.recipeUpdated[prof]=now()
    queueRecipes(prof)
    log('Scanned '..#recipes..' visible '..prof..' recipes; queued guild sharing.')
  end
  requestUpdate()
end
local function scanCraft()
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
  if #recipes==0 then return end
  table.sort(recipes)
  local record=db and db[key()]
  if not record then return end
  record.recipes=record.recipes or {}; record.recipeUpdated=record.recipeUpdated or {}
  local old=record.recipes[prof]
  if old and #recipes<#old then return end
  local changed=not old or #old~=#recipes
  if not changed then for i,name in ipairs(recipes) do if old[i]~=name then changed=true; break end end end
  if changed then
    record.recipes[prof]=recipes; record.recipeUpdated[prof]=now()
    queueRecipes(prof)
    log('Scanned '..#recipes..' visible '..prof..' recipes; queued guild sharing.')
  end
  requestUpdate()
end
scanRecipes=function()
  scanTradeSkill()
  scanCraft()
end
local function doSync()
  save(); announce(true); addonSend('Q|'..key()); recipeSend('R|'..key()); shareAllRecipes(); requestUpdate()
  log('Guild sync request sent.')
end
local function doRefresh()
  save(); announce(true); scanRecipes(); requestUpdate()
  log('Local professions refreshed and shared.')
end

-- Active addon users: guildmates heard from this session who are still online.
local function refreshRoster()
  wipe(guildOnline)
  if not (IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo) then return end
  for i=1,GetNumGuildMembers() do
    local name,_,_,_,_,_,_,_,online=GetGuildRosterInfo(i)
    if name and online then guildOnline[shortName(name)]=true end
  end
end
local function requestRoster()
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
  elseif GuildRoster then GuildRoster() end
end
local function activeUsers()
  local me=UnitName('player') or 'You'
  local list={me}
  local rosterKnown=next(guildOnline)~=nil
  for name in pairs(activeSeen) do
    if name~=me and (not rosterKnown or guildOnline[name]) then list[#list+1]=name end
  end
  table.sort(list)
  return list
end
local function markSeen(sender)
  local name=shortName(sender)
  if name and not activeSeen[name] then activeSeen[name]=true; if refreshMinimap then refreshMinimap() end end
end

-- Display helpers
local function updatedLabel(timestamp)
  if not timestamp or timestamp<=0 then return 'unknown' end
  local age=math.max(0,now()-timestamp)
  if age<60 then return 'just now' end
  if age<3600 then return math.floor(age/60)..'m ago' end
  if age<86400 then return math.floor(age/3600)..'h ago' end
  return math.floor(age/86400)..'d ago'
end
local function rankColor(rank)
  if rank>=300 then return 1,.5,0 end
  if rank>=225 then return .64,.21,.93 end
  if rank>=150 then return 0,.44,.87 end
  if rank>=75 then return .12,1,0 end
  return .62,.62,.62
end
local function rankTitle(max)
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
local function recipeIcon(prof,info)
  if info and info.icon then return info.icon end
  local kind,id=splitLink(info and info.link)
  if kind=='i' then return itemIcon(id) or QUESTION_ICON end
  if kind=='e' and GetSpellTexture then return GetSpellTexture(id) or professionIcons[prof] end
  return professionIcons[prof] or QUESTION_ICON
end
local function recipeLabel(name,info)
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
local function showLinkTooltip(owner,link)
  local kind,id=splitLink(link)
  if not kind then return false end
  GameTooltip:SetOwner(owner,'ANCHOR_RIGHT')
  GameTooltip:SetHyperlink((kind=='i' and 'item:' or 'enchant:')..id)
  return true
end
local function insertChatLink(link)
  local kind,id=splitLink(link)
  local chatLink
  if kind=='i' then chatLink=select(2,GetItemInfo(id))
  elseif kind=='e' and GetSpellLink then chatLink=GetSpellLink(id) end
  if chatLink and ChatEdit_InsertLink then ChatEdit_InsertLink(chatLink) end
end

-- Guild data per profession
local function gather(prof)
  local crafters,recipes,byName={},{},{}
  for who,record in pairs(db or {}) do
    if type(record)=='table' then
      local skill
      for _,p in ipairs(record.professions or {}) do if p.name==prof then skill=p; break end end
      local known=record.recipes and record.recipes[prof]
      if type(known)~='table' then known=nil end
      if skill or (known and #known>0) then
        local c={key=who,character=who:match('^(.-)%-') or who,rank=skill and tonumber(skill.rank) or 0,max=skill and tonumber(skill.max) or 0,updated=record.updated,recipeCount=known and #known or 0,isMe=(who==key())}
        crafters[#crafters+1]=c
        for _,name in ipairs(known or {}) do
          if type(name)=='string' then
            local r=byName[name]
            if not r then r={name=name,crafters={}}; byName[name]=r; recipes[#recipes+1]=r end
            r.crafters[#r.crafters+1]=c
            if c.isMe then r.mine=true end
          end
        end
      end
    end
  end
  local byRank=function(a,b)
    if a.rank~=b.rank then return a.rank>b.rank end
    return a.character:lower()<b.character:lower()
  end
  table.sort(crafters,byRank)
  for _,r in ipairs(recipes) do table.sort(r.crafters,byRank) end
  table.sort(recipes,function(a,b) return a.name<b.name end)
  return crafters,recipes
end
local function hasProfession(prof)
  for _,record in pairs(db or {}) do
    if type(record)=='table' then
      for _,p in ipairs(record.professions or {}) do if p.name==prof then return true end end
    end
  end
  return false
end
local function found(text,term) return text and text:lower():find(term,1,true)~=nil end
local function recipeMatches(r,prof,term)
  if term=='' or found(prof,term) or found(r.name,term) then return true end
  for _,c in ipairs(r.crafters) do if found(c.character,term) then return true end end
  for _,reagent in ipairs(r.info and r.info.reagents or {}) do
    if found(reagentName(reagent),term) then return true end
  end
  return false
end
local function professionData(prof,term)
  local crafters,recipes=gather(prof)
  local filter=selectedCrafter[prof]
  local matsOnly=GuildCraftDB and GuildCraftDB.ui.matsOnly
  local d={crafters=crafters,recipes=recipes,fc={},fr={},ready=0,filter=filter}
  for _,c in ipairs(crafters) do
    if term=='' or found(prof,term) or found(c.character,term) then d.fc[#d.fc+1]=c end
    if c.key==filter then d.filterName=c.character end
  end
  for _,r in ipairs(recipes) do
    r.info=recipeInfo and recipeInfo[prof] and recipeInfo[prof][r.name]
    r.times=craftableTimes(r.info)
    if (r.times or 0)>0 then d.ready=d.ready+1 end
    local byFilter=not filter
    if filter then for _,c in ipairs(r.crafters) do if c.key==filter then byFilter=true; break end end end
    if byFilter and recipeMatches(r,prof,term) and (not matsOnly or (r.times or 0)>0) then d.fr[#d.fr+1]=r end
  end
  if filter and not d.filterName then selectedCrafter[prof]=nil; d.filter=nil end
  return d
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
  b.place=fontString(b,'GameFontDisableSmall','RIGHT'); b.place:SetPoint('LEFT',4,0); b.place:SetWidth(24)
  b.name=fontString(b,'GameFontHighlight'); b.name:SetPoint('LEFT',36,0); b.name:SetWidth(176)
  b.bar=CreateFrame('StatusBar',nil,b); b.bar:SetSize(170,13); b.bar:SetPoint('LEFT',220,0)
  b.bar:SetStatusBarTexture('Interface\\TargetingFrame\\UI-StatusBar')
  local barBg=b.bar:CreateTexture(nil,'BACKGROUND'); barBg:SetAllPoints(); barBg:SetColorTexture(0,0,0,.55)
  b.bar.text=fontString(b.bar,'GameFontHighlightSmall','CENTER'); b.bar.text:SetPoint('CENTER',0,0)
  b.recipes=fontString(b,'GameFontHighlightSmall'); b.recipes:SetPoint('LEFT',404,0); b.recipes:SetWidth(110)
  b.updated=fontString(b,'GameFontDisableSmall','RIGHT'); b.updated:SetPoint('RIGHT',-8,0)
  addHighlight(b)
  return b
end
factories.recipe=function()
  local b=CreateFrame('Button',nil,scrollContent)
  b:SetHeight(26)
  b.stripe=b:CreateTexture(nil,'BACKGROUND'); b.stripe:SetAllPoints()
  b.toggle=b:CreateTexture(nil,'ARTWORK'); b.toggle:SetSize(14,14); b.toggle:SetPoint('LEFT',3,0)
  b.iconBorder=b:CreateTexture(nil,'BORDER'); b.iconBorder:SetSize(24,24); b.iconBorder:SetPoint('LEFT',20,0); b.iconBorder:SetColorTexture(0,0,0,.8)
  b.icon=b:CreateTexture(nil,'ARTWORK'); b.icon:SetSize(22,22); b.icon:SetPoint('CENTER',b.iconBorder,'CENTER'); b.icon:SetTexCoord(.07,.93,.07,.93)
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
  b.count=fontString(b,'GameFontHighlightSmall'); b.count:SetPoint('LEFT',250,0); b.count:SetWidth(200)
  addHighlight(b,.25)
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
local function releaseAll()
  for _,pool in pairs(pools) do
    for i=1,#pool do pool[i]:Hide() end
    pool.used=0
  end
end
local function toggleTexture(open)
  return open and 'Interface\\Buttons\\UI-MinusButton-Up' or 'Interface\\Buttons\\UI-PlusButton-Up'
end
local function showCrafterTooltip(owner,prof,c)
  GameTooltip:SetOwner(owner,'ANCHOR_RIGHT')
  GameTooltip:AddLine(c.character..(c.isMe and ' (You)' or ''),1,.82,0)
  GameTooltip:AddLine(prof..'  '..c.rank..' / '..c.max..'  ('..rankTitle(c.max)..')',1,1,1)
  GameTooltip:AddLine(c.recipeCount..' recipes shared',.8,.8,.8)
  GameTooltip:AddLine('Updated '..updatedLabel(c.updated),.6,.6,.6)
  GameTooltip:AddLine(' ')
  GameTooltip:AddLine('Click to show only their recipes',.4,.8,1)
  GameTooltip:Show()
end
local selectTab

update=function()
  if not window or not window:IsShown() then return end
  updatePending=false; sinceUpdate=0
  local term=(searchBox and searchBox:GetText() or ''):lower()
  releaseAll()
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
  local function addSection(id,label,extra,forceOpen)
    local open=forceOpen or not sectionCollapsed[id]
    local b=acquire('section')
    b.toggle:SetTexture(toggleTexture(open))
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
  local function addCrafter(prof,c,place_,clickTabs)
    local b=acquire('crafter')
    stripe=stripe+1
    b.stripe:SetColorTexture(1,1,1,stripe%2==0 and .04 or 0)
    b.selected:SetShown(selectedCrafter[prof]==c.key)
    b.place:SetText(place_..'.')
    b.name:SetText(c.character..(c.isMe and ' |cff40ff40(You)|r' or ''))
    b.bar:SetMinMaxValues(0,math.max(1,c.max))
    b.bar:SetValue(c.rank)
    b.bar:SetStatusBarColor(rankColor(c.rank))
    b.bar.text:SetText(c.rank..' / '..c.max)
    b.recipes:SetText(c.recipeCount>0 and ('|cffffd100'..c.recipeCount..'|r recipes') or '|cff808080no recipes|r')
    b.updated:SetText(updatedLabel(c.updated))
    b:SetScript('OnClick',function()
      releaseSearchFocus()
      selectedCrafter[prof]=(selectedCrafter[prof]~=c.key) and c.key or nil
      if clickTabs then selectTab(prof) else update() end
    end)
    b:SetScript('OnEnter',function(self) showCrafterTooltip(self,prof,c) end)
    b:SetScript('OnLeave',GameTooltip_Hide)
    place(b,20,8)
  end
  local function addRecipe(prof,r)
    local id=prof..'|'..r.name
    local open=recipeOpen[id]==true
    local b=acquire('recipe')
    stripe=stripe+1
    b.stripe:SetColorTexture(1,1,1,stripe%2==0 and .045 or 0)
    b.toggle:SetTexture(toggleTexture(open))
    b.icon:SetTexture(recipeIcon(prof,r.info))
    b.name:SetText(recipeLabel(r.name,r.info))
    local names={}
    for i=1,math.min(2,#r.crafters) do
      local c=r.crafters[i]
      names[#names+1]=c.isMe and '|cff40ff40You|r' or c.character
    end
    local more=#r.crafters>2 and (' +'..(#r.crafters-2)) or ''
    b.crafters:SetText('|cffa0a0a0'..table.concat(names,', ')..more..'|r')
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
      if not showLinkTooltip(self,r.info and r.info.link) then
        GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
        GameTooltip:AddLine(r.name,1,.82,0)
      end
      GameTooltip:AddLine(' ')
      GameTooltip:AddLine('Crafted by '..#r.crafters..' guildmate'..(#r.crafters==1 and '' or 's'),.4,.8,1)
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
      addNote('|cff808080Reagents not shared yet. They appear once a crafter on GuildCraft '..VERSION..'+ opens this profession and syncs.|r',56)
    end
    local list={}
    for _,c in ipairs(r.crafters) do list[#list+1]=(c.isMe and '|cff40ff40You|r' or c.character)..' |cff808080('..c.rank..')|r' end
    addNote('|cffffd100Crafted by:|r '..table.concat(list,', '),56)
    y=y+4
  end

  local selected=selectedTab
  local totalCrafters,totalRecipes=0,0
  if selected=='All' then
    local any=false
    for _,prof in ipairs(professions) do
      local d=professionData(prof,term)
      totalCrafters=totalCrafters+#d.crafters; totalRecipes=totalRecipes+#d.recipes
      local profMatch=term~='' and found(prof,term)
      if term=='' or profMatch or #d.fc>0 or #d.fr>0 then
        any=true
        local h=acquire('profHeader')
        h.icon:SetTexture(professionIcons[prof])
        h.name:SetText(prof)
        local top=d.crafters[1]
        local info=#d.crafters..' crafters'
        if #d.recipes>0 then info=info..'  |cffa0a0a0·|r  '..#d.recipes..' recipes' end
        if top then info=info..'  |cffa0a0a0·|r  Top: |cffffd100'..top.character..'|r ('..top.rank..')' end
        h.info:SetText(info)
        h.icon:SetDesaturated(#d.crafters==0)
        h:SetScript('OnClick',function() releaseSearchFocus(); selectTab(prof) end)
        y=y+2
        place(h,42)
        if term~='' then
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
    headerSub:SetText(string.format('%d crafter entries  ·  %d recipes shared  ·  %d online with GuildCraft',totalCrafters,totalRecipes,#activeUsers()))
  else
    local prof=selected
    local d=professionData(prof,term)
    local searching=term~=''
    if addSection(prof..'|crafters','Crafters',#d.fc..' of '..#d.crafters,searching) then
      if #d.fc==0 then addNote('No guildmates have shared '..prof..' yet.',16) end
      for i,c in ipairs(d.fc) do addCrafter(prof,c,i,false) end
    end
    if craftable[prof] or #d.recipes>0 then
      local extra=#d.fr..' of '..#d.recipes
      if d.filterName then extra='|cffffd100'..d.filterName..'|r only  ·  '..extra end
      if addSection(prof..'|recipes','Recipes',extra,searching) then
        if #d.fr==0 then
          addNote(#d.recipes==0 and 'No recipes shared yet. Open the profession window on a character that knows it.' or 'No recipes match the current filters.',16)
        end
        for _,r in ipairs(d.fr) do addRecipe(prof,r) end
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
    if t.name~='All' then t:GetNormalTexture():SetDesaturated(not hasProfession(t.name)) end
  end
  local guild=(IsInGuild and IsInGuild()) and (GetGuildInfo and GetGuildInfo('player') or 'In guild') or 'Not in guild'
  local queued=#recipeQueue>0 and ('  |  sharing '..#recipeQueue..' queued') or ''
  status:SetText(string.format('|cffffd100%s|r  |  %d syncs  |  %d recipe batches%s',guild,received,recipeReceived,queued))
end

selectTab=function(name)
  selectedTab=name
  if GuildCraftDB then GuildCraftDB.ui.tab=name end
  if scrollFrame then scrollFrame:SetVerticalScroll(0) end
  update()
end

local function makeTab(index,name)
  local t=CreateFrame('CheckButton',nil,window)
  t.name=name
  t:SetSize(32,32)
  t:SetPoint('TOPLEFT',window,'TOPRIGHT',-6,-44-(index-1)*37)
  local bg=t:CreateTexture(nil,'BACKGROUND')
  bg:SetTexture('Interface\\SpellBook\\SpellBook-SkillLineTab'); bg:SetSize(64,64); bg:SetPoint('TOPLEFT',-3,11)
  t:SetNormalTexture(professionIcons[name])
  t:SetHighlightTexture('Interface\\Buttons\\ButtonHilight-Square','ADD')
  t:SetCheckedTexture('Interface\\Buttons\\CheckButtonHilight')
  t:GetCheckedTexture():SetBlendMode('ADD')
  t:SetScript('OnClick',function() releaseSearchFocus(); selectTab(name) end)
  t:SetScript('OnEnter',function(self)
    GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
    GameTooltip:AddLine(name=='All' and 'All Professions' or name,1,.82,0)
    if name~='All' and not hasProfession(name) then GameTooltip:AddLine('No guildmates recorded yet',.6,.6,.6) end
    GameTooltip:Show()
  end)
  t:SetScript('OnLeave',GameTooltip_Hide)
  tabs[#tabs+1]=t
end

local function makeWindow()
  local f=CreateFrame('Frame','GuildCraftWindow',UIParent,BACKDROP_TEMPLATE)
  window=f
  f:SetSize(720,560); f:SetPoint('CENTER'); f:SetFrameStrata('DIALOG'); f:SetToplevel(true)
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag('LeftButton'); f:SetClampedToScreen(true)
  f:SetScript('OnDragStart',f.StartMoving); f:SetScript('OnDragStop',f.StopMovingOrSizing)
  if f.SetBackdrop then
    f:SetBackdrop({bgFile='Interface\\DialogFrame\\UI-DialogBox-Background',edgeFile='Interface\\DialogFrame\\UI-DialogBox-Border',tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
  end
  local tint=f:CreateTexture(nil,'BACKGROUND',nil,1)
  tint:SetPoint('TOPLEFT',11,-12); tint:SetPoint('BOTTOMRIGHT',-12,11); tint:SetColorTexture(.16,.11,.06,.55)
  tinsert(UISpecialFrames,'GuildCraftWindow')

  local banner=f:CreateTexture(nil,'ARTWORK')
  banner:SetTexture('Interface\\DialogFrame\\UI-DialogBox-Header'); banner:SetSize(320,64); banner:SetPoint('TOP',0,12)
  local title=f:CreateFontString(nil,'OVERLAY','GameFontNormal')
  title:SetPoint('TOP',banner,'TOP',0,-14); title:SetText('GuildCraft  |cffa89c84v'..VERSION..'|r')
  local close=CreateFrame('Button',nil,f,'UIPanelCloseButton')
  close:SetPoint('TOPRIGHT',-6,-6)

  local function button(label,width,anchor,fn)
    local b=CreateFrame('Button',nil,f,'UIPanelButtonTemplate')
    b:SetSize(width,22); b:SetPoint(unpack(anchor)); b:SetText(label)
    b:SetScript('OnClick',function(...) releaseSearchFocus(); fn(...) end)
    return b
  end
  local refresh=button('Refresh',80,{'TOPLEFT',22,-36},doRefresh)
  button('Sync Guild',90,{'LEFT',refresh,'RIGHT',6,0},doSync)

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
  matsCheck:SetChecked(GuildCraftDB.ui.matsOnly)
  local matsLabel=f:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
  matsLabel:SetPoint('LEFT',matsCheck,'RIGHT',0,1); matsLabel:SetText('Have mats')
  matsCheck:SetScript('OnClick',function(self) releaseSearchFocus(); GuildCraftDB.ui.matsOnly=self:GetChecked() and true or false; update() end)
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
  scrollFrame=CreateFrame('ScrollFrame','GuildCraftScrollFrame',inset,'UIPanelScrollFrameTemplate')
  scrollFrame:SetPoint('TOPLEFT',8,-8); scrollFrame:SetPoint('BOTTOMRIGHT',-30,8)
  scrollFrame:SetScript('OnMouseDown',releaseSearchFocus)
  scrollContent=CreateFrame('Frame',nil,scrollFrame); scrollContent:SetSize(CONTENT_W,100)
  scrollContent:EnableMouse(true); scrollContent:SetScript('OnMouseDown',releaseSearchFocus)
  scrollFrame:SetScrollChild(scrollContent)

  status=f:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall'); status:SetPoint('BOTTOMLEFT',22,17)
  local hint=f:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); hint:SetPoint('BOTTOMRIGHT',-22,17)
  hint:SetText('Shift-click a recipe or reagent to link it')

  makeTab(1,'All')
  for i,prof in ipairs(professions) do makeTab(i+1,prof) end

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

-- Minimap button: a "GC" bubble with a badge counting guildmates online with GuildCraft.
local function positionMinimap()
  local angle=math.rad(GuildCraftDB.minimap.angle or 200)
  local radius=(Minimap:GetWidth()/2)+10
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint('CENTER',Minimap,'CENTER',math.cos(angle)*radius,math.sin(angle)*radius)
end
local function showMinimapTooltip(self)
  GameTooltip:SetOwner(self,'ANCHOR_LEFT')
  GameTooltip:AddLine('GuildCraft',1,.82,0)
  local users=activeUsers()
  GameTooltip:AddLine(#users..' online with GuildCraft',1,1,1)
  for i=1,math.min(#users,15) do GameTooltip:AddLine('   '..users[i],.55,.9,.55) end
  if #users>15 then GameTooltip:AddLine('   and '..(#users-15)..' more',.6,.6,.6) end
  GameTooltip:AddLine(' ')
  GameTooltip:AddLine('|cffffd100Left-click|r  open GuildCraft',.85,.85,.85)
  GameTooltip:AddLine('|cffffd100Right-click|r  sync with guild',.85,.85,.85)
  GameTooltip:AddLine('|cffffd100Drag|r  move this button',.85,.85,.85)
  GameTooltip:Show()
end
refreshMinimap=function()
  if not minimapButton then return end
  minimapButton.count:SetText(#activeUsers())
  if GameTooltip:IsOwned(minimapButton) then showMinimapTooltip(minimapButton) end
end
local function makeMinimapButton()
  local b=CreateFrame('Button','GuildCraftMinimapButton',Minimap)
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
  text:SetTextColor(1,.82,0); text:SetText('GC')
  local badge=CreateFrame('Frame',nil,b)
  badge:SetSize(15,15); badge:SetPoint('CENTER',b,'TOPLEFT',28,-26); badge:SetFrameLevel(b:GetFrameLevel()+2)
  local badgeBg=badge:CreateTexture(nil,'ARTWORK')
  badgeBg:SetTexture('Interface\\Minimap\\UI-Minimap-Background'); badgeBg:SetAllPoints(); badgeBg:SetVertexColor(.75,.08,.05)
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
      GuildCraftDB.minimap.angle=math.deg(math.atan2(py/scale-my,px/scale-mx))
      positionMinimap()
    end)
  end)
  b:SetScript('OnDragStop',function(self) self:SetScript('OnUpdate',nil) end)
  positionMinimap()
  b:SetShown(not GuildCraftDB.minimap.hide)
  refreshMinimap()
end

SLASH_GUILDCRAFT1='/guildcraft'; SLASH_GUILDCRAFT2='/gcraft'; SLASH_GUILDCRAFT3='/guildprof'
SlashCmdList['GUILDCRAFT']=function(message)
  message=(message or ''):lower():match('^%s*(.-)%s*$')
  if message=='status' then
    local count=0; for _ in pairs(db or {}) do count=count+1 end
    log(string.format('v%s; guild=%s; saved members=%d; messages sent=%d; completed syncs=%d; online with addon=%d',VERSION,tostring(IsInGuild and IsInGuild()),count,sent,received,#activeUsers()))
    log(string.format('recipe batches received=%d; recipe messages sent=%d; queued=%d',recipeReceived,recipeSent,#recipeQueue))
  elseif message=='sync' then doSync()
  elseif message=='refresh' then doRefresh()
  elseif message=='minimap' then
    GuildCraftDB.minimap.hide=not GuildCraftDB.minimap.hide
    if minimapButton then minimapButton:SetShown(not GuildCraftDB.minimap.hide) end
    log('Minimap button '..(GuildCraftDB.minimap.hide and 'hidden' or 'shown')..'.')
  elseif message=='help' then log('/guildcraft opens window; /guildcraft sync exchanges guild records; /guildcraft status reports sync counters; /guildcraft minimap toggles the minimap button.')
  else toggle() end
end
frame:RegisterEvent('PLAYER_LOGIN'); frame:RegisterEvent('SKILL_LINES_CHANGED')
frame:RegisterEvent('CHAT_MSG_ADDON'); frame:RegisterEvent('PLAYER_GUILD_UPDATE')
frame:RegisterEvent('TRADE_SKILL_SHOW'); frame:RegisterEvent('TRADE_SKILL_UPDATE')
frame:RegisterEvent('CRAFT_SHOW'); frame:RegisterEvent('CRAFT_UPDATE')
frame:RegisterEvent('GUILD_ROSTER_UPDATE'); frame:RegisterEvent('BAG_UPDATE')
frame:RegisterEvent('GET_ITEM_INFO_RECEIVED')
frame:SetScript('OnEvent',function(_,event,...)
  if event=='PLAYER_LOGIN' then
    initDB(); save()
    local register=(C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
    if register then register(PREFIX); register(RECIPE_PREFIX) end
    makeMinimapButton()
    requestRoster()
    log('v'..VERSION..' loaded. Click the GC minimap button or type /guildcraft to open.')
    if C_Timer and C_Timer.After then C_Timer.After(5,function() announce(true); addonSend('Q|'..key()); recipeSend('R|'..key()) end) end
  elseif event=='TRADE_SKILL_SHOW' or event=='TRADE_SKILL_UPDATE' or event=='CRAFT_SHOW' or event=='CRAFT_UPDATE' then
    if C_Timer and C_Timer.After then C_Timer.After(0.3,scanRecipes) else scanRecipes() end
  elseif event=='SKILL_LINES_CHANGED' then
    save(); requestUpdate(); announce(false)
  elseif event=='PLAYER_GUILD_UPDATE' then
    announce(true); addonSend('Q|'..key()); requestRoster(); requestUpdate()
  elseif event=='GUILD_ROSTER_UPDATE' then
    refreshRoster(); refreshMinimap()
  elseif event=='BAG_UPDATE' or event=='GET_ITEM_INFO_RECEIVED' then
    requestUpdate()
  elseif event=='CHAT_MSG_ADDON' then
    local prefix,msg,channel,sender=...
    if channel=='GUILD' and (prefix==PREFIX or prefix==RECIPE_PREFIX) and shortName(sender)~=UnitName('player') then
      markSeen(sender)
    end
    if channel=='GUILD' then
      if prefix==PREFIX then parseMessage(msg,sender); requestUpdate() end
      if prefix==RECIPE_PREFIX then
        if sender and msg:sub(1,2)=='R|' and msg:sub(3):match('^[^-]+')==sender:match('^[^-]+') then
          shareAllRecipes()
        else receiveRecipe(msg,sender) end
      end
    end
  end
end)
frame:SetScript('OnUpdate',function(_,elapsed)
  if #recipeQueue>0 and now()~=0 then
    lastRecipeSend=lastRecipeSend+elapsed
    if lastRecipeSend>=0.25 then
      lastRecipeSend=0
      if IsInGuild and IsInGuild() then recipeSend(table.remove(recipeQueue,1)) end
    end
  end
  -- Coalesce bursts of sync messages and bag events into one redraw.
  sinceUpdate=sinceUpdate+elapsed
  if updatePending and sinceUpdate>=0.2 then update() end
  sinceRoster=sinceRoster+elapsed
  if sinceRoster>=60 then sinceRoster=0; requestRoster() end
end)
print('|cff00ff00GuildCraft: v'..VERSION..' Lua loaded; slash commands registered.|r')
