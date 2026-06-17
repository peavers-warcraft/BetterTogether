--[[ UI/Shell/Nav.lua
  The dashboard's navigation (ns.UI.Nav): the Plumber-style left page list and the
  native Blizzard bottom tab bar that swaps the whole view (Dashboard vs Settings).

  Nav.Build(panel, content, pages) builds both from the registered, order-sorted page
  list. Nav.HighlightPage(key) / Nav.HighlightMainTab(key) drive selection visuals;
  Nav.SetShown(shown) hides/shows the left list + its divider together (the settings
  and compact views borrow the full width).
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Nav = {}
ns.UI.Nav = Nav

local Theme = ns.UI.Theme
local Layout = ns.UI.Layout
local L = ns.L

local PAD, NAV_W, NAV_BTN_H = Layout.PAD, Layout.NAV_W, Layout.NAV_BTN_H

-- Top-level (bottom) tabs that swap the whole view: the existing dashboard vs the
-- consolidated settings page (Plumber-style bottom tab bar).
local MAIN_TABS = { { key = "dashboard", label = L["Dashboard"] }, { key = "settings", label = L["Settings"] } }

local nav, navDiv
local navButtons = {}
local mainTabButtons = {}

-- ---------------------------------------------------------------------------
-- Left nav buttons
-- ---------------------------------------------------------------------------
local function setNavActive(b, active)
  b.active = active
  b.accent:SetShown(active)
  b.glow:SetShown(active)
  if active then
    b.hl:Hide()
    b.fs:SetTextColor(Theme.CREAM[1], Theme.CREAM[2], Theme.CREAM[3])
  else
    if b.stub then b.fs:SetTextColor(0.5, 0.5, 0.5) else b.fs:SetTextColor(0.86, 0.82, 0.70) end
  end
end

local function makeNavButton(parent, desc)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(NAV_W - 10, NAV_BTN_H)
  b.key, b.stub = desc.key, desc.stub

  -- active glow (gold gradient fading right)
  local glow = b:CreateTexture(nil, "BACKGROUND"); glow:SetAllPoints(b); glow:SetColorTexture(1, 1, 1, 1)
  if CreateColor then
    glow:SetGradient("HORIZONTAL", CreateColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.28), CreateColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.0))
  else glow:SetColorTexture(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.16) end
  glow:Hide(); b.glow = glow
  -- hover highlight (subtle white)
  local hl = b:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(b); hl:SetColorTexture(1, 1, 1, 0.06); hl:Hide()
  b.hl = hl
  -- left accent bar
  local accent = b:CreateTexture(nil, "ARTWORK"); accent:SetSize(3, NAV_BTN_H - 10)
  accent:SetPoint("LEFT", b, "LEFT", 2, 0); accent:SetColorTexture(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3]); accent:Hide()
  b.accent = accent

  local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetPoint("LEFT", b, "LEFT", 14, 0); fs:SetText(desc.label)
  local ff = GameFontHighlight:GetFont(); if ff then fs:SetFont(ff, 15) end
  b.fs = fs

  b:SetScript("OnEnter", function() if not b.active then hl:Show() end end)
  b:SetScript("OnLeave", function() hl:Hide() end)
  b:SetScript("OnClick", function() ns.Dashboard.Select(desc.key) end)
  setNavActive(b, false)
  return b
end

--- Highlight the nav button whose page key matches (others go inactive).
function Nav.HighlightPage(key)
  for _, b in ipairs(navButtons) do setNavActive(b, b.key == key) end
end

--- Show/hide the left nav list + its divider together.
function Nav.SetShown(shown)
  nav:SetShown(shown); navDiv:SetShown(shown)
end

-- ---------------------------------------------------------------------------
-- Bottom tab bar (Dashboard / Settings) — native Blizzard frame tabs that hang
-- beneath the panel, the same PanelTabButtonTemplate used by the character sheet,
-- spellbook, etc. PanelTemplates_* drives selection so the active tab reads as
-- "connected" to the frame exactly like a stock UI panel.
-- ---------------------------------------------------------------------------
local function setMainTabActive(b, active)
  b.active = active
  if active then PanelTemplates_SelectTab(b) else PanelTemplates_DeselectTab(b) end
end

local tabCount = 0
local function makeMainTabButton(parent, def)
  tabCount = tabCount + 1
  local b = CreateFrame("Button", "BetterTogetherMainTab" .. tabCount, parent, "PanelTabButtonTemplate")
  b.key = def.key
  b:SetText(def.label)
  b:SetScript("OnClick", function() ns.Dashboard.ShowMainTab(def.key) end)
  PanelTemplates_TabResize(b, 0)
  return b
end

--- Highlight the active bottom tab (dashboard / settings).
function Nav.HighlightMainTab(key)
  for _, b in ipairs(mainTabButtons) do setMainTabActive(b, b.key == key) end
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
--- @param panel table The root panel frame.
--- @param content table The panel's content inset.
--- @param pages table Order-sorted page descriptors.
function Nav.Build(panel, content, pages)
  -- left nav + divider
  nav = CreateFrame("Frame", nil, content)
  nav:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -PAD)
  nav:SetSize(NAV_W, 10)
  navDiv = content:CreateTexture(nil, "ARTWORK")
  navDiv:SetColorTexture(1, 1, 1, 0.08); navDiv:SetWidth(1)
  navDiv:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + NAV_W + 8, -PAD)
  navDiv:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", PAD + NAV_W + 8, PAD)

  local prev
  for _, desc in ipairs(pages) do
    -- A page can open a new category: extra space + a thin gold divider above it.
    local gap = 2
    if desc.separator and prev then
      gap = 14
      local div = nav:CreateTexture(nil, "ARTWORK")
      div:SetHeight(1); div:SetColorTexture(1, 1, 1, 1)
      if CreateColor then
        div:SetGradient("HORIZONTAL", CreateColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.0),
          CreateColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.45))
      else div:SetVertexColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.3) end
      div:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 6, -(gap / 2))
      div:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", -6, -(gap / 2))
    end

    local b = makeNavButton(nav, desc)
    if prev then b:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -gap)
    else b:SetPoint("TOPLEFT", nav, "TOPLEFT", 0, 0) end
    prev = b
    table.insert(navButtons, b)
  end

  -- Bottom tab bar: native Blizzard frame tabs hung beneath the panel, the same
  -- look the character sheet / spellbook use. The tabs' top edge tucks up under the
  -- panel's bottom border so the active tab reads as part of the frame; subsequent
  -- tabs overlap by the template's built-in side art (the standard -15 inset).
  local mainTabBar = CreateFrame("Frame", nil, panel)
  mainTabBar:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 16, 1)
  mainTabBar:SetHeight(32)
  -- The modern uiframe-tab atlas tabs have visible rounded end-caps (not the old
  -- template's transparent side padding), so they sit flush — no negative inset, or
  -- they'd overlap each other. A couple px of gap keeps the caps from touching.
  local TAB_GAP = 2
  local prevTab, totalW = nil, 0
  for _, def in ipairs(MAIN_TABS) do
    local b = makeMainTabButton(mainTabBar, def)
    if prevTab then
      b:SetPoint("LEFT", prevTab, "RIGHT", TAB_GAP, 0)
      totalW = totalW + (b:GetWidth() or 0) + TAB_GAP
    else
      b:SetPoint("TOPLEFT", mainTabBar, "TOPLEFT", 0, 0)
      totalW = totalW + (b:GetWidth() or 0)
    end
    prevTab = b
    table.insert(mainTabButtons, b)
  end
  -- Give the bar a real width. Without it the container's rect is indeterminate, so
  -- GetLeft() returns nil and the child tabs — anchored to it — never resolve a
  -- screen position and silently don't draw (even though their textures are shown).
  mainTabBar:SetWidth(math.max(1, totalW))
end

return Nav
