--[[ UI/Settings.lua
  Thin Blizzard interface-options entry. Every real option now lives in the addon's
  own window under the Settings bottom-tab (src/UI/SettingsTab.lua), so this panel is
  just a redirect: a single button that opens our window straight to that tab. Kept so
  the addon still appears in the game's AddOns options list and ESC > Options flow.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Settings = {}
ns.Settings = Settings

local L = ns.L

local categoryID   -- handle for Settings.OpenToCategory

local function buildPanel()
  local panel = CreateFrame("Frame", "BetterTogetherSettingsPanel")
  panel.name = "BetterTogether"

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("BetterTogether — " .. L["Partner Readiness Dashboard"])

  local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  sub:SetWidth(480); sub:SetJustifyH("LEFT")
  sub:SetText(L["All BetterTogether options live in the addon's own window."])

  local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  btn:SetSize(240, 26)
  btn:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -16)
  btn:SetText(L["Open BetterTogether settings"])
  btn:SetScript("OnClick", function()
    if ns.Dashboard and ns.Dashboard.OpenSettings then ns.Dashboard.OpenSettings() end
  end)

  local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 2, -10)
  hint:SetText(L["Type |cffffff00/bt|r for quick commands."])

  return panel
end

function Settings.Init()
  if categoryID ~= nil or Settings.panel then return end
  local panel = buildPanel()
  Settings.panel = panel

  -- Modern (Dragonflight+/Midnight) Settings API. The legacy InterfaceOptions API was
  -- removed in 10.0 and this addon targets 12.x, so there's no fallback path. Note this
  -- must be _G.Settings (the global) — the local `Settings` above is our own module.
  if _G.Settings and _G.Settings.RegisterCanvasLayoutCategory then
    local category = _G.Settings.RegisterCanvasLayoutCategory(panel, "BetterTogether")
    category.ID = "BetterTogether"
    _G.Settings.RegisterAddOnCategory(category)
    categoryID = category
  end
  ns:Debug("Settings registered")
end

-- Open our in-window Settings tab (the empty `/bt` command routes here).
function Settings.Open()
  if ns.Dashboard and ns.Dashboard.OpenSettings then
    ns.Dashboard.OpenSettings()
  else
    ns:Print("settings UI unavailable; use |cffffff00/bt|r commands")
  end
end

return Settings
