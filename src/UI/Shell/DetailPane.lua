--[[ UI/Shell/DetailPane.lua
  The shared right-side preview/detail pane (ns.UI.DetailPane). A page opts in via its
  descriptor's `detail = true`; the pane then shows whatever that page renders into it
  (an item tooltip, a quest's objectives, an achievement). This module owns only the
  *surface* — the chip / name / body / spinner widgets and a scroll frame — and knows
  nothing about items vs quests vs achievements. Pages own what they draw.

  Handoff model: a page calls DetailPane.Render(fn) to make `fn` the active renderer
  (it draws into the exposed widgets) and run it once. DetailPane.Rerender() re-runs the
  active renderer (used by Refresh and by a page's own data-arrival events, gated with
  IsActiveRenderer so a background item-info load can't clobber a quest's detail).
  DetailPane.Clear() drops the renderer and restores the hint.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local DetailPane = {}
ns.UI.DetailPane = DetailPane

local Theme = ns.UI.Theme
local Widgets = ns.UI.Widgets
local Layout = ns.UI.Layout
local L = ns.L

local PAD, DETAIL_W = Layout.PAD, Layout.DETAIL_W

local currentRenderer

-- ---------------------------------------------------------------------------
-- Loading spinner (shown while we wait on a partner's full item string, or on a
-- base item-data load). Idempotent so a re-render mid-wait doesn't restart it.
-- ---------------------------------------------------------------------------
--- @param y number|nil Vertical offset from the body's top (default -64).
function DetailPane.StartSpinner(y)
  local sp = DetailPane.spinner
  if not sp then return end
  sp:ClearAllPoints()
  sp:SetPoint("TOP", DetailPane.body, "TOP", 0, y or -64)
  if not sp:IsShown() then sp:Start() end
  return sp
end
function DetailPane.StopSpinner()
  if DetailPane.spinner then DetailPane.spinner:Stop() end
end

-- ---------------------------------------------------------------------------
-- Visibility + header
-- ---------------------------------------------------------------------------
--- Show/hide the pane + its divider together.
function DetailPane.SetShown(shown)
  if not DetailPane.frame then return end
  DetailPane.frame:SetShown(shown); DetailPane.div:SetShown(shown)
end
function DetailPane.IsShown()
  return DetailPane.frame and DetailPane.frame:IsShown()
end
--- Set the pane's section header + the hint shown when nothing is previewed.
function DetailPane.SetHeader(title, hint)
  Widgets.StyleHeader(DetailPane.hdr, title or L["Item Details"], DETAIL_W)
  DetailPane.hint:SetText(hint or L["Hover an item to preview it here."])
end

-- ---------------------------------------------------------------------------
-- Renderer handoff
-- ---------------------------------------------------------------------------
--- Make `fn` the active renderer and draw it once. No-op if the pane is hidden
--- (the active page doesn't use a detail pane), matching the old show guard.
function DetailPane.Render(fn)
  if not DetailPane.IsShown() then return end
  currentRenderer = fn
  DetailPane.hint:Hide()
  fn()
end
--- Re-run the active renderer (e.g. after a refresh or a data-arrival event).
function DetailPane.Rerender()
  if currentRenderer and DetailPane.IsShown() then currentRenderer() end
end
--- True when `fn` is the currently active renderer — pages gate their own
--- data-arrival re-renders on this so they can't draw over another page's detail.
function DetailPane.IsActiveRenderer(fn)
  return currentRenderer == fn
end
--- Drop the active renderer and restore the empty/hint pane.
function DetailPane.Clear()
  currentRenderer = nil
  if not DetailPane.frame then return end
  DetailPane.StopSpinner()
  DetailPane.chip:Hide()
  DetailPane.qchip:Hide()
  DetailPane.qlabel:Hide()
  DetailPane.text:Hide()
  DetailPane.name:SetText("")
  DetailPane.hint:Show()
  DetailPane.body:SetHeight(40)
  DetailPane.scroll:SetVerticalScroll(0); DetailPane.scroll:UpdateScrollChildRect()
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
--- @param content table The panel's content inset.
function DetailPane.Build(content)
  -- Right-side preview/detail pane (Plumber-style). Pages opt in via desc.detail.
  local detailDiv = content:CreateTexture(nil, "ARTWORK")
  detailDiv:SetColorTexture(1, 1, 1, 0.08); detailDiv:SetWidth(1)
  detailDiv:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD - DETAIL_W - 9, -PAD)
  detailDiv:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -PAD - DETAIL_W - 9, PAD)
  DetailPane.div = detailDiv

  local detail = CreateFrame("Frame", nil, content)
  -- Anchor top AND bottom to content so the pane's height tracks the actual inset
  -- bounds (not a fixed inner-height estimate); otherwise the scroll frame's clip edge
  -- lands just past the bottom border and long tooltips peek out beneath it.
  detail:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, -PAD)
  detail:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -PAD, PAD)
  detail:SetWidth(DETAIL_W)
  DetailPane.frame = detail

  local dHdr = Widgets.SectionHeader(detail)
  dHdr.label:SetPoint("TOPLEFT", detail, "TOPLEFT", 0, 0)
  Widgets.StyleHeader(dHdr, L["Item Details"], DETAIL_W)
  DetailPane.hdr = dHdr

  -- scrollable area (long recipe/item tooltips can exceed the pane height)
  local dscroll = CreateFrame("ScrollFrame", nil, detail, "UIPanelScrollFrameTemplate")
  dscroll:SetPoint("TOPLEFT", detail, "TOPLEFT", 0, -38)
  dscroll:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -16, 0)
  dscroll:EnableMouseWheel(true)
  dscroll:SetScript("OnMouseWheel", function(self, d)
    self:SetVerticalScroll(math.min(self:GetVerticalScrollRange(), math.max(0, self:GetVerticalScroll() - d * 40)))
  end)
  DetailPane.scroll = dscroll
  Widgets.StyleScrollbar(dscroll)

  local body = CreateFrame("Frame", nil, dscroll)
  body:SetWidth(DETAIL_W - 18); body:SetHeight(10)
  dscroll:SetScrollChild(body)
  DetailPane.body = body

  local hint = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  hint:SetPoint("TOPLEFT", body, "TOPLEFT", 2, -2); hint:SetWidth(DETAIL_W - 4); hint:SetJustifyH("LEFT")
  hint:SetTextColor(0.6, 0.6, 0.62); hint:SetText(L["Hover an item to preview it here."])
  DetailPane.hint = hint

  -- Custom (non-tooltip) item detail, styled as part of the addon:
  -- chip (same as throughout) + name (vertically centered) + scanned lines.
  local chip = Widgets.Chip(body, 46); chip:SetPoint("TOPLEFT", body, "TOPLEFT", 2, -2); chip:Hide()
  DetailPane.chip = chip

  local dn = body:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  dn:SetPoint("LEFT", chip, "RIGHT", 10, 0)   -- single anchor (vertical center of chip)
  dn:SetWidth(DETAIL_W - 64); dn:SetJustifyH("LEFT"); dn:SetJustifyV("MIDDLE"); dn:SetWordWrap(false)
  DetailPane.name = dn

  local dt = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  dt:SetWidth(DETAIL_W - 26); dt:SetJustifyH("LEFT"); dt:SetJustifyV("TOP"); dt:SetSpacing(5)
  local dff = GameFontHighlight:GetFont(); if dff then dt:SetFont(dff, 13) end
  dt:Hide(); DetailPane.text = dt

  -- Loading spinner for the detail pane: shown while we wait on the partner's full
  -- item string (the on-demand inventory lookup) or on the base item data load.
  local dspin = Widgets.Spinner(body, 36); DetailPane.spinner = dspin

  -- crafting-quality shown as one of our chips
  local qchip = Widgets.Chip(body, 30); qchip:Hide(); DetailPane.qchip = qchip
  local qlbl = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  qlbl:SetPoint("LEFT", qchip, "RIGHT", 10, 0); qlbl:SetJustifyH("LEFT"); qlbl:Hide()
  local qff = GameFontHighlight:GetFont(); if qff then qlbl:SetFont(qff, 14) end
  DetailPane.qlabel = qlbl

  detail:Hide()
end

return DetailPane
