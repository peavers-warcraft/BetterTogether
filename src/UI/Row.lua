--[[ UI/Row.lua
  A single readiness row: [icon chip] Label .......... value  [status mark]
  Icons are unified into a circular "chip" (dark fill + thin gold rim + circular-
  masked icon) so the mixed in-game art reads as one cohesive, premium set.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Row = {}
ns.UI.Row = Row

local GOLD = { 0.83, 0.67, 0.33 }
local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

local function atlasExists(name)
  return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end
local HAS_ATLAS = atlasExists("common-icon-checkmark")
local FALLBACK = {
  ok = "Interface\\RaidFrame\\ReadyCheck-Ready", no = "Interface\\RaidFrame\\ReadyCheck-NotReady",
  wait = "Interface\\RaidFrame\\ReadyCheck-Waiting",
}
-- Apply chip art, handling atlas names (crisp at any size) vs file textures
-- (cropped slightly to hide the baked-in border). Mirrors S.applyIcon; kept local
-- since Row loads before Shared.
local function applyIcon(tex, art)
  if type(art) == "string" and not art:find("\\") and atlasExists(art) then
    tex:SetTexCoord(0, 1, 0, 1); tex:SetAtlas(art)
  else
    tex:SetTexture(art); tex:SetTexCoord(0.1, 0.9, 0.1, 0.9)
  end
end
local function setMark(tex, state)
  if HAS_ATLAS then
    if state == true then tex:SetAtlas("common-icon-checkmark")
    elseif state == false then tex:SetAtlas("common-icon-redx")
    else tex:SetAtlas("services-icon-warning") end
  else
    if state == true then tex:SetTexture(FALLBACK.ok)
    elseif state == false then tex:SetTexture(FALLBACK.no)
    else tex:SetTexture(FALLBACK.wait) end
  end
end

local ROW_HEIGHT, CHIP, MARK_SIZE = 32, 26, 18
-- Two-column ("You … / Partner …") value layout: the Partner column is a fixed-width
-- box pinned to the right edge, so the You column's right edge — and the gap between
-- the two — stay constant from row to row. Without this the whole value is one
-- right-aligned string and "You done" drifts left/right with the partner text.
local PARTNER_COL, VALUE_GAP = 150, 14

-- Circular icon chip: gold rim + dark fill + masked icon.
local function makeChip(parent, size, iconPath)
  local c = CreateFrame("Frame", nil, parent)
  c:SetSize(size, size)

  local rim = c:CreateTexture(nil, "BACKGROUND")
  rim:SetAllPoints(c); rim:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.55)
  local rimMask = c:CreateMaskTexture()
  rimMask:SetAllPoints(rim); rimMask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  rim:AddMaskTexture(rimMask)

  local fill = c:CreateTexture(nil, "BORDER")
  fill:SetPoint("CENTER"); fill:SetSize(size - 3, size - 3); fill:SetColorTexture(0.09, 0.09, 0.12, 1)
  local fillMask = c:CreateMaskTexture()
  fillMask:SetAllPoints(fill); fillMask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  fill:AddMaskTexture(fillMask)

  local icon = c:CreateTexture(nil, "ARTWORK")
  icon:SetPoint("CENTER"); icon:SetSize(size - 9, size - 9)
  applyIcon(icon, iconPath)
  local iconMask = c:CreateMaskTexture()
  iconMask:SetAllPoints(icon); iconMask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  icon:AddMaskTexture(iconMask)

  c.icon = icon
  return c
end
-- Exposed so other UI (e.g. the Statistics tiles) can reuse the exact chip look.
Row.MakeChip = makeChip

function Row.Create(parent, iconPath)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(ROW_HEIGHT)

  local hl = f:CreateTexture(nil, "BACKGROUND")
  hl:SetAllPoints(f); hl:SetColorTexture(1, 1, 1, 0.05); hl:Hide()
  f:SetScript("OnEnter", function() hl:Show() end)
  f:SetScript("OnLeave", function() hl:Hide() end)
  f:EnableMouse(true)

  local chip = makeChip(f, CHIP, iconPath)
  chip:SetPoint("LEFT", f, "LEFT", 2, 0)
  f.chip = chip

  local fontFile = GameFontHighlight:GetFont()

  local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  label:SetPoint("LEFT", chip, "RIGHT", 12, 0); label:SetJustifyH("LEFT")
  if fontFile then label:SetFont(fontFile, 15) end
  f.label = label

  local status = f:CreateTexture(nil, "OVERLAY")
  status:SetSize(MARK_SIZE, MARK_SIZE); status:SetPoint("RIGHT", f, "RIGHT", -2, 0)
  f.status = status

  local value = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  value:SetPoint("RIGHT", status, "LEFT", -10, 0); value:SetJustifyH("RIGHT")
  if fontFile then value:SetFont(fontFile, 15) end
  f.value = value

  label:SetPoint("RIGHT", value, "LEFT", -8, 0)
  label:SetWordWrap(false)

  local obj = { frame = f }
  function obj:Set(labelText, valueText, ok, valueColor)
    f.label:SetText(labelText or "")
    f.value:SetText(valueText or "")
    if valueColor then f.value:SetTextColor(valueColor[1], valueColor[2], valueColor[3])
    else f.value:SetTextColor(0.85, 0.85, 0.85) end
    setMark(f.status, ok)
  end
  function obj:SetWidth(w) f:SetWidth(w) end
  function obj:Show() f:Show() end
  function obj:Hide() f:Hide() end
  function obj:SetShown(v) f:SetShown(v) end
  function obj:GetHeight() return ROW_HEIGHT end
  return obj
end

-- Info row: chip + label + value, no status mark, with a settable icon. Used for
-- non-readiness sections (e.g. "Now") so they share the readiness look.
function Row.CreateInfo(parent, iconPath)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(ROW_HEIGHT)

  -- persistent selection tint (under the hover highlight)
  local sel = f:CreateTexture(nil, "BACKGROUND")
  sel:SetAllPoints(f); sel:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.14); sel:Hide()
  local hl = f:CreateTexture(nil, "BACKGROUND")
  hl:SetAllPoints(f); hl:SetColorTexture(1, 1, 1, 0.05); hl:Hide()
  f:SetScript("OnEnter", function() hl:Show(); if f._enter then f._enter(f) end end)
  f:SetScript("OnLeave", function() hl:Hide(); if f._leave then f._leave(f) end end)
  f:SetScript("OnMouseUp", function() if f._click then f._click() end end)
  f:EnableMouse(true)

  local chip = makeChip(f, CHIP, iconPath or "Interface\\Icons\\INV_Misc_QuestionMark")
  chip:SetPoint("LEFT", f, "LEFT", 2, 0)
  f.chip = chip

  local fontFile = GameFontHighlight:GetFont()
  local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  label:SetPoint("LEFT", chip, "RIGHT", 12, 0); label:SetJustifyH("LEFT")
  if fontFile then label:SetFont(fontFile, 15) end
  f.label = label
  local value = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  value:SetPoint("RIGHT", f, "RIGHT", -4, 0); value:SetJustifyH("RIGHT"); value:SetWordWrap(false)
  if fontFile then value:SetFont(fontFile, 15) end
  f.value = value
  -- Second value column (the "You …" side); only shown in two-column mode.
  local value2 = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  value2:SetJustifyH("RIGHT"); value2:SetWordWrap(false); value2:Hide()
  if fontFile then value2:SetFont(fontFile, 15) end
  f.value2 = value2
  label:SetPoint("RIGHT", value, "LEFT", -8, 0); label:SetWordWrap(false)

  -- Reattach the label between the chip and a given right-hand anchor (the active
  -- value column), so single- and two-column modes both keep the label clamped.
  local function anchorLabel(rightAnchor)
    f.label:ClearAllPoints()
    f.label:SetPoint("LEFT", f.chip, "RIGHT", 12, 0)
    f.label:SetPoint("RIGHT", rightAnchor, "LEFT", -8, 0)
  end

  local obj = { frame = f }
  function obj:SetIcon(p) applyIcon(f.chip.icon, p) end
  function obj:SetHover(enterFn, leaveFn) f._enter = enterFn; f._leave = leaveFn end
  function obj:SetClick(fn) f._click = fn end
  function obj:SetSelected(v) sel:SetShown(v and true or false) end
  function obj:Set(labelText, valueText, valueColor)
    -- Single-column mode: value auto-sized (one RIGHT anchor) and right-aligned.
    f.value2:Hide()
    f.value:ClearAllPoints()
    f.value:SetPoint("RIGHT", f, "RIGHT", -4, 0); f.value:SetJustifyH("RIGHT")
    anchorLabel(f.value)
    f.label:SetText(labelText or ""); f.value:SetText(valueText or "")
    if valueColor then f.value:SetTextColor(valueColor[1], valueColor[2], valueColor[3])
    else f.value:SetTextColor(0.9, 0.9, 0.9) end
  end
  -- Two-column comparison: `partner` fills a fixed-width box pinned to the frame's
  -- right edge (width set via LEFT+RIGHT anchors, so we never juggle SetWidth); `you`
  -- right-aligns just left of that box, giving it a stable right edge across rows.
  -- Colours are carried inline in the strings (|cff…|r).
  function obj:SetSplit(labelText, youText, partnerText)
    f.value:ClearAllPoints()
    f.value:SetPoint("RIGHT", f, "RIGHT", -4, 0)
    f.value:SetPoint("LEFT", f, "RIGHT", -(4 + PARTNER_COL), 0)
    f.value:SetJustifyH("LEFT")
    f.value:SetTextColor(0.9, 0.9, 0.9); f.value:SetText(partnerText or "")
    f.value2:ClearAllPoints()
    f.value2:SetPoint("RIGHT", f.value, "LEFT", -VALUE_GAP, 0)
    f.value2:SetTextColor(0.9, 0.9, 0.9); f.value2:SetText(youText or ""); f.value2:Show()
    anchorLabel(f.value2)
    f.label:SetText(labelText or "")
  end
  function obj:SetWidth(w) f:SetWidth(w) end
  function obj:Show() f:Show() end
  function obj:Hide() f:Hide() end
  function obj:SetShown(v) f:SetShown(v) end
  function obj:GetHeight() return ROW_HEIGHT end
  return obj
end

Row.HEIGHT = ROW_HEIGHT

return Row
