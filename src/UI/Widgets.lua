--[[ UI/Widgets.lua
  Reusable UI elements — the small frames pages build out of. Each factory returns a
  ready-styled frame (or a header table); all of them theme from ns.UI.Theme so the
  whole addon reskins from one place. Loaded after Theme and before Row/pages.

  Provided:
    Widgets.Chip(parent, size, iconPath)     circular gold-rim chip (+ .icon, .rim)
    Widgets.Button(parent, text, w, h)       themed dark-gold button (+ .fs)
    Widgets.Input(parent, w, h)              themed edit box
    Widgets.SubText(parent)                  muted sub-text fontstring
    Widgets.SectionHeader(parent)            cream label + gold diamond + fading rule
    Widgets.StyleHeader/HideHeader/SubHeight  drive a section header at layout time

  History: the chip was implemented three times (Row, Dashboard detail, Achievements
  cards) and the button/input only existed inline in Partners. They live here now.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Widgets = {}
ns.UI.Widgets = Widgets

local Theme = ns.UI.Theme
local GOLD, CREAM = Theme.GOLD, Theme.CREAM
local MASK = Theme.CIRCLE_MASK

local CreateFrame = CreateFrame

-- The shared body font, captured once.
local function bodyFont() return GameFontHighlight:GetFont() end

-- ---------------------------------------------------------------------------
-- Circular icon chip: gold rim + dark fill + circular-masked icon. The single
-- implementation behind every chip in the addon. `.rim` is exposed so callers can
-- recolor it (e.g. by item quality); `.icon` so they can repaint the art.
-- ---------------------------------------------------------------------------
--- @param parent table Frame to parent the chip to.
--- @param size number Chip diameter in pixels.
--- @param iconPath string|number|nil Initial icon art (atlas/path/fileID), or nil to set later.
--- @return table chip Frame with `.icon` and `.rim` textures.
function Widgets.Chip(parent, size, iconPath)
  local c = CreateFrame("Frame", nil, parent)
  c:SetSize(size, size)

  local rim = c:CreateTexture(nil, "BACKGROUND")
  rim:SetAllPoints(c); rim:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], Theme.RIM_ALPHA)
  local rimMask = c:CreateMaskTexture()
  rimMask:SetAllPoints(rim); rimMask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  rim:AddMaskTexture(rimMask)

  local fill = c:CreateTexture(nil, "BORDER")
  fill:SetPoint("CENTER"); fill:SetSize(size - 3, size - 3)
  fill:SetColorTexture(Theme.CHIP_FILL[1], Theme.CHIP_FILL[2], Theme.CHIP_FILL[3], 1)
  local fillMask = c:CreateMaskTexture()
  fillMask:SetAllPoints(fill); fillMask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  fill:AddMaskTexture(fillMask)

  local icon = c:CreateTexture(nil, "ARTWORK")
  icon:SetPoint("CENTER"); icon:SetSize(size - 9, size - 9); icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
  if iconPath ~= nil then Theme.ApplyIcon(icon, iconPath) end
  local iconMask = c:CreateMaskTexture()
  iconMask:SetAllPoints(icon); iconMask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  icon:AddMaskTexture(iconMask)

  c.rim, c.icon = rim, icon
  return c
end

-- ---------------------------------------------------------------------------
-- Themed dark-gold button (replaces the stock UIPanelButton in our dark panel).
-- Brightens on hover and nudges its label on press. Label fontstring is `.fs`.
-- ---------------------------------------------------------------------------
--- @param parent table
--- @param text string Button label.
--- @param w number
--- @param h number
--- @return table button
function Widgets.Button(parent, text, w, h)
  local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
  b:SetSize(w, h)
  b:SetBackdrop(Theme.BACKDROP_TOOLTIP)
  b:SetBackdropColor(Theme.BG_BUTTON[1], Theme.BG_BUTTON[2], Theme.BG_BUTTON[3], 0.9)
  b:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.75)

  local fs = b:CreateFontString(nil, "OVERLAY")
  fs:SetPoint("CENTER", 0, 0)
  local ff = bodyFont(); if ff then fs:SetFont(ff, Theme.FONT_SMALL, "") end
  fs:SetTextColor(CREAM[1], CREAM[2], CREAM[3]); fs:SetText(text)
  b.fs = fs

  b:SetScript("OnEnter", function(self)
    if self._disabled then
      if self._disabledTip then
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(self._disabledTip, GOLD[1], GOLD[2], GOLD[3], true)
        GameTooltip:Show()
      end
      return
    end
    self:SetBackdropColor(Theme.BG_BUTTON_HOVER[1], Theme.BG_BUTTON_HOVER[2], Theme.BG_BUTTON_HOVER[3], 0.95)
    self:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 1)
  end)
  b:SetScript("OnLeave", function(self)
    GameTooltip:Hide()
    if self._disabled then return end
    self:SetBackdropColor(Theme.BG_BUTTON[1], Theme.BG_BUTTON[2], Theme.BG_BUTTON[3], 0.9)
    self:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.75)
  end)
  b:SetScript("OnMouseDown", function(self) if not self._disabled then self.fs:SetPoint("CENTER", 1, -1) end end)
  b:SetScript("OnMouseUp", function(self) if not self._disabled then self.fs:SetPoint("CENTER", 0, 0) end end)

  -- Disabled state: greys the button and surfaces `disabledTip` on hover instead
  -- of the press affordance. Callers still guard their OnClick on `_disabled`
  -- (a custom Button has no native click-suppression). Used by the Partners page
  -- to block switching to an offline partner.
  b._disabled = false
  function b:SetEnabledState(enabled, disabledTip)
    self._disabled = not enabled
    self._disabledTip = disabledTip
    if enabled then
      self:SetBackdropColor(Theme.BG_BUTTON[1], Theme.BG_BUTTON[2], Theme.BG_BUTTON[3], 0.9)
      self:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.75)
      self.fs:SetTextColor(CREAM[1], CREAM[2], CREAM[3])
    else
      self:SetBackdropColor(Theme.BG_BUTTON[1], Theme.BG_BUTTON[2], Theme.BG_BUTTON[3], 0.4)
      self:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)
      self.fs:SetTextColor(Theme.SUBHEADER_COLOR[1], Theme.SUBHEADER_COLOR[2], Theme.SUBHEADER_COLOR[3])
    end
  end
  return b
end

-- ---------------------------------------------------------------------------
-- Themed edit box (replaces the stock InputBoxTemplate). Brightens its border
-- while focused. Autocomplete wiring stays at the call site (Partners).
-- ---------------------------------------------------------------------------
--- @param parent table
--- @param w number
--- @param h number
--- @return table editBox
function Widgets.Input(parent, w, h)
  local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
  e:SetSize(w, h)
  e:SetBackdrop(Theme.BACKDROP_TOOLTIP)
  e:SetBackdropColor(Theme.BG_INPUT[1], Theme.BG_INPUT[2], Theme.BG_INPUT[3], 0.9)
  e:SetBackdropBorderColor(GOLD[1] * 0.7, GOLD[2] * 0.7, GOLD[3] * 0.7, 0.7)
  local ff = bodyFont(); if ff then e:SetFont(ff, Theme.FONT_SMALL, "") end
  e:SetTextColor(CREAM[1], CREAM[2], CREAM[3])
  e:SetTextInsets(8, 8, 0, 0)
  e:SetAutoFocus(false)
  e:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 1) end)
  e:HookScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(GOLD[1] * 0.7, GOLD[2] * 0.7, GOLD[3] * 0.7, 0.7) end)
  return e
end

-- ---------------------------------------------------------------------------
-- Muted sub-text (empty-state lines, inline notes) that isn't owned by a header.
-- Same font as a header's built-in sub so the two never clash.
-- ---------------------------------------------------------------------------
--- @param parent table
--- @return table fontString
function Widgets.SubText(parent)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  local ff = bodyFont()
  if ff then fs:SetFont(ff, Theme.SUBHEADER_SIZE, "") end
  fs:SetTextColor(Theme.SUBHEADER_COLOR[1], Theme.SUBHEADER_COLOR[2], Theme.SUBHEADER_COLOR[3])
  fs:SetJustifyH("LEFT"); fs:SetJustifyV("TOP")
  return fs
end

-- ---------------------------------------------------------------------------
-- Section header: cream label + gold diamond + right-fading gold rule, with an
-- optional descriptive sub-line. Build once; drive each refresh with StyleHeader.
-- ---------------------------------------------------------------------------
--- @param parent table
--- @return table header { label, diamond, line, sub } — drive with StyleHeader.
function Widgets.SectionHeader(parent)
  local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  local ff = bodyFont()
  if ff then label:SetFont(ff, Theme.FONT_HEADER) end
  label:SetTextColor(CREAM[1], CREAM[2], CREAM[3])
  local diamond = parent:CreateTexture(nil, "ARTWORK")
  diamond:SetSize(7, 7); diamond:SetTexture(Theme.WHITE8X8)
  diamond:SetVertexColor(GOLD[1], GOLD[2], GOLD[3]); diamond:SetRotation(math.rad(45))
  local line = parent:CreateTexture(nil, "ARTWORK")
  line:SetHeight(2); line:SetColorTexture(1, 1, 1, 1)
  if CreateColor then
    line:SetGradient("HORIZONTAL", CreateColor(GOLD[1], GOLD[2], GOLD[3], 0.8), CreateColor(GOLD[1], GOLD[2], GOLD[3], 0.0))
  else
    line:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.5)
  end
  local sub = Widgets.SubText(parent); sub:Hide()   -- optional descriptive line under the rule
  return { label = label, diamond = diamond, line = line, sub = sub }
end

--- Hide every piece of a section header.
--- @param h table A header from SectionHeader.
function Widgets.HideHeader(h)
  h.label:Hide(); h.diamond:Hide(); h.line:Hide()
  if h.sub then h.sub:Hide() end
end

--- Style a header (caller has already positioned h.label's TOPLEFT). Anchors the
--- diamond + line beneath the label and sizes the line to colW. Pass `subtext` to
--- render a descriptive sub-line beneath the rule (aligned to the label, x=0);
--- omit/"" to hide it. Use SubHeight(h) to learn how far the sub extends below the
--- rule when laying out the content that follows.
--- @param h table A header from SectionHeader.
--- @param title string Header text.
--- @param colW number Width the rule spans.
--- @param subtext string|nil Optional descriptive line.
function Widgets.StyleHeader(h, title, colW, subtext)
  h.label:SetText(title); h.label:Show()
  h.diamond:Show(); h.diamond:ClearAllPoints(); h.diamond:SetPoint("TOPLEFT", h.label, "BOTTOMLEFT", 3, -6)
  h.line:Show(); h.line:ClearAllPoints(); h.line:SetPoint("LEFT", h.diamond, "RIGHT", 6, 0); h.line:SetWidth(colW - 16)
  if h.sub then
    if subtext and subtext ~= "" then
      h.sub:Show(); h.sub:SetWidth(colW)
      h.sub:ClearAllPoints()
      h.sub:SetPoint("TOPLEFT", h.diamond, "BOTTOMLEFT", -3, -Theme.SUBHEADER_GAP)
      h.sub:SetText(subtext)
    else
      h.sub:Hide()
    end
  end
end

--- Vertical space the header's sub-text occupies below the rule (0 when hidden).
--- Add this to Theme.HEADER_H to find where the next content row should start.
--- @param h table A header from SectionHeader.
--- @return number height
function Widgets.SubHeight(h)
  if h.sub and h.sub:IsShown() then return Theme.SUBHEADER_GAP + h.sub:GetStringHeight() end
  return 0
end

return Widgets
