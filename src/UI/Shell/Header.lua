--[[ UI/Shell/Header.lua
  The panel's shared header (ns.UI.Header): class portrait + class-coloured partner
  name + the title-bar verdict dot/label (which doubles as the sync indicator), a soft
  "ping" ring that blooms when the verdict changes, and the collapse (-) toggle.

  Header.Build(panel) constructs the widgets (hung on the panel as vDot / vLabel /
  vPing / collapseBtn so the rest of the shell can show/hide them). Header.Update(snap,
  verdict) repaints them each refresh; Header.Ping(color) flashes the ring (used by the
  presence layer even when toasts are off).
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Header = {}
ns.UI.Header = Header

local S = ns.UI.Shared
local Theme = ns.UI.Theme
local L = ns.L

local panel

-- ---------------------------------------------------------------------------
-- Portrait + title helpers (tolerate the ButtonFrameTemplate's various layouts)
-- ---------------------------------------------------------------------------
local function getPortrait()
  return (panel.PortraitContainer and panel.PortraitContainer.portrait) or panel.portrait
end
local function setTitle(text)
  if panel.SetTitle then panel:SetTitle(text)
  elseif panel.TitleContainer and panel.TitleContainer.TitleText then panel.TitleContainer.TitleText:SetText(text)
  elseif _G[panel:GetName() .. "TitleText"] then _G[panel:GetName() .. "TitleText"]:SetText(text) end
end
local function setPortrait(cls)
  local p = getPortrait(); if not p then return end
  local atlas = (cls and cls ~= "") and ("classicon-" .. strlower(cls)) or nil
  if atlas and Theme.AtlasExists(atlas) then p:SetTexCoord(0, 1, 0, 1); p:SetAtlas(atlas)
  elseif cls and cls ~= "" and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls] then
    p:SetTexture(Theme.CLASS_CIRCLES); p:SetTexCoord(unpack(CLASS_ICON_TCOORDS[cls]))
  else p:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark"); p:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
end

--- Repaint the header from the current partner snapshot + verdict.
function Header.Update(snap, verdict)
  local r, g, b = S.classColor(snap.cls)
  setPortrait(snap.cls)
  setTitle(S.hex(r, g, b) .. (ns.state.partnerName or L["Partner"]) .. "|r")
  panel.vDot:SetTexture(Theme.INDICATOR[verdict] or Theme.INDICATOR.wait)
  local vc = Theme.VERDICT_RGB[verdict] or Theme.VERDICT_RGB.wait
  panel.vLabel:SetText(Theme.VERDICT_LABEL[verdict] or ""); panel.vLabel:SetTextColor(vc[1], vc[2], vc[3])
end

--- Flash the verdict-change ping ring in `color` (defaults to gold).
function Header.Ping(color)
  if panel and panel.vPing then panel.vPing(color or Theme.GOLD) end
end

--- Build the title-bar verdict dot + ping + label + collapse toggle.
function Header.Build(p)
  panel = p

  -- title-bar verdict + collapse toggle. The dot + label double as the sync
  -- indicator (gray dot / "WAITING" until the partner's data lands), so keep them
  -- prominent — a larger, clearly-coloured label rather than the old small text.
  local vDot = panel:CreateTexture(nil, "OVERLAY"); vDot:SetSize(18, 18)
  if panel.CloseButton then vDot:SetPoint("RIGHT", panel.CloseButton, "LEFT", -2, 0)
  else vDot:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -6) end
  panel.vDot = vDot

  -- A soft circular ring that blooms out from the dot and fades when the verdict
  -- changes — an at-a-glance "something just happened" cue. Drawn behind the dot
  -- (ARTWORK) so it never hides it; a single OnUpdate runs only while playing.
  local ping = panel:CreateTexture(nil, "ARTWORK")
  ping:SetSize(16, 16); ping:SetPoint("CENTER", vDot, "CENTER", 0, 0)
  ping:SetColorTexture(1, 1, 1, 1)
  local pingMask = panel:CreateMaskTexture()
  pingMask:SetAllPoints(ping); pingMask:SetTexture(Theme.CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  ping:AddMaskTexture(pingMask); ping:Hide()
  local pingDriver = CreateFrame("Frame", nil, panel); pingDriver:Hide()
  local P_DUR, P_BASE, P_PEAK = 0.6, 16, 40
  pingDriver:SetScript("OnUpdate", function(self, dt)
    self.t = (self.t or 0) + dt
    local f = self.t / P_DUR
    if f >= 1 then ping:Hide(); self:Hide(); return end
    ping:SetSize(P_BASE + (P_PEAK - P_BASE) * f, P_BASE + (P_PEAK - P_BASE) * f)
    ping:SetAlpha(0.5 * (1 - f))
  end)
  panel.vPing = function(col)
    col = col or Theme.GOLD
    ping:SetColorTexture(col[1], col[2], col[3], 1)
    pingDriver.t = 0; ping:Show(); pingDriver:Show()
  end

  local vLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal"); vLabel:SetPoint("RIGHT", vDot, "LEFT", -5, 0)
  local vff = GameFontNormal:GetFont(); if vff then vLabel:SetFont(vff, 14) end
  panel.vLabel = vLabel

  local cb = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate"); cb:SetSize(24, 20)
  cb:SetPoint("RIGHT", vLabel, "LEFT", -8, 0); cb:SetText("–")
  cb:SetScript("OnClick", function() ns.db.expanded = not ns.db.expanded; ns.Dashboard.ApplyMode() end)
  panel.collapseBtn = cb
end

return Header
