--[[ UI/Dashboard.lua
  The tab shell orchestrator (ns.Dashboard). It owns the page registry and the panel
  lifecycle: it builds the root frame, then hands construction of each piece to a focused
  module under src/UI/Shell/ (Header, Nav, DetailPane, Compact, SettingsView, Scaling)
  and to the proactive Presence layer. Select swaps the active page into the scroll host;
  Refresh fans the current context out to whichever view is showing.

  Pages register via Dashboard.RegisterPage and own everything they draw — including what
  they render into the shared DetailPane (ns.UI.DetailPane). The collapse (-) button
  drops to ns.UI.Compact's single-column readiness card.

  Public API kept stable for Core.lua / SettingsTab: Init / Refresh / ApplyMode / OpenTab /
  OpenSettings / Select / ShowMainTab / Show / Hide / SetScale / SavePosition /
  RestorePosition / ApplyLock.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Dashboard = {}
ns.Dashboard = Dashboard

local S = ns.UI.Shared
local Widgets = ns.UI.Widgets
local Layout = ns.UI.Layout
local L = ns.L

local WIDTH_COMPACT, WIDTH_EXPANDED = Layout.WIDTH_COMPACT, Layout.WIDTH_EXPANDED
local PANEL_H_EXPANDED, CONTENT_TOP = Layout.PANEL_H_EXPANDED, Layout.CONTENT_TOP
local PAD, HOST_X = Layout.PAD, Layout.HOST_X

local panel, host
local pages, pagesByKey = {}, {}
local activeKey
local activeMainTab = "dashboard"
local shouldShow = true

-- ---------------------------------------------------------------------------
-- Page registry (pages register at load; built lazily on first Select)
-- ---------------------------------------------------------------------------
--- Register a tab page. Pages call this at load; the shell builds them lazily.
--- @param desc table { key, label, order, detail?, detailTitle?, detailHint?,
---   separator?, build(host)->frame, refresh(frame, ctx)->height, onShow? }
function Dashboard.RegisterPage(desc)
  table.insert(pages, desc)
  pagesByKey[desc.key] = desc
end

-- ---------------------------------------------------------------------------
-- Shared partner context (snap + verdict). The "wait" verdict surfaces in the
-- title bar as the sync/waiting indicator; we no longer dim the whole panel for
-- it (the fade read as an ugly translucent window).
-- ---------------------------------------------------------------------------
local function getContext()
  local bonded = ns.Pairing and ns.Pairing.PartnerName()
  local partner = ns.state.partner
  if not ns.state.linked or not partner then
    ns.state.partnerName = (bonded and ns.Pairing.ShortName(bonded)) or L["not paired"]
    -- A bonded partner with no live link has logged off (or hasn't come online
    -- yet): show a calm "offline" rather than a "waiting/syncing" indicator.
    return {}, bonded and "offline" or "wait"
  end
  local stale = (GetTime() - (partner.lastSeen or 0)) > ns.STALE_AFTER
  return partner, stale and "wait" or ns.Snapshot.ComputeVerdict(partner, ns.db)
end
Dashboard.GetContext = getContext

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
function Dashboard.Init()
  if panel then return end

  panel = CreateFrame("Frame", "BetterTogetherPanel", UIParent, "ButtonFrameTemplate")
  panel:SetSize(WIDTH_EXPANDED, 360)
  panel:SetClampedToScreen(true)
  panel:SetMovable(true); panel:EnableMouse(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetFrameStrata("HIGH"); panel:SetToplevel(true)
  panel:SetScript("OnMouseDown", function(self) self:Raise() end)
  panel:SetScript("OnDragStart", function(self) if not ns.db.locked then self:StartMoving() end end)
  panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); Dashboard.SavePosition() end)
  -- Closing the panel (Escape, X, or otherwise) clears the desired-visibility
  -- flag so a later refresh won't re-show it.
  panel:SetScript("OnHide", function() shouldShow = false end)
  table.insert(UISpecialFrames, "BetterTogetherPanel")  -- Escape closes the panel

  if panel.TitleContainer then
    panel.TitleContainer:EnableMouse(true); panel.TitleContainer:RegisterForDrag("LeftButton")
    panel.TitleContainer:SetScript("OnDragStart", function() if not ns.db.locked then panel:StartMoving() end end)
    panel.TitleContainer:SetScript("OnDragStop", function() panel:StopMovingOrSizing(); Dashboard.SavePosition() end)
  end
  if panel.CloseButton then panel.CloseButton:SetScript("OnClick", function() panel:Hide() end) end

  local content = panel.Inset or panel
  panel.content = content

  -- Modern dark background covering the template's parchment inset.
  local bg = content:CreateTexture(nil, "BACKGROUND")
  bg:SetPoint("TOPLEFT", content, "TOPLEFT", 3, -3)
  bg:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -3, 3)
  bg:SetColorTexture(0.05, 0.055, 0.07, 0.94)
  panel.bg = bg

  -- Subtle vignette: soft inner shadows top & bottom for depth.
  if CreateColor then
    local topSh = content:CreateTexture(nil, "ARTWORK")
    topSh:SetPoint("TOPLEFT", content, "TOPLEFT", 3, -3); topSh:SetPoint("TOPRIGHT", content, "TOPRIGHT", -3, -3)
    topSh:SetHeight(30); topSh:SetColorTexture(1, 1, 1, 1)
    topSh:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.5))
    local botSh = content:CreateTexture(nil, "ARTWORK")
    botSh:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 3, 3); botSh:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -3, 3)
    botSh:SetHeight(30); botSh:SetColorTexture(1, 1, 1, 1)
    botSh:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.5), CreateColor(0, 0, 0, 0))
  end

  ns.UI.Header.Build(panel)

  -- Scrollable content host (fixed window; content scrolls — Plumber-style). Anchor
  -- top AND bottom to content so the scroll viewport's clip edge tracks the real inset
  -- bounds; with only a fixed inner-height estimate the last row spills past the bottom
  -- border before scrolling. Width is set live by Refresh.
  host = CreateFrame("ScrollFrame", "BetterTogetherScroll", content, "UIPanelScrollFrameTemplate")
  host:SetPoint("TOPLEFT", content, "TOPLEFT", HOST_X, -PAD)
  host:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", HOST_X, PAD)
  host:SetWidth(Layout.scrollWidth())
  host:EnableMouseWheel(true)
  host:SetScript("OnMouseWheel", function(self, delta)
    local new = math.min(self:GetVerticalScrollRange(), math.max(0, self:GetVerticalScroll() - delta * 45))
    self:SetVerticalScroll(new)
  end)
  panel.host = host
  Widgets.StyleScrollbar(host)

  -- Sort pages by order, then let each shell part build itself.
  table.sort(pages, function(a, b) return (a.order or 99) < (b.order or 99) end)
  ns.UI.Nav.Build(panel, content, pages)
  ns.UI.DetailPane.Build(content)
  ns.UI.SettingsView.Build(content)
  ns.UI.EmptyState.Build(content)
  ns.UI.Compact.Build(content)

  Dashboard.RestorePosition()
  ns.UI.Scaling.Init(panel)
  Dashboard.Select(ns.chardb.lastTab or "overview")
  Dashboard.ShowMainTab(ns.chardb.lastMainTab or "dashboard")
  Dashboard.ApplyMode()
  C_Timer.NewTicker(2.0, function() Dashboard.Refresh() end)
end

-- ---------------------------------------------------------------------------
-- Position / lock / scale / mode / tabs
-- ---------------------------------------------------------------------------
function Dashboard.SavePosition()
  local point, _, relPoint, x, y = panel:GetPoint()
  ns.chardb.point = { point, nil, relPoint, x, y }
end
function Dashboard.RestorePosition()
  local p = ns.chardb.point
  panel:ClearAllPoints()
  panel:SetPoint(p[1] or "CENTER", UIParent, p[3] or "CENTER", p[4] or 0, p[5] or 0)
end
-- Intentional no-op: the lock state (ns.db.locked) is enforced lazily inside the
-- drag handlers (OnDragStart bails when locked), so there is nothing to re-apply
-- when it toggles. Kept as a stable hook for callers (Settings, /bt lock).
function Dashboard.ApplyLock() end
function Dashboard.SetScale(s) ns.db.scale = s; ns.UI.Scaling.Apply() end
function Dashboard.Show() shouldShow = true; if panel then panel:Show() end end
function Dashboard.Hide() shouldShow = false; if panel then panel:Hide() end end
function Dashboard.ApplyMode()
  if not panel then return end
  panel.collapseBtn:SetText(ns.db.expanded and "–" or "+")
  Dashboard.Refresh()
end

function Dashboard.OpenTab(key)
  ns.db.expanded = true
  if panel then
    Dashboard.ShowMainTab("dashboard")   -- left-nav pages live under the Dashboard tab
    Dashboard.Select(key); Dashboard.ApplyMode(); Dashboard.Show()
  end
end

-- Open the panel straight to the consolidated Settings tab.
function Dashboard.OpenSettings()
  if not panel then return end
  Dashboard.Show()
  Dashboard.ShowMainTab("settings")
end

--- Switch the top-level view between the dashboard and the settings page.
--- @param key string "dashboard" | "settings"
function Dashboard.ShowMainTab(key)
  if key ~= "settings" then key = "dashboard" end
  activeMainTab = key
  ns.chardb.lastMainTab = key
  ns.UI.Nav.HighlightMainTab(key)
  if key == "settings" then ns.UI.SettingsView.ResetSettingTip() end
  Dashboard.Refresh()
end

--- Switch the visible tab to `key` (falls back to the first page).
--- @param key string A registered page key.
function Dashboard.Select(key)
  local desc = pagesByKey[key] or pages[1]
  if not desc then return end
  activeKey = desc.key
  ns.chardb.lastTab = desc.key
  if not desc.frame and desc.build then desc.frame = desc.build(host) end
  for _, d in ipairs(pages) do if d.frame and d ~= desc then d.frame:Hide() end end
  if desc.frame then
    host:SetScrollChild(desc.frame)
    desc.frame:SetShown(ns.db.expanded)
    if ns.db.expanded and UIFrameFadeIn then
      desc.frame:SetAlpha(0); UIFrameFadeIn(desc.frame, 0.18, 0, 1)
    end
  end
  host:SetVerticalScroll(0)
  if desc.detail then
    ns.UI.DetailPane.Clear()
    ns.UI.DetailPane.SetHeader(desc.detailTitle, desc.detailHint)
  end
  if desc.onShow then desc.onShow() end
  ns.UI.Nav.HighlightPage(desc.key)
  Dashboard.Refresh()
end

-- ---------------------------------------------------------------------------
-- Refresh — fan the current context out to whichever view is showing
-- ---------------------------------------------------------------------------
function Dashboard.Refresh()
  if not panel then return end
  local snap, verdict = getContext()
  ns.UI.Header.Update(snap, verdict)
  ns.UI.Presence.Notify(snap, verdict)

  local r, g, b = S.classColor(snap.cls)

  if activeMainTab == "settings" then
    -- SETTINGS tab: hide the dashboard view; show the settings column + its tips pane.
    ns.UI.Nav.SetShown(false); host:Hide()
    ns.UI.DetailPane.SetShown(false)
    ns.UI.EmptyState.SetShown(false)
    for _, d in ipairs(pages) do if d.frame then d.frame:Hide() end end
    ns.UI.Compact.SetShown(false)
    panel.collapseBtn:Hide()          -- compact mode doesn't apply to settings
    panel:SetWidth(WIDTH_EXPANDED)    -- always full size, even if the dashboard was collapsed
    panel:SetHeight(PANEL_H_EXPANDED)
    ns.UI.SettingsView.Refresh({ snap = snap, verdict = verdict, r = r, g = g, b = b })
    panel:SetShown(shouldShow)
    return
  end

  -- DASHBOARD tab: settings hidden, collapse affordance available again.
  ns.UI.SettingsView.Hide()
  panel.collapseBtn:Show()

  if not ns.db.expanded then
    -- COMPACT
    ns.UI.Nav.SetShown(false); host:Hide()
    ns.UI.EmptyState.SetShown(false)
    for _, d in ipairs(pages) do if d.frame then d.frame:Hide() end end
    ns.UI.Compact.SetShown(true)
    panel:SetWidth(WIDTH_COMPACT)
    local h = ns.UI.Compact.Layout(snap, r, g, b)
    panel:SetHeight(CONTENT_TOP + h)
    panel:SetShown(shouldShow)
    return
  end

  -- EXPANDED (tabbed) — FIXED window size, content scrolls
  ns.UI.Compact.SetShown(false)
  ns.UI.Nav.SetShown(true)
  panel:SetWidth(WIDTH_EXPANDED)
  panel:SetHeight(PANEL_H_EXPANDED)

  local desc = pagesByKey[activeKey] or pages[1]

  -- Decide whether this page has nothing to show and should hand the whole content area
  -- (page host + detail pane) to the shared centered prompt. Two cases:
  --   * No live partner — every data page is a you-vs-partner comparison, so there's
  --     nothing to compare. Skipped on pages that manage pairing itself (skipEmptyState).
  --   * The page itself reports an empty state (desc.emptyState) — e.g. the partner has
  --     turned off sharing that data type. Only consulted while a partner is connected.
  -- The left nav stays in both cases so the user can still move around.
  local connected = ns.state.linked and ns.state.partner ~= nil
  local spec
  if not connected and not (desc and desc.skipEmptyState) then
    spec = ns.UI.EmptyState.NoPartnerSpec(verdict, ns.state.partnerName)
  elseif connected and desc and desc.emptyState then
    spec = desc.emptyState(snap, verdict)
  end

  if spec then
    host:Hide()
    ns.UI.DetailPane.SetShown(false)
    for _, d in ipairs(pages) do if d.frame then d.frame:Hide() end end
    ns.UI.EmptyState.Show(spec)
    panel:SetShown(shouldShow)
    return
  end
  ns.UI.EmptyState.SetShown(false)
  host:Show()

  local detailOn = desc and desc.detail or false
  ns.UI.DetailPane.SetShown(detailOn)
  host:SetWidth(Layout.scrollWidth(detailOn))

  if desc then
    if not desc.frame and desc.build then desc.frame = desc.build(host) end
    if desc.frame then
      if host:GetScrollChild() ~= desc.frame then host:SetScrollChild(desc.frame) end
      desc.frame:Show()
      if desc.refresh then desc.refresh(desc.frame, { snap = snap, verdict = verdict, width = Layout.scrollWidth(detailOn), r = r, g = g, b = b }) end
      host:UpdateScrollChildRect()
    end
  end
  if detailOn then ns.UI.DetailPane.Rerender() end
  -- Hide the scrollbar entirely when the page fits (no stray arrows).
  local sb = host.ScrollBar
  if sb then sb:SetShown((host:GetVerticalScrollRange() or 0) > 1) end
  panel:SetShown(shouldShow)
end

return Dashboard
