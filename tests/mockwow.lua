-- Minimal Classic Era stand-in: enough of the WoW API for GuildForge to load, log in, sync and open its window.
-- Set REALM, PLAYER, SKILL, TS_RECIPES or CHAT_RESTRICTED before loading GuildForge.lua to vary a scenario.
frames={}
local function newObj(kind,name)
  local o={__scripts={},__kind=kind,__name=name,__shown=true,__text=''}
  return setmetatable(o,{__index=function(t,k)
    if k=='SetScript' or k=='HookScript' then return function(self,ev,fn) self.__scripts[ev]=fn end end
    if k=='GetScript' then return function(self,ev) return self.__scripts[ev] end end
    if k=='CreateTexture' or k=='CreateFontString' then return function() return newObj('region') end end
    if k=='SetText' then return function(self,v) self.__text=v end end
    if k=='GetText' then return function(self) return self.__text or '' end end
    if k=='Show' then return function(self) self.__shown=true; local f=self.__scripts.OnShow; if f then f(self) end end end
    if k=='Hide' then return function(self) self.__shown=false end end
    if k=='SetShown' then return function(self,v) self.__shown=v and true or false end end
    if k=='IsShown' then return function(self) return self.__shown end end
    if k=='GetWidth' or k=='GetHeight' or k=='GetStringHeight' or k=='GetFrameLevel' or k=='GetEffectiveScale' then return function() return 10 end end
    if k=='GetCenter' then return function() return 0,0 end end
    if k=='HasFocus' or k=='GetChecked' or k=='IsOwned' then return function() return false end end
    if k=='GetNormalTexture' or k=='GetCheckedTexture' or k=='GetFontString' then return function() return newObj('region') end end
    if k=='RegisterEvent' then return function(self,ev) if not KNOWN_EVENTS[ev] then error('Attempt to register unknown event "'..ev..'"') end end end
    return function() return nil end
  end})
end
KNOWN_EVENTS={}
for _,e in ipairs({'PLAYER_LOGIN','SKILL_LINES_CHANGED','CHAT_MSG_ADDON','PLAYER_GUILD_UPDATE','TRADE_SKILL_SHOW','TRADE_SKILL_UPDATE','CRAFT_SHOW','CRAFT_UPDATE','TRAINER_SHOW','TRAINER_UPDATE','UNIT_SPELLCAST_SUCCEEDED','GUILD_ROSTER_UPDATE','BAG_UPDATE','GET_ITEM_INFO_RECEIVED'}) do KNOWN_EVENTS[e]=true end
function CreateFrame(kind,name)
  local f=newObj(kind,name); frames[#frames+1]=f
  if name then _G[name]=f end
  return f
end
UIParent=newObj('Frame'); Minimap=newObj('Frame'); WorldFrame=newObj('Frame')
GameTooltip=newObj('GameTooltip'); ItemRefTooltip=newObj('GameTooltip')
BackdropTemplateMixin={}

CLOCK=1762100000
function time() return math.floor(CLOCK) end
function GetTime() return CLOCK-1762000000 end
timers={}
C_Timer={After=function(s,fn) timers[#timers+1]=fn end}

OUT={}
C_ChatInfo={
  RegisterAddonMessagePrefix=function() return true end,
  SendAddonMessage=function(p,m,c) if #m>255 then error('addon message too long') end OUT[#OUT+1]={p,m}; return true end,
  SendChatMessage=function() end,
}
-- Classic Era answered the Forever lockdown check with a non-boolean; scenarios can mimic that.
if CHAT_RESTRICTED~=nil then C_ChatInfo.AreOutgoingAddonChatMessagesRestricted=function() return CHAT_RESTRICTED end end

ADDON_FOLDER=ADDON_FOLDER or 'GuildForge'
C_AddOns={GetAddOnMetadata=function(name,field)
  if name~=ADDON_FOLDER then error('Couldn\'t find AddOn "'..tostring(name)..'"') end
  return '@project-version@'
end}

REALM=REALM or 'Living Flame'
PLAYER=PLAYER or 'Arcbinky'
SKILL=SKILL or {'First Aid',9,75}
TS_RECIPES=TS_RECIPES or {'Linen Bandage'}
function GetRealmName() return REALM end
function UnitName() return PLAYER end
function IsInGuild() return true end
function GetGuildInfo() return 'Hidden Leaf','Member',3 end
ROSTER=ROSTER or {{'Arcbinky',true},{'Fortbek',true}}
local function packed(name) return name..'-'..REALM:gsub('[^%w]','') end
function GetNumGuildMembers() return #ROSTER end
function GetGuildRosterInfo(i) local r=ROSTER[i]; return packed(r[1]),'Member',3,60,'Warrior','Zone','','',r[2] end
function GetGuildRosterLastOnline() return 0,0,1,4 end
function GetGuildRosterShowOffline() return true end
function GuildRoster() end
function GetNumSkillLines() return 2 end
function GetSkillLineInfo(i) if i==1 then return 'Professions',true end return SKILL[1],false,nil,SKILL[2],nil,nil,SKILL[3] end
function GetTradeSkillLine() return SKILL[1] end
function GetNumTradeSkills() return #TS_RECIPES end
function GetTradeSkillInfo(i) return TS_RECIPES[i],'easy' end
function GetTradeSkillNumReagents() return 1 end
function GetTradeSkillReagentInfo() return 'Linen Cloth',nil,1 end
function GetTradeSkillReagentItemLink() return '|Hitem:2589::|h[Linen Cloth]|h' end
function GetTradeSkillItemLink(i) return '|Hitem:'..(1250+i)..'::|h[x]|h' end
function GetTradeSkillIcon() return 1 end
function GetItemCount() return 0 end
function GetItemInfo() return nil end
function GetItemIcon() return 134400 end
function GetSpellInfo() return 'Spell' end
function GetSpellCooldown() return 0,0 end
function GetItemCooldown() return 0,0 end
function IsPlayerSpell() return false end
function GetCursorPosition() return 0,0 end
function IsModifiedClick() return false end
function GameTooltip_Hide() end
function StaticPopup_Show() end
StaticPopupDialogs={}; YES='Yes'; NO='No'; UISpecialFrames={}; SlashCmdList={}
ITEM_QUALITY_COLORS={}
function wipe(t) for k in pairs(t) do t[k]=nil end return t end
tinsert=table.insert

-- Helpers for the test runner
function GF_TEST_main() for _,f in ipairs(frames) do if f.__scripts.OnEvent then return f end end end
function GF_TEST_fire(...) local f=GF_TEST_main(); f.__scripts.OnEvent(f,...) end
function GF_TEST_tick(dt) CLOCK=CLOCK+dt; local f=GF_TEST_main(); f.__scripts.OnUpdate(f,dt) end
function GF_TEST_timers() local t=timers; timers={}; for _,fn in ipairs(t) do fn() end end
function GF_TEST_outbox() local o=OUT; OUT={}; return o end
function GF_TEST_members()
  local out={}
  for _,bucket in pairs(GuildForgeDB.guilds or {}) do
    for who,r in pairs(bucket.members) do
      local recipes=0
      for _,list in pairs(r.recipes or {}) do recipes=recipes+#list end
      out[who:match('^[^-]+')]={profs=#(r.professions or {}),recipes=recipes}
    end
  end
  return out
end
