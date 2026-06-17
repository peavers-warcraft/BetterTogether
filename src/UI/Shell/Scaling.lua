--[[ UI/Shell/Scaling.lua
  Auto-fit scaling for the panel (ns.UI.Scaling). The expanded panel is a fixed
  WIDTH_EXPANDED x PANEL_H_EXPANDED, sized to nearly fill a standard 768-unit-tall UI.
  On large monitors / low WoW UI-scale (notably 4K, where UIParent sits near its 768px
  floor) a raw scale of 1.0 makes the panel dominate the screen, so we derive a base
  scale that keeps it within a comfortable fraction of the available space. ns.db.scale
  then multiplies this: 1.0 = the recommended fit; raise or lower to taste.

  Scaling.Init(panel) stores the panel and keeps the fit current across resolution /
  UI-scale changes. Scaling.Apply re-applies; Dashboard.SetScale forwards here.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Scaling = {}
ns.UI.Scaling = Scaling

local Layout = ns.UI.Layout

local panel

local FIT_W, FIT_H = 0.66, 0.46   -- target fraction of the screen the panel covers
local function fitScale()
  local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
  if not (sw and sh) or sw <= 0 or sh <= 0 then return 1.0 end
  local s = math.min((sw * FIT_W) / Layout.WIDTH_EXPANDED, (sh * FIT_H) / Layout.PANEL_H_EXPANDED)
  return math.max(0.5, math.min(1.0, s))   -- never upscale past the design size
end
Scaling.fitScale = fitScale

function Scaling.Apply()
  if not panel then return end
  panel:SetScale(math.max(0.4, math.min(2.0, fitScale() * (ns.db.scale or 1.0))))
end

-- Diagnostic: dump the numbers that drive scaling so the default can be tuned to
-- match a reference addon (e.g. Plumber). Invoked via `/bt scaleinfo`.
function Scaling.PrintScaleInfo()
  local pw, ph = GetPhysicalScreenSize()
  ns:Print(string.format("physical screen: %s x %s", tostring(pw), tostring(ph)))
  ns:Print(string.format("UIParent: effScale=%.3f height=%.0f units", UIParent:GetEffectiveScale(), UIParent:GetHeight()))
  ns:Print(string.format("fitScale=%.3f  db.scale=%.2f", fitScale(), ns.db.scale or 1.0))
  if panel then
    ns:Print(string.format("panel: scale=%.3f effScale=%.3f  -> ~%.0f%% of screen height",
      panel:GetScale(), panel:GetEffectiveScale(), 100 * (Layout.PANEL_H_EXPANDED * panel:GetScale()) / UIParent:GetHeight()))
  end
  if _G.PlumberDB ~= nil or _G.Plumber ~= nil then ns:Print("(Plumber is loaded — compare its panel size by eye)") end
end

--- Bind the panel and keep its fit current as the display / UI scale changes.
function Scaling.Init(p)
  panel = p
  ns:RegisterEvent("DISPLAY_SIZE_CHANGED", Scaling.Apply)
  ns:RegisterEvent("UI_SCALE_CHANGED", Scaling.Apply)
  Scaling.Apply()
end

return Scaling
