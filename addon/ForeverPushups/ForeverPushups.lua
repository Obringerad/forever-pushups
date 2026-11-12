-- Forever Pushups
-- Records PvE deaths, PvP deaths, falling deaths and flights into ForeverPushupsDB.
-- WoW only writes SavedVariables to disk on /reload, logout or exit; the website
-- (obringerad.github.io/forever-pushups) reads that file and adds the reps.

local ADDON_NAME = ...
local MAX_EVENTS = 1000
local HIT_WINDOW = 20 -- seconds: how recent the last hit must be to blame it for a death
local PLAYER_CONTROL = COMBATLOG_OBJECT_CONTROL_PLAYER or 0x00000100

local GOLD = "|cfff0c050"
local LABEL = { pve = "PvE Death", pvp = "PvP Death", fall = "Falling Death", flight = "Flight Point" }

local db
local playerGUID
local lastHit
local sessionCount = 0

local function say(msg)
  DEFAULT_CHAT_FRAME:AddMessage(GOLD .. "Forever Pushups:|r " .. msg)
end

local function realmName()
  local r = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or ""
  return (r:gsub("[%s%-']", ""))
end

local function record(kind, info)
  if not db then return end
  sessionCount = sessionCount + 1
  local e = {
    id = string.format("%s-%s-%d-%d-%d", UnitName("player") or "?", realmName(), time(), sessionCount, math.random(1000, 9999)),
    type = kind,
    t = time(),
    char = UnitName("player"),
    realm = realmName(),
    zone = GetRealZoneText() or GetZoneText(),
    subzone = GetSubZoneText(),
  }
  for k, v in pairs(info or {}) do e[k] = v end
  table.insert(db.events, e)
  while #db.events > MAX_EVENTS do table.remove(db.events, 1) end

  local detail = e.killer or e.dest
  say(string.format("%s%s|r logged%s. Type %s/reload|r to send it to the site.",
    GOLD, LABEL[kind] or kind, detail and (" (" .. detail .. ")") or "", GOLD))
  if UIErrorsFrame then UIErrorsFrame:AddMessage("Forever Pushups: " .. (LABEL[kind] or kind), 0.94, 0.75, 0.31) end
end

-- ---------- deaths ----------
local DAMAGE = {
  SWING_DAMAGE = true, RANGE_DAMAGE = true, SPELL_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true,
  DAMAGE_SHIELD = true, DAMAGE_SPLIT = true, SPELL_INSTAKILL = true,
}

local function onCombatLog()
  local _, sub, _, _, srcName, srcFlags, _, dstGUID = CombatLogGetCurrentEventInfo()
  if dstGUID ~= playerGUID then return end
  if sub == "ENVIRONMENTAL_DAMAGE" then
    local envType = select(12, CombatLogGetCurrentEventInfo())
    lastHit = { at = GetTime(), env = envType and tostring(envType) or "Environment" }
  elseif DAMAGE[sub] then
    lastHit = { at = GetTime(), src = srcName, pvp = bit.band(srcFlags or 0, PLAYER_CONTROL) > 0 }
  end
end

local function titleCase(s)
  s = tostring(s):lower()
  return (s:gsub("^%l", string.upper))
end

local function onDeath()
  local h = lastHit
  if h and GetTime() - h.at > HIT_WINDOW then h = nil end
  lastHit = nil
  if h and h.env then
    if h.env:upper() == "FALLING" then
      record("fall")
    else
      record("pve", { killer = titleCase(h.env) }) -- drowning, lava, fatigue...
    end
  elseif h and h.pvp then
    record("pvp", { killer = h.src })
  else
    record("pve", { killer = h and h.src or nil })
  end
end

-- ---------- flights ----------
local function onTakeTaxi(index)
  local dest = TaxiNodeName and TaxiNodeName(index)
  if not C_Timer then record("flight", { dest = dest }) return end
  local tries = 0
  local function check()
    tries = tries + 1
    if UnitOnTaxi("player") then
      record("flight", { dest = dest })
    elseif tries < 4 then
      C_Timer.After(1.5, check)
    end -- never took off (no money, closed window...), so nothing is logged
  end
  C_Timer.After(1, check)
end

-- ---------- setup ----------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_DEAD")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    ForeverPushupsDB = ForeverPushupsDB or {}
    db = ForeverPushupsDB
    db.version = 1
    db.events = db.events or {}
  elseif event == "PLAYER_LOGIN" then
    playerGUID = UnitGUID("player")
    if TakeTaxiNode then hooksecurefunc("TakeTaxiNode", onTakeTaxi) end
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    onCombatLog()
  elseif event == "PLAYER_DEAD" then
    onDeath()
  end
end)

SLASH_FOREVERPUSHUPS1 = "/pushups"
SlashCmdList.FOREVERPUSHUPS = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "undo" then
    local last = db.events[#db.events]
    if last and sessionCount > 0 then
      table.remove(db.events)
      sessionCount = sessionCount - 1
      say("Removed " .. (LABEL[last.type] or last.type) .. ". /reload to sync.")
    else
      say("Nothing from this session to undo (events already synced can be deleted on the site).")
    end
  elseif msg == "test" then
    record("pve", { killer = "Test Dummy" })
  elseif msg == "sync" then
    ReloadUI()
  else
    say(string.format("%d event(s) logged this session, %d stored.", sessionCount, #db.events))
    say("/pushups sync - reload to send events to the site")
    say("/pushups undo - remove the last event from this session")
    say("/pushups test - log a fake PvE death to test the link")
  end
end
