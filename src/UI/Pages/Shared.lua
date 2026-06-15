--[[ UI/Pages/Shared.lua
  Shared UI constants, helpers, section-header widget, content builders, and demo
  fixtures used by the tab shell and all pages. (ns.UI.Shared)
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local S = {}
ns.UI.Shared = S

-- Palette (Plumber-ish warm gold + cream)
S.GOLD  = { 0.83, 0.67, 0.33 }
S.CREAM = { 0.96, 0.90, 0.74 }

S.INDICATOR = {
  ready = "Interface\\COMMON\\Indicator-Green", amber = "Interface\\COMMON\\Indicator-Yellow",
  red   = "Interface\\COMMON\\Indicator-Red",   wait  = "Interface\\COMMON\\Indicator-Gray",
}
S.VERDICT_RGB = {
  ready = { 0.30, 0.85, 0.40 }, amber = { 0.98, 0.78, 0.20 },
  red   = { 0.95, 0.32, 0.32 }, wait  = { 0.70, 0.70, 0.72 },
}
S.VERDICT_LABEL = { ready = "READY", amber = "CHECK", red = "NOT READY", wait = "WAITING" }

S.ICON = {
  durability = "Interface\\Icons\\Trade_BlackSmithing",
  flask      = "Interface\\Icons\\INV_Potion_97",
  food       = "Interface\\Icons\\INV_Misc_Food_15",
  wpn        = "Interface\\Icons\\INV_Stone_SharpeningStone_05",
  rune       = "Interface\\Icons\\INV_Misc_Rune_01",
  bags       = "Interface\\Icons\\INV_Misc_Bag_08",
}
S.I_KEY   = "Interface\\Icons\\INV_Relics_Hourglass"
S.I_VAULT = "Interface\\Icons\\INV_Misc_Treasurechest_Battered"
S.I_LOC   = "Interface\\Icons\\INV_Misc_Map02"
S.I_COORDS = "Interface\\Icons\\INV_Misc_Map_01"
S.I_GOLD  = "Interface\\MoneyFrame\\UI-GoldIcon"
S.I_GEAR  = "Interface\\Icons\\Trade_Engineering"
S.I_SUP   = "Interface\\Icons\\INV_Potion_54"
S.I_QUEST = "Interface\\GossipFrame\\ActiveQuestIcon"
S.I_BOSS  = "Interface\\Icons\\Achievement_Boss_Ragnaros"
S.I_DUNGEON = "Interface\\Icons\\Achievement_ChallengeMode_Gold"
S.I_DEATH = "Interface\\Icons\\Ability_Rogue_FeignDeath"
S.I_TIME  = "Interface\\Icons\\INV_Misc_PocketWatch_01"
S.I_MOB   = "Interface\\Icons\\Ability_DualWield"

S.CLASS_CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
S.HEADER_H = 18 + 6 + 8

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
function S.atlasExists(name)
  return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end
function S.classColor(cls)
  if C_ClassColor and C_ClassColor.GetClassColor and cls and cls ~= "" then
    local c = C_ClassColor.GetClassColor(cls); if c then return c.r, c.g, c.b end
  end
  local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
  if c then return c.r, c.g, c.b end
  return 0.8, 0.8, 0.82
end
function S.hex(r, g, b) return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255) end
-- Inline texture for fontstrings. yOff nudges it down to sit on the text baseline.
function S.inlineIcon(p, sz, yoff)
  sz = sz or 14; yoff = yoff or -3
  return "|T" .. p .. ":" .. sz .. ":" .. sz .. ":0:" .. yoff .. "|t "
end
function S.classDisplayName(cls)
  if cls and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls] then return LOCALIZED_CLASS_NAMES_MALE[cls] end
  return cls or ""
end
function S.specInfo(specID)
  if not specID or specID == 0 then return "", nil end
  local _, name, _, _, role = GetSpecializationInfoByID(specID)
  return name or "", role
end
function S.roleAtlas(role)
  local a = role and ({ TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" })[role]
  if a and S.atlasExists(a) then return a end
  return nil
end
-- Which unit token is our partner (for the live 3D model)?
function S.partnerUnit()
  if ns.db.demoMode or (ns.Comm and ns.Comm.selftest) then return "player" end
  local name = ns.state.partnerName
  if not name then return nil end
  for i = 1, 4 do
    local u = "party" .. i
    if UnitExists(u) and UnitName(u) == name then return u end
  end
  return nil
end

function S.fmtGold(g)
  local n = BreakUpLargeNumbers and BreakUpLargeNumbers(g) or tostring(g)
  return "|cffffffff" .. n .. "|r|cffffd100g|r"
end
-- Truncate the MIDDLE of a string (keeps head + tail) so prefixes/suffixes survive.
function S.midTruncate(s, max)
  if not s then return "" end
  local n = #s
  if n <= max then return s end
  local keep = max - 1
  local head = math.ceil(keep / 2)
  local tail = keep - head
  return s:sub(1, head) .. "…" .. s:sub(n - tail + 1)
end

function S.fmtTime(sec)
  sec = math.floor(sec or 0)
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  if h > 0 then return h .. "h " .. m .. "m" end
  if m > 0 then return m .. "m" end
  return sec .. "s"
end

-- ---------------------------------------------------------------------------
-- Section header (cream label + gold diamond + right-fading gold rule)
-- ---------------------------------------------------------------------------
function S.makeSectionHeader(parent)
  local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  local ff = GameFontHighlight:GetFont()
  if ff then label:SetFont(ff, 17) end
  label:SetTextColor(S.CREAM[1], S.CREAM[2], S.CREAM[3])
  local diamond = parent:CreateTexture(nil, "ARTWORK")
  diamond:SetSize(7, 7); diamond:SetTexture("Interface\\Buttons\\WHITE8X8")
  diamond:SetVertexColor(S.GOLD[1], S.GOLD[2], S.GOLD[3]); diamond:SetRotation(math.rad(45))
  local line = parent:CreateTexture(nil, "ARTWORK")
  line:SetHeight(2); line:SetColorTexture(1, 1, 1, 1)
  if CreateColor then
    line:SetGradient("HORIZONTAL", CreateColor(S.GOLD[1], S.GOLD[2], S.GOLD[3], 0.8), CreateColor(S.GOLD[1], S.GOLD[2], S.GOLD[3], 0.0))
  else
    line:SetVertexColor(S.GOLD[1], S.GOLD[2], S.GOLD[3], 0.5)
  end
  return { label = label, diamond = diamond, line = line }
end

function S.hideHeader(h)
  h.label:Hide(); h.diamond:Hide(); h.line:Hide()
end

-- Style a header (caller has already positioned h.label's TOPLEFT). Anchors the
-- diamond + line beneath the label and sizes the line to colW.
function S.styleHeader(h, title, colW)
  h.label:SetText(title); h.label:Show()
  h.diamond:Show(); h.diamond:ClearAllPoints(); h.diamond:SetPoint("TOPLEFT", h.label, "BOTTOMLEFT", 3, -6)
  h.line:Show(); h.line:ClearAllPoints(); h.line:SetPoint("LEFT", h.diamond, "RIGHT", 6, 0); h.line:SetWidth(colW - 16)
end

-- ---------------------------------------------------------------------------
-- Readiness row values
-- ---------------------------------------------------------------------------
function S.setRowValues(rows, snap)
  local db = ns.db
  local function set(key, ...) if db.show[key] and rows[key] then rows[key]:Set(...) end end
  local slot = snap.durSlot and ns.Snapshot.SLOT_NAMES[snap.durSlot]
  set("durability", "Repairs" .. (slot and (" |cff808080" .. slot .. "|r") or ""), (snap.dur or 0) .. "%", (snap.dur or 100) >= db.thresholds.durability)
  set("flask", "Flask", snap.flask and "active" or "missing", snap.flask)
  set("food", "Food buff", snap.food and "active" or "missing", snap.food)
  set("wpn", "Weapon oil", snap.wpn and "active" or "missing", snap.wpn)
  set("rune", "Aug rune", snap.rune and "active" or "missing", snap.rune)
  set("bags", "Bag space", (snap.bags or 0) .. " free", (snap.bags or 0) > 0)
end

-- ---------------------------------------------------------------------------
-- Content builders (return a string of lines, or "")
-- ---------------------------------------------------------------------------
function S.cActivity(snap)
  local t = {}
  if (snap.key or "") ~= "" and (snap.klvl or 0) > 0 then
    table.insert(t, S.inlineIcon(S.I_KEY) .. "|cffa335ee" .. snap.key .. " +" .. snap.klvl .. "|r")
  end
  if ((snap.vm or 0) + (snap.vr or 0) + (snap.vw or 0)) > 0 then
    table.insert(t, S.inlineIcon(S.I_VAULT) .. "Vault  |cffffffffM+ " .. (snap.vm or 0) .. "/3   Raid " .. (snap.vr or 0) .. "/3|r")
  end
  return table.concat(t, "\n")
end
function S.cStatus(snap)
  local t = {}
  if (snap.zone or "") ~= "" then
    table.insert(t, S.inlineIcon(S.I_LOC) .. snap.zone .. (snap.rest and "  |cff6cb6ff(resting)|r" or ""))
  end
  if (snap.gold or 0) > 0 then table.insert(t, S.inlineIcon(S.I_GOLD) .. S.fmtGold(snap.gold)) end
  return table.concat(t, "\n")
end
function S.cGear(snap)
  local t = {}
  if (snap.enchMask or 0) > 0 then
    local names = {}
    for i, slot in ipairs(ns.Snapshot.ENCHANT_SLOTS) do
      if bit.band(snap.enchMask, 2 ^ (i - 1)) ~= 0 then table.insert(names, ns.Snapshot.SLOT_NAMES[slot] or ("slot" .. slot)) end
    end
    table.insert(t, S.inlineIcon(S.I_GEAR) .. "|cffff8000No enchant:|r " .. table.concat(names, ", "))
  end
  if (snap.gemMiss or 0) > 0 then table.insert(t, S.inlineIcon(S.I_GEAR) .. "|cffff8000Empty sockets:|r " .. snap.gemMiss) end
  local sup = {}
  if (snap.pots or 0) > 0 then table.insert(sup, "Pots x" .. snap.pots) end
  table.insert(sup, "Stone " .. ((snap.hs or 0) > 0 and "|cff44ff44yes|r" or "|cffff5555no|r"))
  if (snap.foodCount or 0) > 0 then table.insert(sup, "Food x" .. snap.foodCount) end
  table.insert(t, S.inlineIcon(S.I_SUP) .. table.concat(sup, "   "))
  return table.concat(t, "\n")
end
function S.cQuest(snap)
  if not (ns.db.show.quest and (snap.qid or 0) ~= 0 and (snap.qname or "") ~= "") then return "" end
  local myQ = (C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()) or 0
  local mismatch = (myQ ~= 0 and snap.qid ~= 0 and myQ ~= snap.qid)
  local q = S.inlineIcon(S.I_QUEST) .. snap.qname
  if (snap.qtotal or 0) > 0 then q = q .. " |cff909090(" .. (snap.qcur or 0) .. "/" .. snap.qtotal .. ")|r" end
  if mismatch then q = q .. "  |cffffcc33(off-quest)|r" end
  return q
end

-- "Now" — current activity + location, compact (for Overview)
function S.cNow(snap)
  local t = {}
  if (snap.zone or "") ~= "" then
    table.insert(t, S.inlineIcon(S.I_LOC) .. snap.zone .. (snap.rest and "  |cff6cb6ff(resting)|r" or ""))
  end
  if (snap.key or "") ~= "" and (snap.klvl or 0) > 0 then
    table.insert(t, S.inlineIcon(S.I_KEY) .. "|cffa335ee" .. snap.key .. " +" .. snap.klvl .. "|r")
  end
  if ((snap.vm or 0) + (snap.vr or 0) + (snap.vw or 0)) > 0 then
    table.insert(t, S.inlineIcon(S.I_VAULT) .. "Vault  |cffffffffM+ " .. (snap.vm or 0) .. "/3   Raid " .. (snap.vr or 0) .. "/3|r")
  end
  if (snap.gold or 0) > 0 then table.insert(t, S.inlineIcon(S.I_GOLD) .. S.fmtGold(snap.gold)) end
  return table.concat(t, "\n")
end

-- Supplies detail (Inventory tab): consumables, bag space, wallet
function S.cSupplies(snap)
  local t = {}
  table.insert(t, S.inlineIcon(S.I_SUP) .. "Combat potions: |cffffffff" .. (snap.pots or 0) .. "|r")
  table.insert(t, S.inlineIcon(S.I_SUP) .. "Healthstone: " .. ((snap.hs or 0) > 0 and "|cff44ff44yes|r" or "|cffff5555no|r"))
  table.insert(t, S.inlineIcon(S.ICON.food) .. "Food: |cffffffff" .. (snap.foodCount or 0) .. "|r")
  table.insert(t, S.inlineIcon(S.ICON.bags) .. "Bag space: |cffffffff" .. (snap.bags or 0) .. " free|r")
  if (snap.gold or 0) > 0 then table.insert(t, S.inlineIcon(S.I_GOLD) .. S.fmtGold(snap.gold)) end
  return table.concat(t, "\n")
end

-- ---------------------------------------------------------------------------
-- Generic vertical "info page" (sections of title + body text). Pools headers
-- and body fontstrings; getSections(snap) returns { {title=, text=}, ... }.
-- ---------------------------------------------------------------------------
function S.makeInfoPage(getSections, emptyText)
  local function build(host)
    local f = CreateFrame("Frame", nil, host); f:SetSize(10, 10)
    f.headers, f.bodies = {}, {}
    f._ff = GameFontHighlight:GetFont()
    return f
  end
  local function ensure(f, i)
    if f.headers[i] then return end
    f.headers[i] = S.makeSectionHeader(f)
    local b = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b:SetJustifyH("LEFT"); b:SetJustifyV("TOP"); b:SetSpacing(7)
    if f._ff then b:SetFont(f._ff, 15) end
    f.bodies[i] = b
  end
  local function refresh(f, ctx)
    local W = ctx.width; f:SetWidth(W)
    local secs = getSections(ctx.snap) or {}
    local prev, h, n = nil, 0, 0
    for i, s in ipairs(secs) do
      n = i; ensure(f, i)
      local hd, bd = f.headers[i], f.bodies[i]
      hd.label:ClearAllPoints()
      if prev then hd.label:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -24)
      else hd.label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0) end
      S.styleHeader(hd, s.title, math.min(W, 520))
      bd:Show(); bd:SetWidth(math.min(W, 520))
      bd:ClearAllPoints(); bd:SetPoint("TOPLEFT", hd.diamond, "BOTTOMLEFT", -3, -12)
      bd:SetText((s.text and s.text ~= "") and s.text or (emptyText or "—"))
      h = h + (prev and 24 or 0) + S.HEADER_H + bd:GetStringHeight()
      prev = bd
    end
    for i = n + 1, #f.headers do S.hideHeader(f.headers[i]); f.bodies[i]:Hide() end
    f:SetHeight(h + 10)
    return h + 10
  end
  return build, refresh
end

-- ---------------------------------------------------------------------------
-- Generic chip-row page. getSections(snap) returns:
--   { { title=, rows = { {icon=, label=, value=}, ... }, text = "optional" }, ... }
-- Rows render with Row.CreateInfo (chip + label + value); text renders as a muted
-- paragraph. Pools all widgets and hides extras between refreshes.
-- ---------------------------------------------------------------------------
function S.makeRowPage(getSections)
  local Row = ns.UI.Row
  local SEC_GAP = 24

  local function build(host)
    local f = CreateFrame("Frame", nil, host); f:SetSize(10, 10)
    f._headers, f._rows, f._bodies = {}, {}, {}
    f._ff = GameFontHighlight:GetFont()
    return f
  end

  local function ensureBody(f, i)
    if f._bodies[i] then return end
    local b = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b:SetJustifyH("LEFT"); b:SetJustifyV("TOP"); b:SetSpacing(7)
    if f._ff then b:SetFont(f._ff, 14) end
    b:SetTextColor(0.7, 0.68, 0.6)
    f._bodies[i] = b
  end

  local function refresh(f, ctx)
    local W = ctx.width; f:SetWidth(W)
    local colW = math.min(W, 600)
    local secs = getSections(ctx.snap) or {}
    local prev, h, hi, ri, bi = nil, 0, 0, 0, 0

    for _, sec in ipairs(secs) do
      hi = hi + 1
      if not f._headers[hi] then f._headers[hi] = S.makeSectionHeader(f) end
      local hd = f._headers[hi]
      hd.label:ClearAllPoints()
      if prev then hd.label:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -SEC_GAP)
      else hd.label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0) end
      S.styleHeader(hd, sec.title, colW)
      h = h + (prev and SEC_GAP or 0) + S.HEADER_H
      local anchor = hd.diamond

      if sec.rows and #sec.rows > 0 then
        for j, it in ipairs(sec.rows) do
          ri = ri + 1
          if not f._rows[ri] then f._rows[ri] = Row.CreateInfo(f, S.I_QUEST) end
          local r = f._rows[ri]
          r:SetShown(true); r:SetWidth(colW); r:SetIcon(it.icon); r:Set(it.label, it.value)
          r:SetHover(it.onEnter, it.onLeave)
          r:SetClick(it.onClick); r:SetSelected(it.selected)
          r.frame:ClearAllPoints()
          r.frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", j == 1 and -3 or 0, j == 1 and -8 or -3)
          anchor = r.frame
        end
        h = h + 8 + #sec.rows * Row.HEIGHT + (#sec.rows - 1) * 3
      end

      if sec.text and sec.text ~= "" then
        bi = bi + 1; ensureBody(f, bi)
        local b = f._bodies[bi]; b:Show(); b:SetWidth(colW)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == hd.diamond and -3 or 0, anchor == hd.diamond and -10 or -10)
        b:SetText(sec.text)
        anchor = b
        h = h + 10 + b:GetStringHeight()
      end
      prev = anchor
    end

    for i = hi + 1, #f._headers do S.hideHeader(f._headers[i]) end
    for i = ri + 1, #f._rows do f._rows[i]:SetShown(false) end
    for i = bi + 1, #f._bodies do f._bodies[i]:Hide() end
    f:SetHeight(h + 12)
    return h + 12
  end

  return build, refresh
end

-- ---------------------------------------------------------------------------
-- Hover-preview + click-to-lock controller for the shared detail pane.
-- Hovering a row previews its detail; clicking locks it (the lock survives hovering
-- other rows); leaving a row restores the locked detail (or clears to the hint),
-- deferred a beat so sliding between rows doesn't flash the restore state between.
--
-- opts.show(key, payload, mode)  render a row's detail. mode is "preview" (hover),
--                                "lock" (click) or "restore" (revert after leave).
-- opts.clear()                   restore the empty/hint pane (default Dashboard.ClearDetail).
-- opts.onLock()                  run after a click changes the lock, e.g. to repaint
--                                the selected-row highlight (default Dashboard.Refresh).
-- opts.revertDelay               seconds before restoring on leave (default 0.05).
--
-- Returns { preview(key, payload), leave(), lock(key, payload), isLocked(key),
-- unlock() }. unlock() drops the lock without touching the pane (pair with a
-- caller-side clear, e.g. on tab re-open).
function S.makePinController(opts)
  opts = opts or {}
  local show = opts.show
  local clear = opts.clear or function() if ns.Dashboard and ns.Dashboard.ClearDetail then ns.Dashboard.ClearDetail() end end
  local onLock = opts.onLock or function() if ns.Dashboard and ns.Dashboard.Refresh then ns.Dashboard.Refresh() end end
  local revertDelay = opts.revertDelay or 0.05

  local lockedKey, lockedPayload, revertTimer
  local ctrl = {}

  function ctrl.preview(key, payload)
    if revertTimer then revertTimer:Cancel(); revertTimer = nil end
    if show then show(key, payload, "preview") end
  end

  function ctrl.leave()
    if revertTimer then revertTimer:Cancel() end
    revertTimer = C_Timer.NewTimer(revertDelay, function()
      revertTimer = nil
      if lockedKey ~= nil then
        if show then show(lockedKey, lockedPayload, "restore") end
      else
        clear()
      end
    end)
  end

  function ctrl.lock(key, payload)
    if revertTimer then revertTimer:Cancel(); revertTimer = nil end
    lockedKey, lockedPayload = key, payload
    if show then show(key, payload, "lock") end
    onLock()
  end

  function ctrl.isLocked(key) return lockedKey == key end

  function ctrl.unlock()
    if revertTimer then revertTimer:Cancel(); revertTimer = nil end
    lockedKey, lockedPayload = nil, nil
  end

  return ctrl
end

-- ---------------------------------------------------------------------------
-- Demo fixtures
-- ---------------------------------------------------------------------------
function S.demoSnap()
  return {
    dur = 41, durSlot = 8, durLowN = 1, bags = 14,
    flask = true, food = true, wpn = false, rune = true, hp = true,
    qid = 1, qcur = 2, qtotal = 3, qpct = 66, qname = "The Dark Below",
    cls = "PALADIN", spec = 65, lvl = 80, ilvl = 632,
    key = "Ara-Kara", klvl = 12, vr = 1, vm = 2, vw = 0,
    zone = "Dornogal", rest = true, gold = 142030, cx = 45.3, cy = 62.1,
    enchMask = 1 + 32, gemMiss = 1, pots = 8, hs = 1, foodCount = 20,
    lastSeen = GetTime(),
    stats = { bosses = 214, dungeons = 96, mplus = 58, togetherTime = 612000, wipes = 38,
      quests = 1843, deaths = 77, mobs = 41250, achievements = 132, levels = 80,
      firstTogether = 1701000000 },
  }
end
function S.demoInv()
  return {
    { link = "item:6948", count = 1 },    -- Hearthstone (Other)
    { link = "item:5512", count = 12 },   -- Healthstone (Consumable)
    { link = "item:159", count = 20 },    -- Refreshing Spring Water (Consumable)
    { link = "item:4536", count = 5 },    -- Shiny Red Apple (Consumable)
    { link = "item:2589", count = 80 },   -- Linen Cloth (Tradegoods)
    { link = "item:2592", count = 60 },   -- Wool Cloth
    { link = "item:4306", count = 40 },   -- Silk Cloth
    { link = "item:14047", count = 25 },  -- Runecloth
    { link = "item:2840", count = 10 },   -- Copper Bar
    { link = "item:2770", count = 15 },   -- Copper Ore
  }
end

-- Quest-log comparison fixtures. ids 1 & 2 overlap (on together); id 4 is
-- partner-only; ids 3 & 5 are you-only.
function S.demoQLogOwn()
  return {
    { id = 1, done = false, cur = 2, total = 3, title = "The Dark Below" },
    { id = 2, done = true,  cur = 1, total = 1, title = "Whispers in the Deep" },
    { id = 3, done = false, cur = 5, total = 8, title = "Spider's Kiss" },
    { id = 5, done = false, cur = 0, total = 4, title = "Hold the Line" },
  }
end
function S.demoQLogPartner()
  return {
    { id = 1, done = true,  cur = 3, total = 3, title = "The Dark Below" },
    { id = 2, done = false, cur = 0, total = 1, title = "Whispers in the Deep" },
    { id = 4, done = false, cur = 1, total = 6, title = "Threads of Fate" },
  }
end

function S.demoStats()
  return { bosses = 214, dungeons = 96, mplus = 58, togetherTime = 612000, wipes = 38,
    quests = 1902, deaths = 64, mobs = 38110, achievements = 140, levels = 80,
    firstTogether = 1701000000,
    mplusRuns = {
      { map = "Ara-Kara", level = 12, onTime = true, ts = 0 },
      { map = "City of Threads", level = 11, onTime = false, ts = 0 },
      { map = "The Stonevault", level = 13, onTime = true, ts = 0 },
      { map = "Mists of Tirna Scithe", level = 15, onTime = true, ts = 0 },
      { map = "The Dawnbreaker", level = 10, onTime = true, ts = 0 },
    } }
end

-- Achievements-together fixtures. Several id+date pairs are shared between own &
-- partner (earned the SAME day → "together"); the rest are one-sided. Demo entries
-- carry display fields (name/points/desc/icon) so the page renders without resolving
-- fabricated ids through GetAchievementInfo.
function S.demoAchvOwn()
  return {
    { id = 33,    y = 2006, m = 11, d = 20, name = "Level 60",                    points = 10, icon = "Interface\\Icons\\Achievement_Level_60",                    desc = "Reach level 60." },
    { id = 2186,  y = 2009, m = 6,  d = 15, name = "Glory of the Ulduar Raider",  points = 25, icon = "Interface\\Icons\\Achievement_Boss_Yoggsaron_01",          desc = "Complete the Glory of the Ulduar Raider meta-achievement." },
    { id = 4602,  y = 2010, m = 12, d = 8,  name = "Fall of the Lich King",       points = 25, icon = "Interface\\Icons\\Achievement_Dungeon_Icecrown_Frostmourne", desc = "Defeat the Lich King in Icecrown Citadel." },
    { id = 11611, y = 2019, m = 2,  d = 2,  name = "Ahead of the Curve: Jaina",   points = 10, icon = "Interface\\Icons\\Achievement_Boss_JainaProudmoore",        desc = "Defeat Lady Jaina Proudmoore on Heroic before the next tier." },
    { id = 545,   y = 2012, m = 10, d = 5,  name = "Pandaria Explorer",           points = 10, icon = "Interface\\Icons\\Achievement_Zone_Pandaria",                desc = "Explore Pandaria, revealing the covered areas of the map." },
  }
end
function S.demoAchvPartner()
  return {
    { id = 33,    y = 2006, m = 11, d = 20, name = "Level 60",                    points = 10, icon = "Interface\\Icons\\Achievement_Level_60",                    desc = "Reach level 60." },
    { id = 2186,  y = 2009, m = 6,  d = 15, name = "Glory of the Ulduar Raider",  points = 25, icon = "Interface\\Icons\\Achievement_Boss_Yoggsaron_01",          desc = "Complete the Glory of the Ulduar Raider meta-achievement." },
    { id = 4602,  y = 2010, m = 12, d = 8,  name = "Fall of the Lich King",       points = 25, icon = "Interface\\Icons\\Achievement_Dungeon_Icecrown_Frostmourne", desc = "Defeat the Lich King in Icecrown Citadel." },
    { id = 11611, y = 2019, m = 2,  d = 2,  name = "Ahead of the Curve: Jaina",   points = 10, icon = "Interface\\Icons\\Achievement_Boss_JainaProudmoore",        desc = "Defeat Lady Jaina Proudmoore on Heroic before the next tier." },
    { id = 965,   y = 2015, m = 7,  d = 1,  name = "The Loremaster",              points = 50, icon = "Interface\\Icons\\Achievement_Quests_Completed_08",         desc = "Complete the Loremaster meta-achievement." },
  }
end

return S
