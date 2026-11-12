-- Forever Pushups
-- Records PvE deaths, PvP deaths, falling deaths and flights into ForeverPushupsDB.
-- WoW only writes SavedVariables to disk on /reload, logout or exit; the website
-- (obringerad.github.io/forever-pushups) reads that file and adds the reps.

local ADDON_NAME = ...
local MAX_EVENTS = 1000
local HIT_WINDOW = 20 -- seconds: how recent the last hit must be to blame it for a death

local GOLD = "|cfff0c050"
local LABEL = { pve = "PvE Death", pvp = "PvP Death", fall = "Falling Death", flight = "Flight Point" }

local db
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
-- WoW Forever does not let addons read the combat log (registering for it gets the
-- addon blocked), and some unit values can come back as "secret". So instead we:
--   * watch IsFalling() to spot long falls,
--   * keep scanning target + nameplates for whoever is attacking us,
--   * decide PvE / PvP / falling when PLAYER_DEAD fires.

-- Call fn safely; nil if it errors or the value is secret.
local function safe(fn, ...)
  if not fn then return nil end
  local ok, v = pcall(fn, ...)
  if not ok then return nil end
  if issecretvalue and issecretvalue(v) then return nil end
  return v
end

local FALL_MIN = 1.0      -- seconds in the air before it counts as a real fall (a jump is ~0.7s)
local FALL_RECENT = 2.0   -- death must come within this long after landing
local fallStart, lastLongFall
local lastPvp, lastMob    -- { name, at }

local function attacker(unit)
  if not safe(UnitExists, unit) then return end
  if safe(UnitIsDead, unit) then return end
  if not safe(UnitCanAttack, "player", unit) then return end
  if not safe(UnitIsUnit, unit .. "target", "player") then return end
  local name = safe(UnitName, unit)
  if type(name) ~= "string" or name == "" then name = nil end
  local pvp = safe(UnitIsPlayer, unit) or safe(UnitPlayerControlled, unit)
  return name, pvp
end

local function scanAttackers()
  local now = GetTime()
  local units = { "target", "focus", "mouseover" }
  for i = 1, 40 do units[#units + 1] = "nameplate" .. i end
  for _, u in ipairs(units) do
    local name, pvp = attacker(u)
    if name or pvp ~= nil then
      if pvp then lastPvp = { name = name, at = now }
      elseif not lastMob or lastMob.at ~= now then lastMob = { name = name, at = now } end
    end
  end
end

local function watchFalling()
  local now = GetTime()
  if safe(IsFalling, "player") then
    fallStart = fallStart or now
  elseif fallStart then
    if now - fallStart >= FALL_MIN then lastLongFall = now end
    fallStart = nil
  end
end

local function inPvPInstance()
  local _, kind = IsInInstance()
  return kind == "pvp" or kind == "arena"
end

local function onDeath()
  local now = GetTime()
  scanAttackers()
  watchFalling()
  local falling = (fallStart and now - fallStart >= FALL_MIN) or (lastLongFall and now - lastLongFall <= FALL_RECENT)
  local pvp = lastPvp and now - lastPvp.at <= HIT_WINDOW and lastPvp
  local mob = lastMob and now - lastMob.at <= HIT_WINDOW and lastMob
  fallStart, lastLongFall, lastPvp, lastMob = nil, nil, nil, nil

  if falling then
    record("fall")
  elseif pvp or inPvPInstance() then
    record("pvp", { killer = pvp and pvp.name or nil })
  else
    record("pve", { killer = mob and mob.name or nil })
  end
end

local ticker, scanTicker = 0, 0
local function onUpdate(_, elapsed)
  ticker = ticker + elapsed
  if ticker >= 0.1 then ticker = 0; watchFalling() end
  scanTicker = scanTicker + elapsed
  if scanTicker >= 0.5 then
    scanTicker = 0
    if safe(UnitAffectingCombat, "player") then scanAttackers() end
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
f:SetScript("OnUpdate", onUpdate)
f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    ForeverPushupsDB = ForeverPushupsDB or {}
    db = ForeverPushupsDB
    db.version = 1
    db.events = db.events or {}
  elseif event == "PLAYER_LOGIN" then
    if TakeTaxiNode then hooksecurefunc("TakeTaxiNode", onTakeTaxi) end
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
  else
    say(string.format("%d event(s) logged this session, %d stored. Type /reload to send them to the site.", sessionCount, #db.events))
    say("/pushups undo - remove the last event from this session")
    say("/pushups test - log a fake PvE death to test the link")
  end
end
