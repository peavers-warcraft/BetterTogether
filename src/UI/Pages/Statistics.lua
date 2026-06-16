--[[ UI/Pages/Statistics.lua
  Statistics page. Two columns under a full-width "Adventured Together" tile row:
    left  — You-vs-Partner compare rows (shared/personal counters)
    right — Records (derived milestones) + recent Mythic+ history
]]

local addonName, ns = ...
local S = ns.UI.Shared
local Theme = ns.UI.Theme
local Widgets = ns.UI.Widgets
local Row = ns.UI.Row
local L = ns.L

local SECTION_GAP = Theme.SECTION_GAP
local TILE_H = 116
local COL_GUTTER = 28

local function fmtNum(n) return BreakUpLargeNumbers and BreakUpLargeNumbers(n or 0) or tostring(n or 0) end

-- Big shared tiles (max-merged "together" totals).
local TILE_DEFS = {
  { key = "bosses",   icon = Theme.I_BOSS,    label = L["Bosses"],        time = false },
  { key = "dungeons", icon = Theme.I_DUNGEON, label = L["Dungeons"],      time = false },
  { key = "mplus",    icon = Theme.I_KEY,     label = L["Mythic+"],       time = false },
  { key = "togetherTime", icon = Theme.I_TIME, label = L["Time Together"], time = true },
}

-- You-vs-Partner compare rows. own[key] / partner[key] shown side by side.
local COMPARE_DEFS = {
  { key = "quests",       icon = Theme.I_QUEST, label = L["Quests"] },
  { key = "deaths",       icon = Theme.I_DEATH, label = L["Deaths"] },
  { key = "mobs",         icon = Theme.I_MOB,   label = L["Mobs slain"] },
  { key = "levels",       icon = Theme.I_DUNGEON, label = L["Levels gained"] },
}

-- ---------------------------------------------------------------------------
-- Derived "Records" — milestones computed from the raw counters (no extra
-- tracking). own/partner are the two stat tables; shared(k) is the max-merged
-- "together" value for a shared counter.
-- ---------------------------------------------------------------------------
local function computeRecords(own, partner, shared)
  local runs = own.mplusRuns or {}
  local bestKey = 0
  for _, r in ipairs(runs) do
    if (r.level or 0) > bestKey then bestKey = r.level end
  end

  -- "Together since" — earliest grouped timestamp (min-merged across the pair).
  local sinceVal = "—"
  local ft = shared("firstTogether")
  if ft > 0 then
    local days = math.max(0, math.floor(((GetServerTime and GetServerTime() or 0) - ft) / 86400))
    local when = date and date("%b %d, %Y", ft) or tostring(ft)
    sinceVal = "|cffffffff" .. when .. "|r  |cff44ff44(" .. days .. L["d"] .. ")|r"
  end

  return {
    { icon = Theme.I_TIME, label = L["Together since"], value = sinceVal },
    { icon = Theme.I_KEY,  label = L["Best key"],
      value = bestKey > 0 and ("|cffa335ee+" .. bestKey .. "|r") or "—" },
  }
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local function build(host)
  local f = CreateFrame("Frame", nil, host); f:SetSize(10, 10)
  local ff = GameFontHighlight:GetFont()

  -- tiles
  f.tHeader = Widgets.SectionHeader(f)
  f.tiles = {}
  for _, def in ipairs(TILE_DEFS) do
    local t = CreateFrame("Frame", nil, f, "BackdropTemplate"); t:SetHeight(TILE_H)
    t:SetBackdrop(Theme.BACKDROP_HAIRLINE)
    t:SetBackdropColor(0.09, 0.095, 0.12, 0.85)
    t:SetBackdropBorderColor(Theme.GOLD[1] * 0.5, Theme.GOLD[2] * 0.5, Theme.GOLD[3] * 0.5, 0.6)
    t.chip = Row.MakeChip(t, 36, def.icon); t.chip:SetPoint("TOP", t, "TOP", 0, -12)
    t.num = t:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge"); t.num:SetPoint("TOP", t.chip, "BOTTOM", 0, -8)
    if ff then t.num:SetFont(ff, 26) end
    t.num:SetTextColor(Theme.CREAM[1], Theme.CREAM[2], Theme.CREAM[3])
    t.lbl = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); t.lbl:SetPoint("TOP", t.num, "BOTTOM", 0, -4)
    t.lbl:SetText(def.label); t.lbl:SetTextColor(0.75, 0.72, 0.6)
    -- subtle hover glow
    local hl = t:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(t); hl:SetColorTexture(1, 1, 1, 0.04); hl:Hide()
    t:HookScript("OnEnter", function() hl:Show() end); t:HookScript("OnLeave", function() hl:Hide() end)
    f.tiles[def.key] = t
  end

  -- left column: compare rows
  f.cHeader = Widgets.SectionHeader(f)
  f.cRows = {}
  for i, def in ipairs(COMPARE_DEFS) do
    local r = Row.CreateInfo(f, def.icon)
    f.cRows[i] = r
  end

  -- right column: records + recent M+ history
  f.rHeader = Widgets.SectionHeader(f)
  f.rRows = {}
  for i = 1, 8 do
    local r = Row.CreateInfo(f, Theme.I_KEY)
    f.rRows[i] = r
  end
  f.hHeader = Widgets.SectionHeader(f)
  f.hRows = {}; for i = 1, 8 do f.hRows[i] = Row.CreateInfo(f, Theme.I_KEY) end
  f.hEmpty = Widgets.SubText(f)
  return f
end

local function compareVal(you, partner)
  return "|cffffffff" .. L["You "] .. fmtNum(you) .. "|r    |cffa0a0a0" .. L["Partner "] .. fmtNum(partner) ..
    "|r    |cff44ff44" .. L["Total "] .. fmtNum((you or 0) + (partner or 0)) .. "|r"
end

-- Lay out a stack of pooled rows beneath an anchor; returns (lastAnchor, height).
local function stackRows(rows, n, headerDiamond, colW)
  local anchor = headerDiamond
  for i = 1, n do
    local r = rows[i]
    r:SetShown(true); r:SetWidth(colW)
    r.frame:ClearAllPoints()
    r.frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", i == 1 and -3 or 0, i == 1 and -8 or -3)
    anchor = r.frame
  end
  for i = n + 1, #rows do rows[i]:SetShown(false) end
  local h = (n > 0) and (8 + n * Row.HEIGHT + (n - 1) * 3) or 0
  return anchor, Theme.HEADER_H + h
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
local function refresh(f, ctx)
  local W = ctx.width; f:SetWidth(W)
  local leftW = math.min(560, math.floor((W - COL_GUTTER) / 2))
  local rightW = math.min(560, W - COL_GUTTER - leftW)
  local rightX = leftW + COL_GUTTER

  local own = (ns.db.demoMode and S.demoStats()) or (ns.chardb and ns.chardb.stats) or {}
  local partner = (ns.db.demoMode and ctx.snap.stats) or (ns.state.partner and ns.state.partner.stats) or {}
  local function shared(k) return math.max(own[k] or 0, partner[k] or 0) end

  -- tiles (full width)
  f.tHeader.label:ClearAllPoints(); f.tHeader.label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  Widgets.StyleHeader(f.tHeader, L["Adventured Together"], W)
  local gap = 14
  local tileW = math.floor((W - (#TILE_DEFS - 1) * gap) / #TILE_DEFS)
  local x = 0
  for _, def in ipairs(TILE_DEFS) do
    local t = f.tiles[def.key]
    t:ClearAllPoints(); t:SetPoint("TOPLEFT", f.tHeader.diamond, "BOTTOMLEFT", -3 + x, -10); t:SetWidth(tileW)
    local v = shared(def.key)
    t.num:SetText(def.time and S.fmtTime(v) or fmtNum(v))
    x = x + tileW + gap
  end
  local tileAnchor = f.tiles[TILE_DEFS[1].key]

  -- LEFT: You vs Partner
  f.cHeader.label:ClearAllPoints(); f.cHeader.label:SetPoint("TOPLEFT", tileAnchor, "BOTTOMLEFT", 3, -SECTION_GAP)
  Widgets.StyleHeader(f.cHeader, L["You vs Partner"], leftW)
  for i, def in ipairs(COMPARE_DEFS) do
    local r = f.cRows[i]
    r:SetIcon(def.icon)
    r:Set(def.label, compareVal(own[def.key], partner[def.key]))
  end
  local _, leftH = stackRows(f.cRows, #COMPARE_DEFS, f.cHeader.diamond, leftW)

  -- RIGHT (top): Records
  f.rHeader.label:ClearAllPoints(); f.rHeader.label:SetPoint("TOPLEFT", tileAnchor, "BOTTOMLEFT", 3 + rightX, -SECTION_GAP)
  Widgets.StyleHeader(f.rHeader, L["Records"], rightW)
  local recs = computeRecords(own, partner, shared)
  local nRec = math.min(#recs, #f.rRows)
  for i = 1, nRec do
    local d = recs[i]
    local r = f.rRows[i]
    r:SetIcon(d.icon or Theme.I_KEY); r:Set(d.label, d.value)
  end
  local _, recH = stackRows(f.rRows, nRec, f.rHeader.diamond, rightW)

  -- RIGHT (below records): Recent Mythic+
  f.hHeader.label:ClearAllPoints(); f.hHeader.label:SetPoint("TOPLEFT", f.rHeader.label, "TOPLEFT", 0, -(recH + SECTION_GAP))
  Widgets.StyleHeader(f.hHeader, L["Recent Mythic+"], rightW)
  local runs = own.mplusRuns or {}
  local n = math.min(#runs, 8)
  local hAnchor = f.hHeader.diamond
  for i = 1, n do
    local rr = runs[i]
    local r = f.hRows[i]
    r:SetShown(true); r:SetWidth(rightW); r:SetIcon(Theme.I_KEY)
    r:Set("|cffa335ee+" .. (rr.level or 0) .. "|r  " .. (rr.map and tostring(rr.map) or L["Dungeon"]),
      rr.onTime and ("|cff44ff44" .. L["timed"] .. "|r") or ("|cffff5555" .. L["over time"] .. "|r"))
    r.frame:ClearAllPoints()
    r.frame:SetPoint("TOPLEFT", hAnchor, "BOTTOMLEFT", i == 1 and -3 or 0, i == 1 and -8 or -3)
    hAnchor = r.frame
  end
  for i = n + 1, 8 do f.hRows[i]:SetShown(false) end
  local histH
  if n == 0 then
    f.hEmpty:Show(); f.hEmpty:ClearAllPoints(); f.hEmpty:SetPoint("TOPLEFT", f.hHeader.diamond, "BOTTOMLEFT", -3, -10)
    f.hEmpty:SetText(L["No Mythic+ runs together yet."])
    histH = Theme.HEADER_H + 10 + f.hEmpty:GetStringHeight()
  else
    f.hEmpty:Hide()
    histH = Theme.HEADER_H + 8 + n * Row.HEIGHT + (n - 1) * 3
  end
  local rightH = recH + SECTION_GAP + histH

  -- page height = tiles block + tallest column
  local h = Theme.HEADER_H + 10 + TILE_H + SECTION_GAP + math.max(leftH, rightH) + 14
  f:SetHeight(h)
  return h
end

ns.Dashboard.RegisterPage({ key = "statistics", label = L["Statistics"], order = 2, build = build, refresh = refresh })
