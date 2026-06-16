--[[ UI/Row.lua
  A single readiness row: [icon chip] Label .......... value  [status mark]
  Icons are unified into a circular "chip" (Widgets.Chip) so the mixed in-game art
  reads as one cohesive, premium set. Theming/constants come from ns.UI.Theme.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Row = {}
ns.UI.Row = Row

local Theme = ns.UI.Theme
local Widgets = ns.UI.Widgets
local GOLD = Theme.GOLD

local CreateFrame = CreateFrame

local HAS_ATLAS = Theme.AtlasExists("common-icon-checkmark")
local FALLBACK = {
  ok = "Interface\\RaidFrame\\ReadyCheck-Ready", no = "Interface\\RaidFrame\\ReadyCheck-NotReady",
  wait = "Interface\\RaidFrame\\ReadyCheck-Waiting",
}
-- Paint the right-hand status mark: check / red-x / warning (atlas where available,
-- ready-check textures as a fallback). state: true=ok, false=fail, nil=waiting.
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

-- Exposed so other UI (Statistics tiles, Achievement cards) can reuse the exact chip.
Row.MakeChip = Widgets.Chip

--- A readiness row: chip + label + right-aligned value + status mark.
--- @param parent table
--- @param iconPath string|number Chip art.
--- @return table row Object with :Set/:SetWidth/:Show/:Hide/:SetShown/:GetHeight + .frame.
function Row.Create(parent, iconPath)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(ROW_HEIGHT)

  local hl = f:CreateTexture(nil, "BACKGROUND")
  hl:SetAllPoints(f); hl:SetColorTexture(1, 1, 1, Theme.HL_ALPHA); hl:Hide()
  f:SetScript("OnEnter", function() hl:Show() end)
  f:SetScript("OnLeave", function() hl:Hide() end)
  f:EnableMouse(true)

  local chip = Widgets.Chip(f, CHIP, iconPath)
  chip:SetPoint("LEFT", f, "LEFT", 2, 0)
  f.chip = chip

  local fontFile = GameFontHighlight:GetFont()

  local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  label:SetPoint("LEFT", chip, "RIGHT", 12, 0); label:SetJustifyH("LEFT")
  if fontFile then label:SetFont(fontFile, Theme.FONT_ROW) end
  f.label = label

  local status = f:CreateTexture(nil, "OVERLAY")
  status:SetSize(MARK_SIZE, MARK_SIZE); status:SetPoint("RIGHT", f, "RIGHT", -2, 0)
  f.status = status

  local value = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  value:SetPoint("RIGHT", status, "LEFT", -10, 0); value:SetJustifyH("RIGHT")
  if fontFile then value:SetFont(fontFile, Theme.FONT_ROW) end
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

--- Info row: chip + label + value, no status mark, with a settable icon. Used for
--- non-readiness sections (e.g. "Now") so they share the readiness look. Supports a
--- two-column "You … / Partner …" comparison mode via :SetSplit.
--- @param parent table
--- @param iconPath string|number|nil Chip art (defaults to a question mark).
--- @return table row Object with :Set/:SetSplit/:SetIcon/:SetHover/:SetClick/:SetSelected + .frame.
function Row.CreateInfo(parent, iconPath)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(ROW_HEIGHT)

  -- persistent selection tint (under the hover highlight)
  local sel = f:CreateTexture(nil, "BACKGROUND")
  sel:SetAllPoints(f); sel:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], Theme.SEL_ALPHA); sel:Hide()
  local hl = f:CreateTexture(nil, "BACKGROUND")
  hl:SetAllPoints(f); hl:SetColorTexture(1, 1, 1, Theme.HL_ALPHA); hl:Hide()
  f:SetScript("OnEnter", function() hl:Show(); if f._enter then f._enter(f) end end)
  f:SetScript("OnLeave", function() hl:Hide(); if f._leave then f._leave(f) end end)
  f:SetScript("OnMouseUp", function() if f._click then f._click() end end)
  f:EnableMouse(true)

  local chip = Widgets.Chip(f, CHIP, iconPath or "Interface\\Icons\\INV_Misc_QuestionMark")
  chip:SetPoint("LEFT", f, "LEFT", 2, 0)
  f.chip = chip

  local fontFile = GameFontHighlight:GetFont()
  local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  label:SetPoint("LEFT", chip, "RIGHT", 12, 0); label:SetJustifyH("LEFT")
  if fontFile then label:SetFont(fontFile, Theme.FONT_ROW) end
  f.label = label
  local value = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  value:SetPoint("RIGHT", f, "RIGHT", -4, 0); value:SetJustifyH("RIGHT"); value:SetWordWrap(false)
  if fontFile then value:SetFont(fontFile, Theme.FONT_ROW) end
  f.value = value
  -- Second value column (the "You …" side); only shown in two-column mode.
  local value2 = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  value2:SetJustifyH("RIGHT"); value2:SetWordWrap(false); value2:Hide()
  if fontFile then value2:SetFont(fontFile, Theme.FONT_ROW) end
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
  function obj:SetIcon(p) Theme.ApplyIcon(f.chip.icon, p) end
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
