-- Forever Pushups
-- Detects deaths, falling deaths and flights, and keeps your pushup tally right inside WoW.
-- /pushups opens the window. Squats and situps count x2, jumping jacks x3.
-- (Events are also kept in ForeverPushupsDB.events so the website can still import them.)

local ADDON_NAME = ...
local MAX_EVENTS = 1000
local HIT_WINDOW = 20 -- seconds: how recent an attacker must be to blame it for a death

local GOLD = "|cfff0c050"
local GREY = "|cff9c8f78"
local LABEL = { pve = "PvE Death", pvp = "PvP Death", fall = "Falling Death", flight = "Flight Point" }
local SHORT = { pve = "PvE", pvp = "PvP", fall = "Fall", flight = "Flight" }
local TYPES = { "pve", "pvp", "fall", "flight" }
local DEFAULT_REPS = { pve = 10, pvp = 5, fall = 30, flight = 5 }

-- Every event owes pushups; it can be paid off in any of these. mult = reps per pushup owed.
local EX = {
  { name = "Pushups",       mult = 1, short = "Push" },
  { name = "Squats",        mult = 2, short = "Squat" },
  { name = "Situps",        mult = 2, short = "Situp" },
  { name = "Jumping Jacks", mult = 3, short = "Jacks" },
}
local MULT = {}
for _, x in ipairs(EX) do MULT[x.name] = x.mult end

local db
local Refresh = function() end -- set once the UI exists

local function say(msg)
  DEFAULT_CHAT_FRAME:AddMessage(GOLD .. "Forever Pushups:|r " .. msg)
end

-- Call fn safely; nil if it errors or the value is "secret" (Forever hides some unit info).
local function safe(fn, ...)
  if not fn then return nil end
  local ok, v = pcall(fn, ...)
  if not ok then return nil end
  if issecretvalue and issecretvalue(v) then return nil end
  return v
end

local function realmName()
  local r = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or ""
  return (r:gsub("[%s%-']", ""))
end

local function repsFor(kind) return (db.reps and db.reps[kind]) or DEFAULT_REPS[kind] or 10 end

-- ---------------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------------
local counter = 0
local function newEntry(kind, info)
  counter = counter + 1
  local e = {
    id = string.format("%s-%s-%d-%d-%d", UnitName("player") or "?", realmName(), time(), counter, math.random(1000, 9999)),
    type = kind, t = time(),
    char = UnitName("player"), realm = realmName(),
    zone = GetRealZoneText() or GetZoneText(), subzone = GetSubZoneText(),
  }
  for k, v in pairs(info or {}) do e[k] = v end
  return e
end

local function record(kind, info)
  if not db then return end
  local e = newEntry(kind, info)
  -- raw copy for the website
  table.insert(db.events, e)
  while #db.events > MAX_EVENTS do table.remove(db.events, 1) end
  -- tracked entry for the in-game tally
  local entry = { id = e.id, type = kind, reps = repsFor(kind), t = e.t, char = e.char,
    killer = e.killer, dest = e.dest, zone = e.zone, subzone = e.subzone }
  table.insert(db.log, entry)

  local detail = e.killer or e.dest
  say(string.format("%s%s|r%s: +%d pushups (or %d squats). %s/pushups|r to open.",
    GOLD, LABEL[kind] or kind, detail and (" (" .. detail .. ")") or "", entry.reps, entry.reps * 2, GOLD))
  if UIErrorsFrame then UIErrorsFrame:AddMessage("Forever Pushups: " .. (LABEL[kind] or kind) .. " +" .. entry.reps, 0.94, 0.75, 0.31) end
  Refresh()
  return entry
end

local function doneReps(entry) return entry.reps * (MULT[entry.doneAs] or 1) end

local function totals()
  local owed, score, owedN = 0, 0, 0
  local by = {}
  for _, x in ipairs(EX) do by[x.name] = 0 end
  for _, e in ipairs(db.log) do
    if e.done then
      score = score + e.reps
      by[e.doneAs] = (by[e.doneAs] or 0) + doneReps(e)
    else
      owed = owed + e.reps
      owedN = owedN + 1
    end
  end
  return owed, owedN, score, by
end

local function complete(entry, exName)
  entry.done, entry.doneAs, entry.doneT = true, exName, time()
  Refresh()
end
local function undo(entry)
  entry.done, entry.doneAs, entry.doneT = nil, nil, nil
  Refresh()
end
local function delete(entry)
  for i, e in ipairs(db.log) do if e == entry then table.remove(db.log, i) break end end
  Refresh()
end
local function completeAll(exName)
  local now = time()
  for _, e in ipairs(db.log) do if not e.done then e.done, e.doneAs, e.doneT = true, exName, now end end
  Refresh()
end

-- "Menethil Harbor, Wetlands" -> "Wetlands"
local function destZone(dest)
  if not dest then return nil end
  return dest:match(",%s*([^,]+)$") or dest
end
local function flightZone(e)
  if e.landed and e.zone and e.zone ~= "" then return e.zone end
  return destZone(e.dest) or (e.zone ~= "" and e.zone) or "Unknown"
end

local function entryTitle(e)
  local what = e.killer or e.dest
  return (LABEL[e.type] or e.type) .. (what and (GREY .. " – |r" .. what) or "")
end
local function entryWhere(e)
  local place = e.type == "flight" and flightZone(e) or e.zone or ""
  return place .. "  " .. date("%b %d %H:%M", e.doneT or e.t)
end

-- ---------------------------------------------------------------------------
-- Death detection (no combat log on Forever: watch falls + who is attacking us)
-- ---------------------------------------------------------------------------
local FALL_MIN = 1.0      -- seconds in the air before it counts as a real fall (a jump is ~0.7s)
local FALL_RECENT = 2.0   -- death must come within this long after landing
local DEATH_DEBOUNCE = 30 -- Forever fires PLAYER_DEAD twice per death; count it once
local fallStart, lastLongFall, lastPvp, lastMob, lastDeathAt

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

local SCAN_UNITS = { "target", "focus", "mouseover" }
for i = 1, 40 do SCAN_UNITS[#SCAN_UNITS + 1] = "nameplate" .. i end

local function scanAttackers()
  local now = GetTime()
  local gotMob = false
  for _, u in ipairs(SCAN_UNITS) do
    local name, pvp = attacker(u)
    if name or pvp ~= nil then
      if pvp then lastPvp = { name = name, at = now }
      elseif not gotMob then lastMob = { name = name, at = now }; gotMob = true end
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
  if lastDeathAt and now - lastDeathAt < DEATH_DEBOUNCE then return end
  lastDeathAt = now
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

-- ---------------------------------------------------------------------------
-- Flights: log when you actually take off, then note the zone you land in
-- ---------------------------------------------------------------------------
local inFlight -- the log entry for the flight we're on

local function onTakeTaxi(index)
  local dest = TaxiNodeName and TaxiNodeName(index)
  if not C_Timer then record("flight", { dest = dest }) return end
  local tries = 0
  local function check()
    tries = tries + 1
    if safe(UnitOnTaxi, "player") then
      inFlight = record("flight", { dest = dest })
    elseif tries < 4 then
      C_Timer.After(1.5, check)
    end -- never took off (no money, closed the map...), so nothing is logged
  end
  C_Timer.After(1, check)
end

local function watchLanding()
  if inFlight and not safe(UnitOnTaxi, "player") then
    inFlight.zone = GetRealZoneText() or inFlight.zone
    inFlight.landed = true
    inFlight = nil
    Refresh()
  end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------
local W, bar
local PAD, CONTENT_W = 14, 412
local currentTab = "owed"
local tabs, panels = {}, {}

local function backdrop(f, alpha)
  f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  f:SetBackdropColor(0.08, 0.07, 0.05, alpha or 0.95)
  f:SetBackdropBorderColor(0.66, 0.52, 0.18, 1)
end

local function button(parent, w, h, text, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, h)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function text(parent, font, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

local function savePos(f, key)
  local point, _, relPoint, x, y = f:GetPoint()
  db.ui[key] = { point, relPoint, x, y }
end
local function loadPos(f, key, default)
  local p = db.ui[key]
  f:ClearAllPoints()
  if p then f:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else f:SetPoint(unpack(default)) end
end

local function makeScroll(parent, top)
  local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 0, top)
  sf:SetPoint("BOTTOMRIGHT", -26, 0)
  local child = CreateFrame("Frame", nil, sf)
  child:SetSize(CONTENT_W, 1)
  sf:SetScrollChild(child)
  return sf, child
end

local function divider(row)
  local t = row:CreateTexture(nil, "BACKGROUND")
  t:SetColorTexture(1, 1, 1, 0.07)
  t:SetPoint("BOTTOMLEFT")
  t:SetPoint("BOTTOMRIGHT")
  t:SetHeight(1)
end

-- Owed rows: title, where/when, then one button per exercise + delete
local owedRows, doneRows = {}, {}
local function owedRow(parent, i)
  local r = owedRows[i]
  if r then return r end
  r = CreateFrame("Frame", nil, parent)
  r:SetSize(CONTENT_W, 48)
  r.title = text(r, "GameFontHighlight")
  r.title:SetPoint("TOPLEFT", 4, -4)
  r.title:SetWidth(CONTENT_W - 150)
  r.title:SetWordWrap(false)
  r.where = text(r, "GameFontDisableSmall", "RIGHT")
  r.where:SetPoint("TOPRIGHT", -4, -6)
  r.btns = {}
  for j, x in ipairs(EX) do
    local b = button(r, 84, 20, "", function() if r.entry then complete(r.entry, x.name) end end)
    b:SetPoint("BOTTOMLEFT", 2 + (j - 1) * 87, 4)
    r.btns[j] = b
  end
  local del = button(r, 24, 20, "X", function() if r.entry then delete(r.entry) end end)
  del:SetPoint("BOTTOMRIGHT", -2, 4)
  divider(r)
  owedRows[i] = r
  return r
end

local function doneRow(parent, i)
  local r = doneRows[i]
  if r then return r end
  r = CreateFrame("Frame", nil, parent)
  r:SetSize(CONTENT_W, 38)
  r.title = text(r, "GameFontHighlight")
  r.title:SetPoint("TOPLEFT", 4, -4)
  r.title:SetWidth(CONTENT_W - 140)
  r.title:SetWordWrap(false)
  r.amt = text(r, "GameFontNormal", "RIGHT")
  r.amt:SetPoint("TOPRIGHT", -60, -4)
  r.where = text(r, "GameFontDisableSmall")
  r.where:SetPoint("BOTTOMLEFT", 4, 5)
  local u = button(r, 52, 20, "Undo", function() if r.entry then undo(r.entry) end end)
  u:SetPoint("RIGHT", -2, 0)
  divider(r)
  doneRows[i] = r
  return r
end

local function selectTab(name)
  currentTab = name
  for k, p in pairs(panels) do p:SetShown(k == name) end
  for k, b in pairs(tabs) do if k == name then b:LockHighlight() else b:UnlockHighlight() end end
  Refresh()
end

local function buildUI()
  W = CreateFrame("Frame", "ForeverPushupsFrame", UIParent, "BackdropTemplate")
  W:SetSize(470, 540)
  W:SetFrameStrata("HIGH")
  W:SetClampedToScreen(true)
  W:SetMovable(true)
  W:EnableMouse(true)
  W:RegisterForDrag("LeftButton")
  W:SetScript("OnDragStart", W.StartMoving)
  W:SetScript("OnDragStop", function(f) f:StopMovingOrSizing(); savePos(f, "window") end)
  backdrop(W)
  loadPos(W, "window", { "CENTER", UIParent, "CENTER", 0, 0 })
  W:Hide()
  tinsert(UISpecialFrames, "ForeverPushupsFrame") -- Escape closes it

  local close = CreateFrame("Button", nil, W, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local title = text(W, "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", PAD, -12)
  title:SetText("Forever Pushups")

  W.owed = text(W, "GameFontNormalLarge")
  W.owed:SetPoint("TOPLEFT", PAD, -40)
  W.owedSub = text(W, "GameFontDisableSmall")
  W.owedSub:SetPoint("TOPLEFT", PAD, -60)
  W.done = text(W, "GameFontHighlightSmall")
  W.done:SetPoint("TOPLEFT", PAD, -78)
  W.done:SetWidth(470 - PAD * 2)
  W.done:SetWordWrap(false)

  -- manual buttons, for anything the addon can't see
  local addLabel = text(W, "GameFontDisableSmall")
  addLabel:SetPoint("TOPLEFT", PAD, -100)
  addLabel:SetText("Add by hand:")
  W.add = {}
  for i, kind in ipairs(TYPES) do
    local b = button(W, 108, 22, "", function() record(kind, { manual = true }) end)
    b:SetPoint("TOPLEFT", PAD + (i - 1) * 111, -114)
    W.add[kind] = b
  end

  -- tabs
  local names = { { "owed", "Owed" }, { "done", "Completed" }, { "stats", "Stats" }, { "settings", "Settings" } }
  for i, t in ipairs(names) do
    local b = button(W, 108, 22, t[2], function() selectTab(t[1]) end)
    b:SetPoint("TOPLEFT", PAD + (i - 1) * 111, -148)
    tabs[t[1]] = b
  end

  local function panel()
    local p = CreateFrame("Frame", nil, W)
    p:SetPoint("TOPLEFT", PAD, -178)
    p:SetPoint("BOTTOMRIGHT", -PAD, 14)
    return p
  end

  -- Owed
  local po = panel()
  local allLabel = text(po, "GameFontDisableSmall")
  allLabel:SetPoint("TOPLEFT", 2, -4)
  allLabel:SetText("All done as:")
  po.all = {}
  for j, x in ipairs(EX) do
    local b = button(po, 76, 20, x.short, function() completeAll(x.name) end)
    b:SetPoint("TOPLEFT", 74 + (j - 1) * 80, 0)
    po.all[j] = b
  end
  po.sf, po.child = makeScroll(po, -28)
  po.empty = text(po.child, "GameFontDisable")
  po.empty:SetPoint("TOPLEFT", 4, -8)
  po.empty:SetText("Nothing owed. Go die to something.")
  panels.owed = po

  -- Completed
  local pd = panel()
  pd.sf, pd.child = makeScroll(pd, 0)
  pd.empty = text(pd.child, "GameFontDisable")
  pd.empty:SetPoint("TOPLEFT", 4, -8)
  pd.empty:SetText("No reps completed yet.")
  panels.done = pd

  -- Stats
  local ps = panel()
  ps.sf, ps.child = makeScroll(ps, 0)
  ps.body = text(ps.child, "GameFontHighlight")
  ps.body:SetPoint("TOPLEFT", 4, -4)
  ps.body:SetWidth(CONTENT_W - 8)
  ps.body:SetSpacing(3)
  panels.stats = ps

  -- Settings
  local pt = panel()
  local hdr = text(pt, "GameFontNormal")
  hdr:SetPoint("TOPLEFT", 2, -4)
  hdr:SetText("Pushups per event")
  pt.inputs = {}
  for i, kind in ipairs(TYPES) do
    local l = text(pt, "GameFontHighlight")
    l:SetPoint("TOPLEFT", 6, -10 - i * 28)
    l:SetText(LABEL[kind])
    local e = CreateFrame("EditBox", nil, pt, "InputBoxTemplate")
    e:SetSize(50, 20)
    e:SetPoint("TOPLEFT", 150, -6 - i * 28)
    e:SetAutoFocus(false)
    e:SetNumeric(true)
    e:SetMaxLetters(3)
    local function apply(box)
      local n = tonumber(box:GetText())
      if n and n > 0 then db.reps[kind] = n end
      box:SetText(tostring(repsFor(kind)))
      box:ClearFocus()
      Refresh()
    end
    e:SetScript("OnEnterPressed", apply)
    e:SetScript("OnEditFocusLost", apply)
    e:SetScript("OnEscapePressed", function(box) box:SetText(tostring(repsFor(kind))); box:ClearFocus() end)
    pt.inputs[kind] = e
  end
  local note = text(pt, "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", 6, -10 - 5 * 28)
  note:SetWidth(CONTENT_W)
  note:SetText("Squats and situps count x2, jumping jacks x3. New amounts apply to new events.")
  pt.barBtn = button(pt, 180, 22, "", function()
    db.ui.hideBar = not db.ui.hideBar
    Refresh()
  end)
  pt.barBtn:SetPoint("TOPLEFT", 4, -10 - 6 * 28 - 10)
  panels.settings = pt

  -- small movable "Owed: N" bar; click to open the window
  bar = CreateFrame("Button", "ForeverPushupsBar", UIParent, "BackdropTemplate")
  bar:SetSize(150, 26)
  backdrop(bar, 0.85)
  bar:SetClampedToScreen(true)
  bar:SetMovable(true)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", bar.StartMoving)
  bar:SetScript("OnDragStop", function(f) f:StopMovingOrSizing(); savePos(f, "bar") end)
  bar:SetScript("OnClick", function() W:SetShown(not W:IsShown()) end)
  bar.text = text(bar, "GameFontNormal", "CENTER")
  bar.text:SetPoint("CENTER")
  loadPos(bar, "bar", { "TOP", UIParent, "TOP", 0, -120 })

  W:SetScript("OnShow", function() Refresh() end)
  selectTab("owed")
end

Refresh = function()
  if not W then return end
  local owed, owedN, score, by = totals()

  bar.text:SetText(owed > 0 and string.format("Pushups owed: %s%d|r", "|cffff6060", owed) or "Pushups: all caught up")
  bar:SetShown(not db.ui.hideBar)
  if not W:IsShown() then return end

  W.owed:SetText(owed > 0 and string.format("Owed: |cffff6060%d|r pushups", owed) or "All caught up!")
  W.owedSub:SetText(owed > 0 and string.format("or %d squats / situps, or %d jumping jacks", owed * 2, owed * 3) or " ")
  local parts = {}
  for _, x in ipairs(EX) do parts[#parts + 1] = string.format("%s%d|r %s", GOLD, by[x.name] or 0, x.short:lower()) end
  W.done:SetText("Done: " .. table.concat(parts, " · ") .. string.format("   Score: %s%d|r", GOLD, score))
  for _, kind in ipairs(TYPES) do W.add[kind]:SetText(string.format("%s +%d", SHORT[kind], repsFor(kind))) end
  tabs.owed:SetText(string.format("Owed (%d)", owedN))

  if currentTab == "owed" then
    local p = panels.owed
    local n = 0
    for i = #db.log, 1, -1 do
      local e = db.log[i]
      if not e.done then
        n = n + 1
        local r = owedRow(p.child, n)
        r.entry = e
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 0, -(n - 1) * 48)
        r.title:SetText(entryTitle(e))
        r.where:SetText(entryWhere(e))
        for j, x in ipairs(EX) do r.btns[j]:SetText(string.format("%d %s", e.reps * x.mult, x.short)) end
        r:Show()
      end
    end
    for i = n + 1, #owedRows do owedRows[i]:Hide(); owedRows[i].entry = nil end
    p.empty:SetShown(n == 0)
    for _, b in ipairs(p.all) do b:SetEnabled(n > 0) end
    p.child:SetHeight(math.max(1, n * 48))

  elseif currentTab == "done" then
    local p = panels.done
    local list = {}
    for _, e in ipairs(db.log) do if e.done then list[#list + 1] = e end end
    table.sort(list, function(a, b) return (a.doneT or 0) > (b.doneT or 0) end)
    local n = math.min(#list, 300)
    for i = 1, n do
      local e = list[i]
      local r = doneRow(p.child, i)
      r.entry = e
      r:ClearAllPoints()
      r:SetPoint("TOPLEFT", 0, -(i - 1) * 38)
      r.title:SetText(entryTitle(e))
      r.amt:SetText(string.format("%d %s", doneReps(e), (e.doneAs or "pushups"):lower()))
      r.where:SetText(entryWhere(e))
      r:Show()
    end
    for i = n + 1, #doneRows do doneRows[i]:Hide(); doneRows[i].entry = nil end
    p.empty:SetShown(n == 0)
    p.child:SetHeight(math.max(1, n * 38))

  elseif currentTab == "stats" then
    local p = panels.stats
    local count, zones, zoneList, flights = {}, {}, {}, 0
    for _, e in ipairs(db.log) do
      count[e.type] = (count[e.type] or 0) + 1
      if e.type == "flight" then
        flights = flights + 1
        local z = flightZone(e)
        if not zones[z] then zones[z] = 0; zoneList[#zoneList + 1] = z end
        zones[z] = zones[z] + 1
      end
    end
    table.sort(zoneList, function(a, b) if zones[a] ~= zones[b] then return zones[a] > zones[b] end return a < b end)
    local lines = { GOLD .. "Tally|r" }
    for _, kind in ipairs(TYPES) do lines[#lines + 1] = string.format("   %s: %s%d|r", LABEL[kind], GOLD, count[kind] or 0) end
    lines[#lines + 1] = " "
    lines[#lines + 1] = string.format("%sZones flown to|r  %s(%d zones, %d flights)|r", GOLD, GREY, #zoneList, flights)
    if #zoneList == 0 then lines[#lines + 1] = GREY .. "   No flights yet.|r" end
    for _, z in ipairs(zoneList) do lines[#lines + 1] = string.format("   %s: %s%d|r", z, GOLD, zones[z]) end
    lines[#lines + 1] = " "
    lines[#lines + 1] = GOLD .. "Done|r"
    for _, x in ipairs(EX) do lines[#lines + 1] = string.format("   %s: %s%d|r", x.name, GOLD, by[x.name] or 0) end
    lines[#lines + 1] = string.format("   Score (in pushups): %s%d|r", GOLD, score)
    p.body:SetText(table.concat(lines, "\n"))
    p.child:SetHeight(p.body:GetStringHeight() + 10)

  elseif currentTab == "settings" then
    local p = panels.settings
    for kind, e in pairs(p.inputs) do if not e:HasFocus() then e:SetText(tostring(repsFor(kind))) end end
    p.barBtn:SetText(db.ui.hideBar and "Show the owed bar" or "Hide the owed bar")
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
local function migrate()
  db.events = db.events or {}
  db.reps = db.reps or {}
  db.ui = db.ui or {}
  if not db.log then
    -- first run of the in-game version: bring over earlier detected events (skip tests and doubled deaths)
    db.log = {}
    local last = {}
    for _, e in ipairs(db.events) do
      local dup = e.type ~= "flight" and last[e.type] and math.abs((e.t or 0) - last[e.type]) < 5
      if e.killer ~= "Test Dummy" and not dup and LABEL[e.type] then
        table.insert(db.log, { id = e.id, type = e.type, reps = DEFAULT_REPS[e.type], t = e.t, char = e.char,
          killer = e.killer, dest = e.dest, zone = e.zone, subzone = e.subzone })
      end
      last[e.type] = e.t
    end
  end
  db.version = 2
end

local ticker, scanTicker = 0, 0
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_DEAD")
f:SetScript("OnUpdate", function(_, elapsed)
  ticker = ticker + elapsed
  if ticker >= 0.1 then ticker = 0; watchFalling() end
  scanTicker = scanTicker + elapsed
  if scanTicker >= 0.5 then
    scanTicker = 0
    if safe(UnitAffectingCombat, "player") then scanAttackers() end
    watchLanding()
  end
end)
f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    ForeverPushupsDB = ForeverPushupsDB or {}
    db = ForeverPushupsDB
    migrate()
  elseif event == "PLAYER_LOGIN" then
    if TakeTaxiNode then hooksecurefunc("TakeTaxiNode", onTakeTaxi) end
    buildUI()
    Refresh()
  elseif event == "PLAYER_DEAD" then
    onDeath()
  end
end)

SLASH_FOREVERPUSHUPS1 = "/pushups"
SLASH_FOREVERPUSHUPS2 = "/pu"
SlashCmdList.FOREVERPUSHUPS = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "test" then
    record("pve", { killer = "Test Dummy" })
  elseif msg == "bar" then
    db.ui.hideBar = not db.ui.hideBar
    Refresh()
  elseif msg == "reset" then
    db.ui.window, db.ui.bar = nil, nil
    loadPos(W, "window", { "CENTER", UIParent, "CENTER", 0, 0 })
    loadPos(bar, "bar", { "TOP", UIParent, "TOP", 0, -120 })
    say("Window and bar moved back to the middle of the screen.")
  elseif msg == "help" then
    say("/pushups - open or close the window")
    say("/pushups bar - show or hide the small owed bar")
    say("/pushups reset - move the window and bar back on screen")
    say("/pushups test - log a fake PvE death")
  else
    W:SetShown(not W:IsShown())
  end
end
