--[[ UI/Settings.lua
  Options panel (spec §8.2/§8.4, §10 Milestone 3): thresholds, blocking vs
  advisory checks, visible rows, pin-quest selector, scale/lock/demo toggles.
  Registered into the Blizzard Settings UI (modern API with a legacy fallback).
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Settings = {}
ns.Settings = Settings

local Theme = ns.UI.Theme
local L = ns.L

local categoryID   -- handle for Settings.OpenToCategory

-- ---------------------------------------------------------------------------
-- Small widget helpers
-- ---------------------------------------------------------------------------
local function makeCheck(parent, label, tooltip, getter, setter)
  local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
  cb.Text:SetText(label)
  if tooltip then cb.tooltipText = tooltip end
  cb:SetScript("OnShow", function(self) self:SetChecked(getter()) end)
  cb:SetScript("OnClick", function(self)
    setter(self:GetChecked() and true or false)
    if ns.Dashboard then ns.Dashboard.Refresh() end
  end)
  cb:SetChecked(getter())
  return cb
end

local function makeSlider(parent, label, minV, maxV, step, getter, setter, fmt)
  local s = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
  s:SetMinMaxValues(minV, maxV)
  s:SetValueStep(step)
  s:SetObeyStepOnDrag(true)
  s:SetWidth(220)
  -- OptionsSliderTemplate names its fontstrings via $parent; address by suffix.
  local name = s:GetName()
  local lowFS  = name and _G[name .. "Low"]
  local highFS = name and _G[name .. "High"]
  local txtFS  = name and _G[name .. "Text"]
  if lowFS then lowFS:SetText(tostring(minV)) end
  if highFS then highFS:SetText(tostring(maxV)) end

  local function updateText(v)
    if s.Text then s.Text:SetText(fmt and fmt(v) or (label .. ": " .. v)) end
    if txtFS then txtFS:SetText(fmt and fmt(v) or (label .. ": " .. v)) end
  end

  s:SetScript("OnShow", function(self)
    local v = getter()
    self:SetValue(v)
    updateText(v)
  end)
  s:SetScript("OnValueChanged", function(self, value)
    value = math.floor(value / step + 0.5) * step
    setter(value)
    updateText(value)
    if ns.Dashboard then ns.Dashboard.Refresh() end
  end)
  s:SetValue(getter())
  updateText(getter())
  return s
end

-- A blocking/advisory toggle implemented as a checkbox ("blocking?").
local function makeSeverityCheck(parent, label, key)
  return makeCheck(parent, label .. L[" is blocking"],
    L["When checked, failing this check turns the verdict RED. When unchecked, it is advisory (amber)."],
    function() return ns.db.checks[key] == "blocking" end,
    function(v) ns.db.checks[key] = v and "blocking" or "advisory" end)
end

-- ---------------------------------------------------------------------------
-- Build the canvas
-- ---------------------------------------------------------------------------
local function buildPanel()
  local panel = CreateFrame("Frame", "BetterTogetherSettingsPanel")
  panel.name = "BetterTogether"

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("BetterTogether — " .. L["Partner Readiness Dashboard"])

  local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
  sub:SetText(L["Type |cffffff00/bt|r for quick commands."])

  -- Two columns: left = general/thresholds, right = checks/visibility.
  local leftX, rightX = 16, 320
  local y = -70

  local function header(text, x, yy)
    local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", x, yy)
    fs:SetText(Theme.C.accent .. text .. "|r")
    return fs
  end

  -- LEFT COLUMN -------------------------------------------------------------
  header(L["General"], leftX, y)
  local cy = y - 24

  local lockCB = makeCheck(panel, L["Lock panel position"],
    L["Prevents dragging the dashboard."],
    function() return ns.db.locked end,
    function(v) ns.db.locked = v; if ns.Dashboard then ns.Dashboard.ApplyLock() end end)
  lockCB:SetPoint("TOPLEFT", leftX, cy); cy = cy - 30

  local demoCB = makeCheck(panel, L["Demo mode (fake partner)"],
    L["Renders the panel with sample data for screenshots/video."],
    function() return ns.db.demoMode end,
    function(v) ns.db.demoMode = v end)
  demoCB:SetPoint("TOPLEFT", leftX, cy); cy = cy - 40

  local scaleS = makeSlider(panel, L["Scale"], 0.5, 2.0, 0.05,
    function() return ns.db.scale or 1.0 end,
    function(v) ns.Dashboard.SetScale(v) end,
    function(v) return string.format(L["Panel scale: %.2f"], v) end)
  scaleS:SetPoint("TOPLEFT", leftX + 4, cy); cy = cy - 50

  header(L["Thresholds"], leftX, cy); cy = cy - 24
  local durS = makeSlider(panel, L["Durability"], 0, 100, 5,
    function() return ns.db.thresholds.durability end,
    function(v) ns.db.thresholds.durability = v end,
    function(v) return L["Min durability: "] .. v .. "%" end)
  durS:SetPoint("TOPLEFT", leftX + 4, cy); cy = cy - 50

  header(L["Broadcast quest"], leftX, cy); cy = cy - 24
  local qDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  qDesc:SetPoint("TOPLEFT", leftX, cy)
  qDesc:SetWidth(280); qDesc:SetJustifyH("LEFT")
  qDesc:SetText(L["Pin a quest ID to broadcast, or leave empty to use your super-tracked quest."])
  cy = cy - 36

  local qBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
  qBox:SetSize(120, 22)
  qBox:SetAutoFocus(false)
  qBox:SetNumeric(true)
  qBox:SetPoint("TOPLEFT", leftX + 4, cy)
  qBox:SetScript("OnShow", function(self)
    self:SetText(ns.db.pinnedQuestID and tostring(ns.db.pinnedQuestID) or "")
  end)
  local function commitQuest(self)
    local v = tonumber(self:GetText())
    ns.db.pinnedQuestID = (v and v > 0) and v or nil
    self:ClearFocus()
    if ns.SelfState then ns.SelfState.Update() end
    if ns.Comm then ns.Comm.QueueSnapshot() end
  end
  qBox:SetScript("OnEnterPressed", commitQuest)
  qBox:SetScript("OnEditFocusLost", commitQuest)

  local qClear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  qClear:SetSize(120, 22)
  qClear:SetPoint("LEFT", qBox, "RIGHT", 8, 0)
  qClear:SetText(L["Use super-tracked"])
  qClear:SetScript("OnClick", function()
    ns.db.pinnedQuestID = nil
    qBox:SetText("")
    if ns.SelfState then ns.SelfState.Update() end
    if ns.Comm then ns.Comm.QueueSnapshot() end
  end)

  -- RIGHT COLUMN ------------------------------------------------------------
  header(L["Visible rows"], rightX, y)
  local ry = y - 24
  local rowDefs = {
    { "durability", L["Repairs / durability"] },
    { "flask",      L["Flask"] },
    { "food",       L["Food buff"] },
    { "wpn",        L["Weapon oil"] },
    { "rune",       L["Augment rune"] },
    { "bags",       L["Bag space"] },
    { "quest",      L["Quest section"] },
  }
  for _, def in ipairs(rowDefs) do
    local key, label = def[1], def[2]
    local cb = makeCheck(panel, label, nil,
      function() return ns.db.show[key] end,
      function(v) ns.db.show[key] = v end)
    cb:SetPoint("TOPLEFT", rightX, ry); ry = ry - 26
  end

  ry = ry - 10
  header(L["Blocking checks (red on fail)"], rightX, ry); ry = ry - 24
  local sevDefs = {
    { "durability",    L["Durability"] },
    { "flask",         L["Flask"] },
    { "food",          L["Food"] },
    { "bags",          L["Bags"] },
    { "wpn",           L["Weapon oil"] },
    { "rune",          L["Aug rune"] },
    { "questMismatch", L["Quest mismatch"] },
  }
  for _, def in ipairs(sevDefs) do
    local cb = makeSeverityCheck(panel, def[2], def[1])
    cb:SetPoint("TOPLEFT", rightX, ry); ry = ry - 26
  end

  return panel
end

-- ---------------------------------------------------------------------------
-- Register with Blizzard settings UI
-- ---------------------------------------------------------------------------
function Settings.Init()
  if categoryID ~= nil or Settings.panel then return end
  local panel = buildPanel()
  Settings.panel = panel

  if _G.Settings and Settings.RegisterCanvasLayoutCategory then
    -- Modern (Dragonflight+/Midnight) Settings API.
    local category = _G.Settings.RegisterCanvasLayoutCategory(panel, "BetterTogether")
    category.ID = "BetterTogether"
    _G.Settings.RegisterAddOnCategory(category)
    categoryID = category
  elseif InterfaceOptions_AddCategory then
    -- Legacy fallback.
    InterfaceOptions_AddCategory(panel)
    categoryID = panel
  end
  ns:Debug("Settings registered")
end

function Settings.Open()
  if _G.Settings and _G.Settings.OpenToCategory and categoryID then
    _G.Settings.OpenToCategory(categoryID.ID or categoryID)
  elseif InterfaceOptionsFrame_OpenToCategory and Settings.panel then
    InterfaceOptionsFrame_OpenToCategory(Settings.panel)
    InterfaceOptionsFrame_OpenToCategory(Settings.panel) -- twice: known Blizzard quirk
  else
    ns:Print("settings UI unavailable; use |cffffff00/bt|r commands")
  end
end

return Settings
