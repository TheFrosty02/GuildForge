-- GuildCraft 0.9.13 - Classic Era search focus polish
local PREFIX='GCRFT96' -- preserve working profession sync protocol
local RECIPE_PREFIX='GCRFT10'
local frame=CreateFrame('Frame')
local window, status, searchBox, scrollContent
local rowPool, expanded = {}, {}
local recipeExpanded = {}
local recipeQueue, recipePending = {}, {}
local recipeSent, recipeReceived = 0, 0
local lastRecipeSend = 0
local professions={"Engineering","Tailoring","Enchanting","Leatherworking","Blacksmithing","Mining","Skinning","Herbalism","Alchemy","First Aid","Cooking"}
local update
local function releaseSearchFocus()
  if searchBox and searchBox:HasFocus() then searchBox:ClearFocus() end
end
local scanRecipes, queueRecipes
local db, lastBroadcast= nil, 0
local received, sent=0,0
local function log(s) print('|cffd8aa55GuildCraft:|r '..tostring(s)) end
local function realm() return (GetRealmName and GetRealmName()) or 'Unknown' end
local function key() return (UnitName('player') or 'Unknown')..'-'..realm() end
local function now() return (time and time()) or 0 end
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
  db=GuildCraftDB.members
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
      if update then update() end
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
      if update then update() end
    end
    recipePending[pendingKey]=nil
  end
end
local function scanTradeSkill()
  if not (GetNumTradeSkills and GetTradeSkillInfo) then return end
  local prof=GetTradeSkillLine and GetTradeSkillLine()
  if not craftable[prof] then return end
  local recipes,seen={},{}
  for i=1,GetNumTradeSkills() do
    local name,kind=GetTradeSkillInfo(i)
    if name and kind~='header' and not seen[name] then
      seen[name]=true; recipes[#recipes+1]=clean(name)
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
    if update then update() end
  end
end
local function scanCraft()
  if not (GetNumCrafts and GetCraftInfo) then return end
  local prof=GetCraftDisplaySkillLine and GetCraftDisplaySkillLine()
  if not craftable[prof] then return end
  local recipes,seen={},{}
  for i=1,GetNumCrafts() do
    local name,_,kind=GetCraftInfo(i)
    if name and kind~='header' and not seen[name] then seen[name]=true; recipes[#recipes+1]=clean(name) end
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
    if update then update() end
  end
end
scanRecipes=function()
  scanTradeSkill()
  scanCraft()
end

local function matches(name,record,term)
  if term=='' or name:lower():find(term,1,true) then return true end
  for _,p in ipairs(record.professions or {}) do
    if p.name:lower():find(term,1,true) then return true end
  end
  return false
end
local function updatedLabel(timestamp)
  if not timestamp or timestamp<=0 then return 'Update unknown' end
  local age=math.max(0,now()-timestamp)
  if age<60 then return 'Updated just now' end
  if age<3600 then return 'Updated '..math.floor(age/60)..'m ago' end
  if age<86400 then return 'Updated '..math.floor(age/3600)..'h ago' end
  return 'Updated '..math.floor(age/86400)..'d ago'
end
local function getRow(i)
  if rowPool[i] then return rowPool[i] end
  local row={}
  row.header=CreateFrame('Button',nil,scrollContent)
  row.header:SetSize(510,29)
  row.header:SetNormalFontObject('GameFontNormal')
  row.header:SetHighlightFontObject('GameFontHighlight')
  row.header:SetText('')
  -- Text exists after SetText; align without replacing the working button.
  local headerText=row.header:GetFontString()
  if headerText then headerText:SetJustifyH('LEFT') end
  row.headerBackground=row.header:CreateTexture(nil,'BACKGROUND')
  row.headerBackground:SetAllPoints(row.header)
  row.headerBackground:SetColorTexture(.32,.265,.19,.94)
  row.headerHighlight=row.header:CreateTexture(nil,'HIGHLIGHT')
  row.headerHighlight:SetAllPoints(row.header)
  row.headerHighlight:SetColorTexture(.55,.43,.23,.35)
  -- Separate font strings avoid relying on the default centered button label.
  row.headerName=row.header:CreateFontString(nil,'OVERLAY','GameFontNormal')
  row.headerName:SetPoint('LEFT',row.header,'LEFT',12,0)
  row.headerName:SetJustifyH('LEFT')
  row.headerCount=row.header:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
  row.headerCount:SetPoint('RIGHT',row.header,'RIGHT',-14,0)
  row.headerCount:SetJustifyH('RIGHT')
  row.headerName:SetWidth(330)
  row.headerCount:SetWidth(140)
  local edge=row.header:CreateTexture(nil,'ARTWORK')
  edge:SetColorTexture(.65,.48,.25,.85)
  edge:SetPoint('TOPLEFT',row.header,'TOPLEFT',0,0)
  edge:SetPoint('BOTTOMLEFT',row.header,'BOTTOMLEFT',0,0)
  edge:SetWidth(3)
  row.memberButtons={}
  row.detail=scrollContent:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
  row.detail:SetWidth(490)
  row.detail:SetJustifyH('LEFT')
  row.detail:SetJustifyV('TOP')
  rowPool[i]=row
  return row
end
update=function()
  if not window or not window:IsShown() then return end
  local term=(searchBox and searchBox:GetText() or ''):lower()
  for _,row in ipairs(rowPool) do
    row.header:Hide(); row.detail:Hide()
    for _,b in ipairs(row.memberButtons) do b:Hide(); b.recipeDetail:Hide() end
  end
  local y,visible,shownMembers=0,0,0
  local rowIndex=0
  for _,profession in ipairs(professions) do
    local members={}
    for name,record in pairs(db or {}) do
      if type(record)=='table' and type(record.professions)=='table' then
        for _,p in ipairs(record.professions) do
          if p.name==profession then
            local character=name:match('^(.-)%-') or name
            local professionMatch=(term~='' and profession:lower():find(term,1,true)~=nil)
            local characterMatch=(term~='' and name:lower():find(term,1,true)~=nil)
            local recipeMatches={}
            local known=record.recipes and record.recipes[profession]
            if term~='' and type(known)=='table' then
              for _,recipe in ipairs(known) do
                if type(recipe)=='string' and recipe:lower():find(term,1,true) then
                  recipeMatches[#recipeMatches+1]=recipe
                end
              end
            end
            if term=='' or professionMatch or characterMatch or #recipeMatches>0 then
              members[#members+1]={name=name,character=character,rank=tonumber(p.rank) or 0,max=tonumber(p.max) or 0,updated=record.updated,recipeMatches=recipeMatches,recipeSearch=(#recipeMatches>0 and not professionMatch and not characterMatch)}
            end
            break
          end
        end
      end
    end
    -- Always show matching profession names even if nobody has learned them yet.
    local show=(term=='' or profession:lower():find(term,1,true) or #members>0)
    if show then
      table.sort(members,function(a,b)
        if a.rank~=b.rank then return a.rank>b.rank end
        return a.name:lower()<b.name:lower()
      end)
      rowIndex=rowIndex+1
      local row=getRow(rowIndex)
      if rowIndex%2==0 then row.headerBackground:SetColorTexture(.28,.235,.175,.94) else row.headerBackground:SetColorTexture(.35,.29,.205,.94) end
      local open=(expanded[profession]==true) or (term~='')
      row.header:ClearAllPoints()
      row.header:SetPoint('TOPLEFT',scrollContent,'TOPLEFT',4,-y)
      row.header:SetText('')
      row.headerName:SetText((open and '|cffffd78a[-]  |r' or '|cffffd78a[+]  |r')..'|cffffd78a'..profession..'|r')
      row.headerCount:SetText('|cffead8b5'..#members..' members|r')
      row.header:SetScript('OnClick',function()
         releaseSearchFocus()
        expanded[profession]=not (expanded[profession]==true)
        update()
      end)
      row.header:Show()
      y=y+29
      visible=visible+1
      if open then
        if #members==0 then
          row.detail:ClearAllPoints()
          row.detail:SetPoint('TOPLEFT',scrollContent,'TOPLEFT',8,-y)
          row.detail:SetText('    No guild members recorded for this profession.')
          row.detail:Show()
          y=y+23
        end
        for i,m in ipairs(members) do
          local b=row.memberButtons[i]
          if not b then
            b=CreateFrame('Button',nil,scrollContent)
            b:SetSize(505,19)
            b:SetNormalFontObject('GameFontHighlightSmall')
            b:SetHighlightFontObject('GameFontNormalSmall')
            b.recipeDetail=scrollContent:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
            b.recipeDetail:SetWidth(475)
            b.recipeDetail:SetJustifyH('LEFT')
            b.recipeDetail:SetJustifyV('TOP')
            row.memberButtons[i]=b
          end
          local rec=db[m.name]
          local recipes=rec and rec.recipes and rec.recipes[profession]
          local hasRecipes=recipes and #recipes>0
          local choice=profession..'|'..m.name
          local opened=(recipeExpanded[choice]==true) or (m.recipeSearch and recipeExpanded[choice]~=false)
          local suffix=(m.name==key()) and ' (You)' or ''
          local count=hasRecipes and ('  ['..#recipes..' recipes]') or ''
          b:ClearAllPoints()
          b:SetPoint('TOPLEFT',scrollContent,'TOPLEFT',15,-y)
          b:SetText((opened and '[-] ' or '[+] ')..i..'. '..m.character..suffix..'  '..m.rank..' / '..m.max..count..'  |cff999999'..updatedLabel(m.updated)..'|r')
          b:SetScript('OnClick',function()
            releaseSearchFocus()
            recipeExpanded[choice]=not opened
            update()
          end)
          b:Show()
          y=y+20
          if opened then
            local lines={}
            if hasRecipes then
              lines[#lines+1]='Known recipes (last scanned '..updatedLabel(rec.recipeUpdated and rec.recipeUpdated[profession]):gsub('^Updated ','')..'):'
              local displayRecipes=m.recipeSearch and m.recipeMatches or recipes
              for _,recipe in ipairs(displayRecipes) do lines[#lines+1]='  - '..recipe end
            else
              lines[1]='No recipes shared yet. Open this profession on that character to scan.'
            end
            b.recipeDetail:ClearAllPoints()
            b.recipeDetail:SetPoint('TOPLEFT',scrollContent,'TOPLEFT',35,-y)
            b.recipeDetail:SetText(table.concat(lines,'\n'))
            b.recipeDetail:Show()
            y=y+math.max(22,math.ceil(b.recipeDetail:GetStringHeight() or 0))+8
          end
        end
        shownMembers=shownMembers+#members
        y=y+7
      end
      y=y+5
    end
  end
  if visible==0 then
    local row=getRow(1)
    row.header:SetText('')
    row.headerName:SetText('No matching professions, guild members, or known recipes.')
    row.headerCount:SetText('')
    row.header:ClearAllPoints()
    row.header:SetPoint('TOPLEFT',scrollContent,'TOPLEFT',4,0)
    row.header:SetScript('OnClick',nil)
    row.header:Show()
    y=40
  end
  scrollContent:SetHeight(math.max(100,y+10))
  local guild=(IsInGuild and IsInGuild()) and 'In guild' or 'Not in guild'
  status:SetText(string.format('%s  |  %d professions  |  %d syncs received',guild,visible,received))
end

local function makeWindow()
  local f=CreateFrame('Frame','GuildCraftWindow',UIParent)
  f:SetSize(600,465); f:SetPoint('CENTER'); f:SetFrameStrata('DIALOG')
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag('LeftButton')
  f:SetScript('OnDragStart',f.StartMoving); f:SetScript('OnDragStop',f.StopMovingOrSizing)
  local bg=f:CreateTexture(nil,'BACKGROUND'); bg:SetAllPoints(); bg:SetColorTexture(.18,.15,.12,.98)
  local title=f:CreateFontString(nil,'OVERLAY','GameFontNormalLarge')
  title:SetPoint('TOPLEFT',18,-18); title:SetText('|cffe7c483GuildCraft|r  |cffaaa397Classic Era v0.9.18|r')
  local function button(label,x,width,fn)
    local b=CreateFrame('Button',nil,f,'UIPanelButtonTemplate')
    b:SetSize(width,24); b:SetPoint('TOPLEFT',x,-52); b:SetText(label); b:SetScript('OnClick',function(...) releaseSearchFocus(); fn(...) end)
    return b
  end
  button('Refresh',18,80,function() save(); update(); announce(true); scanRecipes(); log('Local professions refreshed and shared.') end)
  button('Sync',106,65,function() save(); announce(true); addonSend('Q|'..key()); recipeSend('R|'..key()); shareAllRecipes(); update(); log('Guild sync request sent.') end)
  local close=CreateFrame('Button',nil,f,'UIPanelButtonTemplate')
  close:SetSize(65,24); close:SetPoint('TOPRIGHT',-16,-14); close:SetText('Close'); close:SetScript('OnClick',function() releaseSearchFocus(); f:Hide() end)
  local searchLabel=f:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
  searchLabel:SetPoint('TOPLEFT',190,-57); searchLabel:SetText('Search:')
  searchBox=CreateFrame('EditBox',nil,f,'InputBoxTemplate')
  searchBox:SetSize(190,22); searchBox:SetPoint('LEFT',searchLabel,'RIGHT',12,0); searchBox:SetAutoFocus(false)
  searchBox:SetScript('OnTextChanged',function() update() end)
  searchBox:SetScript('OnEscapePressed',function(self) self:ClearFocus() end)
  searchBox:SetScript('OnEnterPressed',function(self) self:ClearFocus() end)
  searchBox:SetScript('OnEditFocusLost',function(self) self:HighlightText(0,0) end)
  f:SetScript('OnMouseDown',releaseSearchFocus)
  f:SetScript('OnHide',releaseSearchFocus)
  if WorldFrame and WorldFrame.HookScript then
    WorldFrame:HookScript('OnMouseDown',releaseSearchFocus)
  end
  status=f:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall'); status:SetPoint('TOPLEFT',20,-87)
  local scroll=CreateFrame('ScrollFrame',nil,f,'UIPanelScrollFrameTemplate')
  scroll:SetPoint('TOPLEFT',20,-113); scroll:SetPoint('BOTTOMRIGHT',-36,18)
  scroll:SetScript('OnMouseDown',releaseSearchFocus)
  scrollContent=CreateFrame('Frame',nil,scroll); scrollContent:SetSize(535,100)
  scrollContent:EnableMouse(true); scrollContent:SetScript('OnMouseDown',releaseSearchFocus)
  scroll:SetScrollChild(scrollContent)
  f:Hide(); window=f
end
local function toggle()
  if not window then makeWindow() end
  if window:IsShown() then window:Hide() else save(); window:Show(); update() end
end
SLASH_GUILDCRAFT1='/guildcraft'; SLASH_GUILDCRAFT2='/gcraft'; SLASH_GUILDCRAFT3='/guildprof'
SlashCmdList['GUILDCRAFT']=function(message)
  message=(message or ''):lower():match('^%s*(.-)%s*$')
  if message=='status' then
    local count=0; for _ in pairs(db or {}) do count=count+1 end
    log(string.format('v0.9.18; guild=%s; saved members=%d; messages sent=%d; completed syncs=%d',tostring(IsInGuild and IsInGuild()),count,sent,received))
    log(string.format('recipe batches received=%d; recipe messages sent=%d; queued=%d',recipeReceived,recipeSent,#recipeQueue))
  elseif message=='sync' then save(); announce(true); addonSend('Q|'..key()); recipeSend('R|'..key()); shareAllRecipes(); update(); log('Guild sync request sent.')
  elseif message=='refresh' then save(); update(); announce(true); scanRecipes(); log('Professions refreshed.')
  elseif message=='help' then log('/guildcraft opens window; /guildcraft sync exchanges guild records; /guildcraft status reports sync counters.')
  else toggle() end
end
frame:RegisterEvent('PLAYER_LOGIN'); frame:RegisterEvent('SKILL_LINES_CHANGED')
frame:RegisterEvent('CHAT_MSG_ADDON'); frame:RegisterEvent('PLAYER_GUILD_UPDATE')
frame:RegisterEvent('TRADE_SKILL_SHOW'); frame:RegisterEvent('TRADE_SKILL_UPDATE')
frame:RegisterEvent('CRAFT_SHOW'); frame:RegisterEvent('CRAFT_UPDATE')
frame:SetScript('OnEvent',function(_,event,...)
  if event=='PLAYER_LOGIN' then
    initDB(); save()
    local register=(C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
    if register then register(PREFIX); register(RECIPE_PREFIX) end
    log('v0.9.18 loaded. Type /guildcraft to open; /guildcraft sync to exchange professions.')
    if C_Timer and C_Timer.After then C_Timer.After(5,function() announce(true); addonSend('Q|'..key()); recipeSend('R|'..key()) end) end
  elseif event=='TRADE_SKILL_SHOW' or event=='TRADE_SKILL_UPDATE' or event=='CRAFT_SHOW' or event=='CRAFT_UPDATE' then
    if C_Timer and C_Timer.After then C_Timer.After(0.3,scanRecipes) else scanRecipes() end
  elseif event=='SKILL_LINES_CHANGED' then
    save(); update(); announce(false)
  elseif event=='PLAYER_GUILD_UPDATE' then
    announce(true); addonSend('Q|'..key()); update()
  elseif event=='CHAT_MSG_ADDON' then
    local prefix,msg,channel,sender=...
    if channel=='GUILD' then
      if prefix==PREFIX then parseMessage(msg,sender); update() end
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
end)
print('|cff00ff00GuildCraft: v0.9.18 Lua loaded; slash commands registered.|r')
