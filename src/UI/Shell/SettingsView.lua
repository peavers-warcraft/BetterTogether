--[[ UI/Shell/SettingsView.lua
  The consolidated Settings view (ns.UI.SettingsView) — the right-hand bottom tab. A
  full-width scrollable column of options (built by ns.UI.SettingsTab) paired with a
  right-side tips pane that mirrors the dashboard pages' detail pane but renders a plain
  explanation for the setting under the cursor.

  SettingsView.Build(content) constructs the host + tips pane. SettingsView.Refresh(ctx)
  populates them (called from Dashboard.Refresh on the settings tab); SettingsView.Hide()
  tucks them away on the dashboard tab. SetSettingTip / ResetSettingTip drive the tips
  pane (SettingsTab calls SetSettingTip on hover).
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local SettingsView = {}
ns.UI.SettingsView = SettingsView

local Theme = ns.UI.Theme
local Widgets = ns.UI.Widgets
local Layout = ns.UI.Layout
local L = ns.L

local PAD, DETAIL_W = Layout.PAD, Layout.DETAIL_W

local settingsHost, settingsFrame, building
local sTip, sTipDiv, stChip, stName, stText

-- Default copy for the settings tips pane (shown until a setting is hovered).
local DEFAULT_SETTING_TIP =
  L["Hover any option on the left and its explanation appears here.\n\nEverything in Settings is saved automatically — there's no apply button."]

--- Populate the tips pane. With a title, shows a chip + gold name + body for the
--- focused setting; with no title, shows just the default body from the top.
--- @param title string|nil Setting name.
--- @param body string Explanation text.
--- @param icon string|number|nil Icon art for the chip (defaults to a gear).
function SettingsView.SetSettingTip(title, body, icon)
  if not sTip then return end
  if title and title ~= "" then
    Theme.ApplyIcon(stChip.icon, icon or Theme.I_GEAR)
    stChip:Show()
    stName:SetText(title); stName:Show()
    stText:ClearAllPoints()
    stText:SetPoint("TOPLEFT", stChip, "BOTTOMLEFT", 0, -14)
  else
    stChip:Hide(); stName:Hide()
    stText:ClearAllPoints()
    stText:SetPoint("TOPLEFT", sTip, "TOPLEFT", 0, -42)
  end
  stText:SetText(body or "")
end

--- Restore the tips pane to its neutral default (no setting focused).
function SettingsView.ResetSettingTip() SettingsView.SetSettingTip(nil, DEFAULT_SETTING_TIP) end

--- Hide the settings column + tips pane (dashboard tab is active).
function SettingsView.Hide()
  if not settingsHost then return end
  settingsHost:Hide()
  sTip:Hide(); sTipDiv:Hide()
end

--- Show + populate the settings column and tips pane.
--- @param ctx table { snap, verdict, r, g, b }
function SettingsView.Refresh(ctx)
  local w = Layout.settingsScrollWidth()
  sTip:Show(); sTipDiv:Show()
  settingsHost:Show(); settingsHost:SetWidth(w)
  -- Guard against re-entrancy while building: a widget's setup (e.g. a slider's initial
  -- SetValue) can fire a callback that calls Refresh() again before settingsFrame is
  -- assigned, which would re-build and recurse until the stack overflows. Skip if a
  -- build is already in flight.
  if not settingsFrame and not building and ns.UI.SettingsTab then
    building = true
    settingsFrame = ns.UI.SettingsTab.build(settingsHost)
    settingsHost:SetScrollChild(settingsFrame)
    building = false
  end
  if settingsFrame then
    settingsFrame:Show()
    if ns.UI.SettingsTab.refresh then
      ns.UI.SettingsTab.refresh(settingsFrame, { snap = ctx.snap, verdict = ctx.verdict, width = w, r = ctx.r, g = ctx.g, b = ctx.b })
    end
    settingsHost:UpdateScrollChildRect()
  end
  local ssb = settingsHost.ScrollBar
  if ssb then ssb:SetShown((settingsHost:GetVerticalScrollRange() or 0) > 1) end
end

--- @param content table The panel's content inset.
function SettingsView.Build(content)
  -- Full-width scroll host for the Settings tab (no left nav / detail pane). Lives
  -- alongside the page host; the bottom tab bar toggles which is visible.
  settingsHost = CreateFrame("ScrollFrame", "BetterTogetherSettingsScroll", content, "UIPanelScrollFrameTemplate")
  settingsHost:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -PAD)
  settingsHost:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", PAD, PAD)
  settingsHost:SetWidth(Layout.settingsScrollWidth())
  settingsHost:EnableMouseWheel(true)
  settingsHost:SetScript("OnMouseWheel", function(self, delta)
    local new = math.min(self:GetVerticalScrollRange(), math.max(0, self:GetVerticalScroll() - delta * 45))
    self:SetVerticalScroll(new)
  end)
  settingsHost:Hide()
  Widgets.StyleScrollbar(settingsHost)

  -- Settings tips pane: a right-side helper column that mirrors the dashboard pages'
  -- detail pane, but renders a plain explanation for the setting under the cursor.
  sTipDiv = content:CreateTexture(nil, "ARTWORK")
  sTipDiv:SetColorTexture(1, 1, 1, 0.08); sTipDiv:SetWidth(1)
  sTipDiv:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD - DETAIL_W - 9, -PAD)
  sTipDiv:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -PAD - DETAIL_W - 9, PAD)
  sTipDiv:Hide()

  sTip = CreateFrame("Frame", nil, content)
  sTip:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, -PAD)
  sTip:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -PAD, PAD)
  sTip:SetWidth(DETAIL_W)
  local stHdr = Widgets.SectionHeader(sTip)
  stHdr.label:SetPoint("TOPLEFT", sTip, "TOPLEFT", 0, 0)
  Widgets.StyleHeader(stHdr, L["Settings help"], DETAIL_W)
  stChip = Widgets.Chip(sTip, 40)
  stChip:SetPoint("TOPLEFT", sTip, "TOPLEFT", 0, -42); stChip:Hide()
  stName = sTip:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  stName:SetWidth(DETAIL_W - 52); stName:SetJustifyH("LEFT"); stName:SetJustifyV("MIDDLE")
  stName:SetTextColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3])
  stName:SetPoint("LEFT", stChip, "RIGHT", 10, 0); stName:Hide()
  stText = sTip:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  stText:SetWidth(DETAIL_W - 2); stText:SetJustifyH("LEFT"); stText:SetJustifyV("TOP"); stText:SetSpacing(6)
  local stff = GameFontHighlight:GetFont(); if stff then stText:SetFont(stff, Theme.FONT_BODY) end
  sTip:Hide()
end

return SettingsView
