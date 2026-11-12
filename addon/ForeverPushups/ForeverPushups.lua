-- Forever Pushups
-- Detects deaths, falling deaths and flights, and keeps your exercise tally right inside WoW.
-- /pushups opens the window. Exercises, multipliers and reps per event are editable in Settings,
-- and every entry can be edited or deleted.
-- (Events are also kept in ForeverPushupsDB.events so the website can still import them.)

local ADDON_NAME = ...
local MAX_EVENTS = 1000
local MAX_EXERCISES = 4
local HIT_WINDOW = 20 -- seconds: how recent an attacker must be to blame it for a death

local GOLD = "|cfff0c050"
local GREY = "|cff9c8f78"
local RED = "|cffff6060"
local LABEL = { pve = "PvE Death", pvp = "PvP Death", fall = "Falling Death", flight = "Flight Point" }
local SHORT = { pve = "PvE", pvp = "PvP", fall = "Fall", flight = "Flight" }
local TYPES = { "pve", "pvp", "fall", "flight" }
local DEFAULT_REPS = { pve = 10, pvp = 5, fall = 30, flight = 5 }
local DEFAULT_EXERCISES = {
  { id = "pushups", name = "Pushups",       mult = 1 },
  { id = "squats",  name = "Squats",        mult = 2 },
  { id = "situps",  name = "Situps",        mult = 2 },
  { id = "jacks",   name = "Jumping Jacks", mult = 3 },
}

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

local function round(n) return math.floor(n + 0.5) end
local function repsFor(kind) return (db.reps and db.reps[kind]) or DEFAULT_REPS[kind] or 10 end

-- ---------------------------------------------------------------------------
-- Exercises (db.exercises). The first one is the unit everything is counted in.
-- ---------------------------------------------------------------------------
local function exercises() return db.exercises end
local function base() return db.exercises[1] end
local function exById(id)
  for _, x in ipairs(db.exercises) do if x.id == id then return x end end
end
-- Label for small buttons: "Jumping Jacks" -> "Jacks", "Pushups" -> "Pushups"
local function shortName(x)
  local last = x.name:match("(%S+)%s*$") or x.name
  return #last > 8 and last:sub(1, 8) or last
end
local function multText(m)
  return (m == math.floor(m)) and tostring(m) or string.format("%.1f", m)
end
-- "or 20 squats, 20 situps, 30 jumping jacks"
local function altText(reps)
  local parts = {}
  for i = 2, #db.exercises do
    local x = db.exercises[i]
    parts[#parts + 1] = string.format("%d %s", round(reps * x.mult), x.name:lower())
  end
  return #parts > 0 and ("or " .. table.concat(parts, ", ")) or ""
end

-- ---------------------------------------------------------------------------
-- Entries (db.log)
-- ---------------------------------------------------------------------------
local counter = 0
local function newEvent(kind, info)
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
  local e = newEvent(kind, info)
  -- raw copy for the website
  table.insert(db.events, e)
  while #db.events > MAX_EVENTS do table.remove(db.events, 1) end
  -- tracked entry for the in-game tally
  local entry = { id = e.id, type = kind, reps = repsFor(kind), t = e.t, char = e.char,
    killer = e.killer, dest = e.dest, zone = e.zone, subzone = e.subzone }
  table.insert(db.log, entry)

  local detail = e.killer or e.dest
  local alt = db.exercises[2]
  say(string.format("%s%s|r%s: +%d %s%s. %s/pushups|r to open.",
    GOLD, LABEL[kind] or kind, detail and (" (" .. detail .. ")") or "", entry.reps, base().name:lower(),
    alt and string.format(" (or %d %s)", round(entry.reps * alt.mult), alt.name:lower()) or "", GOLD))
  if UIErrorsFrame then UIErrorsFrame:AddMessage("Forever Pushups: " .. (LABEL[kind] or kind) .. " +" .. entry.reps, 0.94, 0.75, 0.31) end
  Refresh()
  return entry
end

-- Done entries keep a snapshot (doneName, doneReps) so later renames/multiplier changes don't rewrite history.
local function setDone(entry, x, when)
  entry.done, entry.doneAs, entry.doneName = true, x.id, x.name
  entry.doneReps = round(entry.reps * x.mult)
  entry.doneT = when or entry.doneT or time()
end
local function setOwed(entry)
  entry.done, entry.doneAs, entry.doneName, entry.doneReps, entry.doneT = nil, nil, nil, nil, nil
end
local function doneName(entry)
  local x = exById(entry.doneAs)
  return x and x.name or entry.doneName or "?"
end

local function totals()
  local owed, score, owedN = 0, 0, 0
  local by, other = {}, {}
  for _, e in ipairs(db.log) do
    if e.done then
      score = score + e.reps
      if exById(e.doneAs) then
        by[e.doneAs] = (by[e.doneAs] or 0) + (e.doneReps or e.reps)
      else -- done as an exercise that has since been removed
        local n = e.doneName or "?"
        other[n] = (other[n] or 0) + (e.doneReps or e.reps)
      end
    else
      owed = owed + e.reps
      owedN = owedN + 1
    end
  end
  return owed, owedN, score, by, other
end

local function complete(entry, x) setDone(entry, x, time()); Refresh() end
local function undo(entry) setOwed(entry); Refresh() end
local function delete(entry)
  for i, e in ipairs(db.log) do if e == entry then table.remove(db.log, i) break end end
  Refresh()
end
local function completeAll(x)
  local now = time()
  for _, e in ipairs(db.log) do if not e.done then setDone(e, x, now) end end
  Refresh()
end

-- "Menethil Harbor, Wetlands" -> "Wetlands"
local function destZone(dest)
  if not dest or dest == "" then return nil end
  return dest:match(",%s*([^,]+)$") or dest
end
local function flightZone(e)
  if e.landed and e.zone and e.zone ~= "" then return e.zone end
  return destZone(e.dest) or (e.zone and e.zone ~= "" and e.zone) or "Unknown"
end

local function detailOf(e) return e.type == "flight" and e.dest or e.killer end
local function entryTitle(e)
  local what = detailOf(e)
  return (LABEL[e.type] or e.type) .. ((what and what ~= "") and (GREY .. " – |r" .. what) or "")
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
-- UI helpers
-- ---------------------------------------------------------------------------
local W, bar, editor
local PAD, CONTENT_W = 14, 412
local currentTab = "owed"
local tabs, panels = {}, {}

local function backdrop(f, alpha)
  f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  f:SetBackdropColor(0.08, 0.07, 0.05, alpha or 0.95)
  f:SetBackdropBorderColor(0.66, 0.52, 0.18, 1)
end

local function button(parent, w, h, label, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, h)
  b:SetText(label)
  b:SetScript("OnClick", onClick)
  return b
end

local function text(parent, font, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

-- Text box. onCommit(box, text) runs on Enter or when it loses focus; Escape restores via getValue.
local function input(parent, w, numeric, getValue, onCommit)
  local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  e:SetSize(w, 20)
  e:SetAutoFocus(false)
  e:SetMaxLetters(numeric and 5 or 40)
  local committing = false
  local function commit(box)
    if committing then return end
    committing = true
    if onCommit then onCommit(box, box:GetText()) end
    box:ClearFocus()
    committing = false
  end
  e:SetScript("OnEnterPressed", commit)
  e:SetScript("OnEditFocusLost", commit)
  e:SetScript("OnEscapePressed", function(box)
    if getValue then box:SetText(getValue() or "") end
    committing = true; box:ClearFocus(); committing = false
  end)
  return e
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

-- ---------------------------------------------------------------------------
-- Entry editor
-- ---------------------------------------------------------------------------
local function openEditor(entry)
  local E = editor
  E.entry = entry
  E.type = entry.type
  E.status = entry.done and (exById(entry.doneAs) and entry.doneAs or "keep") or "owed"
  E.typeBtn:SetText(LABEL[E.type])
  E.detail:SetText(detailOf(entry) or "")
  E.zone:SetText(entry.type == "flight" and flightZone(entry) or (entry.zone or ""))
  E.reps:SetText(tostring(entry.reps))
  E.delBtn.armed = false
  E.delBtn:SetText("Delete")
  E:Update()
  E:Show()
end

local function buildEditor()
  local E = CreateFrame("Frame", "ForeverPushupsEditor", UIParent, "BackdropTemplate")
  E:SetSize(340, 250)
  E:SetFrameStrata("DIALOG")
  E:SetPoint("CENTER")
  E:SetClampedToScreen(true)
  E:SetMovable(true)
  E:EnableMouse(true)
  E:RegisterForDrag("LeftButton")
  E:SetScript("OnDragStart", E.StartMoving)
  E:SetScript("OnDragStop", E.StopMovingOrSizing)
  backdrop(E, 0.98)
  E:Hide()
  tinsert(UISpecialFrames, "ForeverPushupsEditor")

  local title = text(E, "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("Edit entry")

  local function label(y, s)
    local l = text(E, "GameFontHighlight")
    l:SetPoint("TOPLEFT", 16, y)
    l:SetText(s)
    return l
  end

  label(-44, "Event")
  E.typeBtn = button(E, 150, 22, "", function()
    for i, k in ipairs(TYPES) do
      if k == E.type then E.type = TYPES[i % #TYPES + 1] break end
    end
    E.typeBtn:SetText(LABEL[E.type])
    E:Update()
  end)
  E.typeBtn:SetPoint("TOPLEFT", 120, -40)

  E.detailLabel = label(-74, "Killed by")
  E.detail = input(E, 190, false)
  E.detail:SetPoint("TOPLEFT", 126, -70)

  label(-104, "Zone")
  E.zone = input(E, 190, false)
  E.zone:SetPoint("TOPLEFT", 126, -100)

  E.repsLabel = label(-134, "Owed")
  E.reps = input(E, 50, true, nil, function() E:Update() end)
  E.reps:SetPoint("TOPLEFT", 126, -130)

  label(-164, "Status")
  E.statusBtn = button(E, 190, 22, "", function()
    -- cycle: owed -> done as each exercise -> owed
    local order = { "owed" }
    for _, x in ipairs(exercises()) do order[#order + 1] = x.id end
    if E.status == "keep" then order[#order + 1] = "keep" end
    for i, s in ipairs(order) do
      if s == E.status then E.status = order[i % #order + 1] break end
    end
    E:Update()
  end)
  E.statusBtn:SetPoint("TOPLEFT", 120, -160)

  E.save = button(E, 90, 22, "Save", function()
    local e = E.entry
    local wasType = e.type
    e.type = E.type
    local d = E.detail:GetText():match("^%s*(.-)%s*$")
    if e.type == "flight" then e.dest = d ~= "" and d or nil; e.killer = nil
    else e.killer = d ~= "" and d or nil; if wasType == "flight" then e.dest = nil end end
    local z = E.zone:GetText():match("^%s*(.-)%s*$")
    if z ~= "" then e.zone = z; if e.type == "flight" then e.landed = true end end
    local n = tonumber(E.reps:GetText())
    if n and n > 0 then e.reps = round(n) end
    if E.status == "owed" then
      setOwed(e)
    elseif E.status ~= "keep" and exById(E.status) then
      setDone(e, exById(E.status))
    end -- "keep": done as an exercise that was removed, left as it was
    E:Hide()
    Refresh()
  end)
  E.save:SetPoint("BOTTOMLEFT", 14, 14)

  E.delBtn = button(E, 120, 22, "Delete", function(b)
    if not b.armed then b.armed = true; b:SetText("Click to confirm") return end
    delete(E.entry)
    E:Hide()
  end)
  E.delBtn:SetPoint("BOTTOM", 0, 14)

  local cancel = button(E, 90, 22, "Cancel", function() E:Hide() end)
  cancel:SetPoint("BOTTOMRIGHT", -14, 14)

  function E:Update()
    -- the exercise picked here may have just been removed in Settings
    if E.status ~= "owed" and E.status ~= "keep" and not exById(E.status) then
      E.status = (E.entry.done and not exById(E.entry.doneAs)) and "keep" or "owed"
    end
    E.detailLabel:SetText(E.type == "flight" and "Flew to" or "Killed by")
    local reps = tonumber(E.reps:GetText()) or E.entry.reps
    E.repsLabel:SetText("Owed (" .. base().name:lower() .. ")")
    if E.status == "owed" then
      E.statusBtn:SetText("Still owed")
    elseif E.status == "keep" then
      E.statusBtn:SetText(string.format("Done: %d %s", E.entry.doneReps or reps, (E.entry.doneName or "?"):lower()))
    else
      local x = exById(E.status)
      E.statusBtn:SetText(string.format("Done: %d %s", round(reps * x.mult), x.name:lower()))
    end
  end

  editor = E
end

-- ---------------------------------------------------------------------------
-- Main window
-- ---------------------------------------------------------------------------
local owedRows, doneRows = {}, {}
local EXB_W = 76 -- width of each "10 Pushups" button

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
  for j = 1, MAX_EXERCISES do
    local b = button(r, EXB_W, 20, "", function()
      local x = exercises()[j]
      if r.entry and x then complete(r.entry, x) end
    end)
    b:SetPoint("BOTTOMLEFT", 2 + (j - 1) * (EXB_W + 3), 4)
    r.btns[j] = b
  end
  local del = button(r, 24, 20, "X", function() if r.entry then delete(r.entry) end end)
  del:SetPoint("BOTTOMRIGHT", -2, 4)
  local edit = button(r, 40, 20, "Edit", function() if r.entry then openEditor(r.entry) end end)
  edit:SetPoint("RIGHT", del, "LEFT", -3, 0)
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
  r.title:SetWidth(CONTENT_W - 170)
  r.title:SetWordWrap(false)
  r.amt = text(r, "GameFontNormal", "RIGHT")
  r.amt:SetPoint("TOPRIGHT", -98, -4)
  r.where = text(r, "GameFontDisableSmall")
  r.where:SetPoint("BOTTOMLEFT", 4, 5)
  local u = button(r, 50, 20, "Undo", function() if r.entry then undo(r.entry) end end)
  u:SetPoint("RIGHT", -2, 0)
  local edit = button(r, 40, 20, "Edit", function() if r.entry then openEditor(r.entry) end end)
  edit:SetPoint("RIGHT", u, "LEFT", -3, 0)
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

-- Settings: rebuilt from db each time the tab is shown
local function buildSettings(pt)
  pt.sf, pt.child = makeScroll(pt, 0)
  local c = pt.child
  local y = -4
  local function line(h) local cur = y; y = y - h; return cur end

  local h1 = text(c, "GameFontNormal")
  h1:SetPoint("TOPLEFT", 2, line(24))
  pt.repsHeader = h1

  pt.repInputs = {}
  for _, kind in ipairs(TYPES) do
    local yy = line(28)
    local l = text(c, "GameFontHighlight")
    l:SetPoint("TOPLEFT", 6, yy - 4)
    l:SetText(LABEL[kind])
    local e = input(c, 50, true, function() return tostring(repsFor(kind)) end, function(box, s)
      local n = tonumber(s)
      if n and n > 0 then db.reps[kind] = round(n) end
      box:SetText(tostring(repsFor(kind)))
      Refresh()
    end)
    e:SetPoint("TOPLEFT", 150, yy)
    pt.repInputs[kind] = e
  end
  local n1 = text(c, "GameFontDisableSmall")
  n1:SetPoint("TOPLEFT", 6, line(26) - 2)
  n1:SetText("New amounts apply to new events. Use Edit on an entry to change an old one.")
  n1:SetWidth(CONTENT_W - 10)

  local h2 = text(c, "GameFontNormal")
  h2:SetPoint("TOPLEFT", 2, line(22))
  h2:SetText("Exercises")
  local n2 = text(c, "GameFontDisableSmall")
  n2:SetPoint("TOPLEFT", 6, line(30))
  n2:SetWidth(CONTENT_W - 10)
  n2:SetText("The first one is the unit everything is counted in. The number is how many reps equal one of it (squats x2 = 2 squats per pushup).")

  local hdrName = text(c, "GameFontDisableSmall")
  hdrName:SetPoint("TOPLEFT", 12, line(16))
  hdrName:SetText("Name")
  local hdrMult = text(c, "GameFontDisableSmall")
  hdrMult:SetPoint("LEFT", hdrName, "LEFT", 196, 0)
  hdrMult:SetText("Reps per 1")

  pt.exRows = {}
  for i = 1, MAX_EXERCISES do
    local yy = line(28)
    local row = {}
    row.name = input(c, 180, false, function() local x = exercises()[i]; return x and x.name end, function(box, s)
      local x = exercises()[i]
      s = s:match("^%s*(.-)%s*$")
      if x and s ~= "" then x.name = s end
      Refresh()
    end)
    row.name:SetPoint("TOPLEFT", 12, yy)
    row.x = text(c, "GameFontHighlight")
    row.x:SetPoint("TOPLEFT", 200, yy - 4)
    row.x:SetText("x")
    row.mult = input(c, 44, false, function() local x = exercises()[i]; return x and multText(x.mult) end, function(box, s)
      local x = exercises()[i]
      local n = tonumber(s)
      if x and i > 1 and n and n > 0 and n <= 100 then x.mult = n end
      Refresh()
    end)
    row.mult:SetPoint("TOPLEFT", 214, yy)
    row.baseLabel = text(c, "GameFontDisableSmall")
    row.baseLabel:SetPoint("TOPLEFT", 214, yy - 5)
    row.baseLabel:SetText("1 (base unit)")
    row.remove = button(c, 70, 20, "Remove", function()
      if i > 1 and exercises()[i] then table.remove(db.exercises, i) end
      Refresh()
    end)
    row.remove:SetPoint("TOPLEFT", 274, yy)
    pt.exRows[i] = row
  end
  pt.addEx = button(c, 130, 22, "Add exercise", function()
    if #db.exercises < MAX_EXERCISES then
      table.insert(db.exercises, { id = "ex" .. time() .. math.random(100, 999), name = "New exercise", mult = 1 })
    end
    Refresh()
  end)
  pt.addEx:SetPoint("TOPLEFT", 10, line(30))
  pt.resetEx = button(c, 150, 22, "Reset to defaults", function(b)
    if not b.armed then b.armed = true; b:SetText("Click to confirm") return end
    b.armed = false
    db.exercises = CopyTable and CopyTable(DEFAULT_EXERCISES) or {
      { id = "pushups", name = "Pushups", mult = 1 }, { id = "squats", name = "Squats", mult = 2 },
      { id = "situps", name = "Situps", mult = 2 }, { id = "jacks", name = "Jumping Jacks", mult = 3 } }
    Refresh()
  end)
  pt.resetEx:SetPoint("LEFT", pt.addEx, "RIGHT", 8, 0)
  local n3 = text(c, "GameFontDisableSmall")
  n3:SetPoint("TOPLEFT", 6, line(30) - 2)
  n3:SetWidth(CONTENT_W - 10)
  n3:SetText("Changes don't rewrite reps you already marked done; use Edit on an entry for that.")

  local h3 = text(c, "GameFontNormal")
  h3:SetPoint("TOPLEFT", 2, line(26))
  h3:SetText("Display")
  pt.barBtn = button(c, 180, 22, "", function() db.ui.hideBar = not db.ui.hideBar; Refresh() end)
  pt.barBtn:SetPoint("TOPLEFT", 6, line(30))

  c:SetHeight(-y + 10)
end

local function buildUI()
  W = CreateFrame("Frame", "ForeverPushupsFrame", UIParent, "BackdropTemplate")
  W:SetSize(470, 560)
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
  W.owedSub:SetWidth(470 - PAD * 2)
  W.owedSub:SetWordWrap(false)
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
  for j = 1, MAX_EXERCISES do
    local b = button(po, 76, 20, "", function() local x = exercises()[j]; if x then completeAll(x) end end)
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
  pd.empty:SetText("Nothing completed yet.")
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
  buildSettings(pt)
  panels.settings = pt

  -- small movable "Owed: N" bar; click to open the window
  bar = CreateFrame("Button", "ForeverPushupsBar", UIParent, "BackdropTemplate")
  bar:SetSize(170, 26)
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

  buildEditor()

  W:SetScript("OnShow", function() Refresh() end)
  W:SetScript("OnHide", function() if editor then editor:Hide() end end)
  selectTab("owed")
end

Refresh = function()
  if not W then return end
  local owed, owedN, score, by, other = totals()
  local exs = exercises()
  local unit = base().name:lower()

  bar.text:SetText(owed > 0 and string.format("%s owed: %s%d|r", base().name, RED, owed) or (base().name .. ": all caught up"))
  bar:SetShown(not db.ui.hideBar)
  if editor and editor:IsShown() and editor.entry then editor:Update() end
  if not W:IsShown() then return end

  W.owed:SetText(owed > 0 and string.format("Owed: %s%d|r %s", RED, owed, unit) or "All caught up!")
  W.owedSub:SetText(owed > 0 and altText(owed) or " ")
  local parts = {}
  for _, x in ipairs(exs) do parts[#parts + 1] = string.format("%s%d|r %s", GOLD, by[x.id] or 0, shortName(x):lower()) end
  W.done:SetText("Done: " .. table.concat(parts, " · ") .. string.format("   Score: %s%d|r", GOLD, score))
  for _, kind in ipairs(TYPES) do W.add[kind]:SetText(string.format("%s +%d", SHORT[kind], repsFor(kind))) end
  tabs.owed:SetText(string.format("Owed (%d)", owedN))

  if currentTab == "owed" then
    local p = panels.owed
    for j, b in ipairs(p.all) do
      local x = exs[j]
      b:SetShown(x ~= nil)
      if x then b:SetText(shortName(x)); b:SetEnabled(owedN > 0) end
    end
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
        for j, b in ipairs(r.btns) do
          local x = exs[j]
          b:SetShown(x ~= nil)
          if x then b:SetText(string.format("%d %s", round(e.reps * x.mult), shortName(x))) end
        end
        r:Show()
      end
    end
    for i = n + 1, #owedRows do owedRows[i]:Hide(); owedRows[i].entry = nil end
    p.empty:SetShown(n == 0)
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
      r.amt:SetText(string.format("%d %s", e.doneReps or e.reps, doneName(e):lower()))
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
    for _, x in ipairs(exs) do
      lines[#lines + 1] = string.format("   %s: %s%d|r %s(x%s)|r", x.name, GOLD, by[x.id] or 0, GREY, multText(x.mult))
    end
    for name, v in pairs(other) do lines[#lines + 1] = string.format("   %s: %s%d|r %s(removed)|r", name, GOLD, v, GREY) end
    lines[#lines + 1] = string.format("   Score (in %s): %s%d|r", unit, GOLD, score)
    p.body:SetText(table.concat(lines, "\n"))
    p.child:SetHeight(p.body:GetStringHeight() + 10)

  elseif currentTab == "settings" then
    local p = panels.settings
    p.repsHeader:SetText(base().name .. " owed per event")
    for kind, e in pairs(p.repInputs) do if not e:HasFocus() then e:SetText(tostring(repsFor(kind))) end end
    for i, row in ipairs(p.exRows) do
      local x = exs[i]
      row.name:SetShown(x ~= nil)
      row.x:SetShown(x ~= nil and i > 1)
      row.mult:SetShown(x ~= nil and i > 1)
      row.baseLabel:SetShown(x ~= nil and i == 1)
      row.remove:SetShown(x ~= nil and i > 1)
      if x then
        if not row.name:HasFocus() then row.name:SetText(x.name) end
        if not row.mult:HasFocus() then row.mult:SetText(multText(x.mult)) end
      end
    end
    p.addEx:SetEnabled(#exs < MAX_EXERCISES)
    p.resetEx.armed = false
    p.resetEx:SetText("Reset to defaults")
    p.barBtn:SetText(db.ui.hideBar and "Show the owed bar" or "Hide the owed bar")
  end
end

-- ---------------------------------------------------------------------------
-- Setup / saved data
-- ---------------------------------------------------------------------------
local NAME_TO_ID = { ["Pushups"] = "pushups", ["Squats"] = "squats", ["Situps"] = "situps", ["Jumping Jacks"] = "jacks" }

local function migrate()
  db.events = db.events or {}
  db.reps = db.reps or {}
  db.ui = db.ui or {}
  if not db.exercises or #db.exercises == 0 then
    db.exercises = {}
    for _, x in ipairs(DEFAULT_EXERCISES) do db.exercises[#db.exercises + 1] = { id = x.id, name = x.name, mult = x.mult } end
  end
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
  -- v2 stored doneAs as the exercise's name; v3 uses ids plus a snapshot of what was done
  for _, e in ipairs(db.log) do
    if e.done and not e.doneReps then
      local id = NAME_TO_ID[e.doneAs] or e.doneAs
      local x = exById(id)
      e.doneName = e.doneName or (x and x.name) or e.doneAs
      e.doneAs = id
      e.doneReps = round(e.reps * (x and x.mult or 1))
    end
  end
  db.version = 3
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
