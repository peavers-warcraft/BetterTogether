--[[ UI/SettingsTab.lua
  The "Settings" bottom-tab page (ns.UI.SettingsTab). A single scrollable column on
  the left paired with a right-side tips pane (driven by SettingsView.SetSettingTip) that
  explains whatever option the cursor is on — the same left-content / right-detail
  shape the dashboard pages use. Sections are sub-headed, checkbox groups lay out in
  two columns, sliders are the themed Widgets.Slider, and the Privacy "share all /
  nothing" actions sit on the Privacy header row.

  It follows the page contract (build(host)->frame, refresh(frame, ctx)->height) but is
  NOT registered via Dashboard.RegisterPage — the Dashboard hosts it directly in its
  settings scroll. All writes land in ns.db / ns.db.privacy as before; the
  Snapshot/Comm encoders still gate on ns.Shares(), so privacy behaviour is unchanged.
]]

local addonName, ns = ...
local Theme = ns.UI.Theme
local Widgets = ns.UI.Widgets
local L = ns.L
local CREAM = Theme.CREAM

local CHECK_H = 26      -- vertical pitch between checkboxes
local SEC_GAP = 20      -- gap before a new section header
local LABEL_GAP = 6     -- checkbox-to-label spacing
local COL_GAP = 36      -- gap between the two checkbox columns
local COLS = 2          -- checkbox grid columns

ns.UI = ns.UI or {}
local SettingsTab = {}
ns.UI.SettingsTab = SettingsTab

-- ---------------------------------------------------------------------------
-- Privacy toggle groups (keys match DB_DEFAULTS.privacy / ns.Shares()). `sub` is the
-- one-line description shown under the group's sub-header.
-- ---------------------------------------------------------------------------
local GROUPS = {
  {
    title = L["Readiness"],
    sub = L["Consumables, repairs and bag space your partner can check before a pull."],
    keys = {
      { "durability", L["Durability / repairs"] },
      { "bags",       L["Bag space"] },
      { "flask",      L["Flask"] },
      { "food",       L["Food buff"] },
      { "wpn",        L["Weapon oil"] },
      { "rune",       L["Augment rune"] },
      { "hp",         L["Full health"] },
      { "quest",      L["Tracked quest"] },
    },
  },
  {
    title = L["Character"],
    sub = L["Who you are and what you're carrying right now."],
    keys = {
      { "identity", L["Class, spec & level"] },
      { "gear",     L["Gear: enchants & sockets"] },
      { "keystone", L["Mythic+ keystone"] },
      { "vault",    L["Great Vault progress"] },
      { "location", L["Location & resting"] },
      { "coords",   L["Map coordinates"] },
      { "gold",     L["Gold"] },
      { "supplies", L["Potions & healthstone"] },
    },
  },
  {
    title = L["History & data"],
    sub = L["Longer-term records, each shown on its own tab."],
    keys = {
      { "stats",        L["Shared statistics"] },
      { "inventory",    L["Inventory / bags"] },
      { "questlog",     L["Quest log"] },
      { "achievements", L["Achievements"] },
    },
  },
}

-- ---------------------------------------------------------------------------
-- Tips: every interactive widget reports a title + body to the right-hand pane on
-- hover. attachTip hooks OnEnter (so any template/widget hover behaviour is kept).
-- ---------------------------------------------------------------------------
local function attachTip(frame, title, body, icon)
  frame:HookScript("OnEnter", function()
    if ns.UI.SettingsView and ns.UI.SettingsView.SetSettingTip then ns.UI.SettingsView.SetSettingTip(title, body, icon) end
  end)
end

-- Generated, consistent explanation for a privacy toggle.
local function shareTip(label)
  return string.format(
    L["When ticked, %s is shared with your partner. Unticked, it stays on this client and is never broadcast."],
    string.lower(label))
end

-- A privacy change can't move our own state signatures, so force a resend to push the
-- newly-filtered payload, then repaint so the checkboxes reflect the stored flags.
local function applyPrivacy()
  if ns.Comm then
    if ns.Comm.SendPrivacy then ns.Comm.SendPrivacy() end
    if ns.Comm.QueueSnapshot then ns.Comm.QueueSnapshot(true) end
    if ns.Comm.QueueCard then ns.Comm.QueueCard(true) end
    if ns.Comm.QueueStats then ns.Comm.QueueStats(true) end
  end
  if ns.Dashboard then ns.Dashboard.Refresh() end
end

local function setAllPrivacy(value)
  for _, g in ipairs(GROUPS) do
    for _, def in ipairs(g.keys) do ns.db.privacy[def[1]] = value end
  end
  applyPrivacy()
end

-- ---------------------------------------------------------------------------
-- Widget helpers. `reg` collects checks so refresh can re-sync their state after a
-- "Share all/nothing" bulk toggle.
-- ---------------------------------------------------------------------------
local function makeCheck(parent, label, getter, setter, onChange, reg, tipTitle, tipBody, tipIcon)
  local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
  cb.Text:SetText(label)
  cb.Text:ClearAllPoints()
  cb.Text:SetPoint("LEFT", cb, "RIGHT", LABEL_GAP, 0)
  cb.Text:SetTextColor(CREAM[1], CREAM[2], CREAM[3])
  local ff = GameFontHighlight:GetFont()
  if ff then cb.Text:SetFont(ff, Theme.FONT_SMALL, "") end
  cb._get = getter
  cb:SetScript("OnClick", function(self)
    setter(self:GetChecked() and true or false)
    if onChange then onChange() end
  end)
  cb:SetChecked(getter())
  -- Extend the hit rect rightward to cover the label, so hovering (for the tip) and
  -- clicking (to toggle) both work across the whole row, not just the 26px box.
  cb:SetHitRectInsets(0, -math.max(20, (cb.Text:GetStringWidth() or 0) + LABEL_GAP + 6), 0, 0)
  attachTip(cb, tipTitle or label, tipBody, tipIcon)
  if reg then reg[#reg + 1] = cb end
  return cb
end

local function makeSlider(parent, label, minV, maxV, step, getter, setter, fmt, deferApply, tipBody)
  local c = Widgets.Slider(parent, label, minV, maxV, step, getter, setter, fmt, 340, deferApply)
  attachTip(c.slider, label, tipBody)
  return c
end

-- A blocking/advisory toggle implemented as a checkbox ("<name> is blocking").
local function makeSeverityCheck(parent, label, key, reg)
  return makeCheck(parent, label .. L[" is blocking"],
    function() return ns.db.checks[key] == "blocking" end,
    function(v) ns.db.checks[key] = v and "blocking" or "advisory" end,
    function() if ns.Dashboard then ns.Dashboard.Refresh() end end, reg,
    label, string.format(
      L["When on, a failed %s check turns the partner's verdict red. When off it only shows amber (advisory)."],
      string.lower(label)))
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local function build(host)
  local f = CreateFrame("Frame", nil, host)
  f:SetSize(10, 10)
  f.checks = {}   -- all checkboxes, for state re-sync in refresh

  -- PRIVACY ---------------------------------------------------------------
  f.privHeader = Widgets.SectionHeader(f)
  f.allBtn = Widgets.Button(f, L["Share all"], 78, 22)
  f.allBtn:SetScript("OnClick", function() setAllPrivacy(true) end)
  attachTip(f.allBtn, L["Share all"], L["Turn on sharing for every option below at once."])
  f.noneBtn = Widgets.Button(f, L["Share nothing"], 104, 22)
  f.noneBtn:SetScript("OnClick", function() setAllPrivacy(false) end)
  attachTip(f.noneBtn, L["Share nothing"],
    L["Turn off sharing for every option below. Your partner then sees only that you're online."])
  f.privGroups = {}
  for gi, g in ipairs(GROUPS) do
    local grp = { header = Widgets.SectionHeader(f), checks = {} }
    for _, def in ipairs(g.keys) do
      local key, label = def[1], def[2]
      grp.checks[#grp.checks + 1] = makeCheck(f, label,
        function() return ns.db.privacy[key] ~= false end,
        function(v) ns.db.privacy[key] = v end,
        applyPrivacy, f.checks, label, shareTip(label), Theme.ICON[key])
    end
    f.privGroups[gi] = grp
  end

  -- GENERAL ---------------------------------------------------------------
  f.generalHeader = Widgets.SectionHeader(f)
  f.lockCheck = makeCheck(f, L["Lock panel position"],
    function() return ns.db.locked end,
    function(v) ns.db.locked = v; if ns.Dashboard then ns.Dashboard.ApplyLock() end end,
    nil, f.checks, L["Lock panel position"],
    L["Locks the panel so you can't drag it by accident. Untick to move it, then re-lock."])
  -- Multiplies the auto-fit base scale (1.0 = recommended). Narrow band + fine step on
  -- a wide track keeps the drag smooth and granular.
  f.scaleSlider = makeSlider(f, L["Panel scale"], 0.7, 1.3, 0.02,
    function() return ns.db.scale or 1.0 end,
    function(v) ns.Dashboard.SetScale(v) end,
    function(v) return string.format("%.2f", v) end, true,
    L["Resize the whole panel. 1.00 is the recommended fit for your screen."])
  f.toastCheck = makeCheck(f, L["Show notifications"],
    function() return ns.db.toasts ~= false end,
    function(v) ns.db.toasts = v end, nil, f.checks, L["Show notifications"],
    L["Pop a toast when your partner logs in or out, or when their readiness changes."])
  f.toastSoundCheck = makeCheck(f, L["Notification sound"],
    function() return ns.db.toastSound ~= false end,
    function(v) ns.db.toastSound = v end, nil, f.checks, L["Notification sound"],
    L["Play a short sound alongside each notification."])

  -- THRESHOLDS ------------------------------------------------------------
  f.threshHeader = Widgets.SectionHeader(f)
  f.durSlider = makeSlider(f, L["Minimum durability"], 0, 100, 5,
    function() return ns.db.thresholds.durability end,
    function(v) ns.db.thresholds.durability = v end,
    function(v) return v .. "%" end, false,
    L["Gear at or below this durability counts as 'needs repair' for the readiness check."])

  -- VISIBLE ROWS ----------------------------------------------------------
  f.rowsHeader = Widgets.SectionHeader(f)
  f.rowChecks = {}
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
    f.rowChecks[#f.rowChecks + 1] = makeCheck(f, label,
      function() return ns.db.show[key] end,
      function(v) ns.db.show[key] = v end,
      function() if ns.Dashboard then ns.Dashboard.Refresh() end end, f.checks,
      label, string.format(L["Show the %s row on the dashboard."], string.lower(label)),
      Theme.ICON[key])
  end

  -- BLOCKING CHECKS -------------------------------------------------------
  f.checksHeader = Widgets.SectionHeader(f)
  f.sevChecks = {}
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
    f.sevChecks[#f.sevChecks + 1] = makeSeverityCheck(f, def[2], def[1], f.checks)
  end

  -- BROADCAST QUEST -------------------------------------------------------
  f.questHeader = Widgets.SectionHeader(f)
  f.qLabel = Widgets.SubText(f)
  f.qLabel:SetText(L["Quest ID"])
  f.qBox = Widgets.Input(f, 120, 24)
  f.qBox:SetNumeric(true)
  attachTip(f.qBox, L["Broadcast quest"],
    L["Enter a quest ID to always broadcast that quest. Leave empty to use whatever you're super-tracking."])
  f.qBox:SetScript("OnShow", function(self)
    self:SetText(ns.db.pinnedQuestID and tostring(ns.db.pinnedQuestID) or "")
  end)
  local function commitQuest(self)
    local v = tonumber(self:GetText())
    ns.db.pinnedQuestID = (v and v > 0) and v or nil
    self:ClearFocus()
    if ns.SelfState then ns.SelfState.Update() end
    if ns.Comm then ns.Comm.QueueSnapshot() end
  end
  f.qBox:SetScript("OnEnterPressed", commitQuest)
  f.qBox:SetScript("OnEditFocusLost", commitQuest)
  f.qClear = Widgets.Button(f, L["Use super-tracked"], 140, 24)
  f.qClear:SetScript("OnClick", function()
    ns.db.pinnedQuestID = nil
    f.qBox:SetText("")
    if ns.SelfState then ns.SelfState.Update() end
    if ns.Comm then ns.Comm.QueueSnapshot() end
  end)
  attachTip(f.qClear, L["Use super-tracked"],
    L["Clear the pinned quest and go back to broadcasting whichever quest you're super-tracking."])

  return f
end

-- ---------------------------------------------------------------------------
-- Refresh / layout — left content column; sections sub-headed, checks in 2 columns.
-- ---------------------------------------------------------------------------
local function refresh(f, ctx)
  local W = ctx.width
  f:SetWidth(W)
  local y = 0
  local gridColW = (W - COL_GAP) / COLS

  -- Re-sync checkbox state (a "Share all/nothing" bulk toggle changes many at once).
  for _, cb in ipairs(f.checks) do cb:SetChecked(cb._get() and true or false) end

  -- y starts at the first header (no leading gap); pass gap=true thereafter. `reserve`
  -- shortens the rule so it doesn't run under right-aligned controls on the row.
  local function header(h, title, gap, subtext, reserve)
    if gap then y = y + SEC_GAP end
    h.label:ClearAllPoints(); h.label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y)
    Widgets.StyleHeader(h, title, W - (reserve or 0), subtext)
    y = y + Theme.HEADER_H + Widgets.SubHeight(h) + 6
  end
  local function check(cb)
    cb:ClearAllPoints(); cb:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y)
    y = y + CHECK_H
  end
  local function checkGrid(checks)
    local rows = 0
    for i, cb in ipairs(checks) do
      local col = (i - 1) % COLS
      local row = math.floor((i - 1) / COLS)
      rows = row + 1
      cb:ClearAllPoints()
      cb:SetPoint("TOPLEFT", f, "TOPLEFT", col * (gridColW + COL_GAP), -(y + row * CHECK_H))
    end
    y = y + rows * CHECK_H
  end
  local function slider(c)
    c:ClearAllPoints(); c:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y)
    y = y + Widgets.SLIDER_H + 12
  end

  -- Privacy --------------------------------------------------------------
  local shareReserve = f.noneBtn:GetWidth() + 8 + f.allBtn:GetWidth() + 14
  header(f.privHeader, L["Privacy"], false,
    L["Pick exactly what your partner can see. Unticked items never leave this client."], shareReserve)
  f.noneBtn:ClearAllPoints(); f.noneBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -1)
  f.allBtn:ClearAllPoints(); f.allBtn:SetPoint("RIGHT", f.noneBtn, "LEFT", -8, 0)
  for gi, grp in ipairs(f.privGroups) do
    header(grp.header, GROUPS[gi].title, gi > 1, GROUPS[gi].sub)
    checkGrid(grp.checks)
  end

  -- General --------------------------------------------------------------
  header(f.generalHeader, L["General"], true, L["How the panel behaves and how you're notified."])
  check(f.lockCheck)
  slider(f.scaleSlider)
  checkGrid({ f.toastCheck, f.toastSoundCheck })

  -- Thresholds -----------------------------------------------------------
  header(f.threshHeader, L["Thresholds"], true, L["When a readiness check should count as a problem."])
  slider(f.durSlider)

  -- Visible rows ---------------------------------------------------------
  header(f.rowsHeader, L["Visible rows"], true, L["Which readiness rows appear on the dashboard."])
  checkGrid(f.rowChecks)

  -- Blocking checks ------------------------------------------------------
  header(f.checksHeader, L["Blocking checks"], true,
    L["Which failed checks turn the verdict red instead of a softer amber."])
  checkGrid(f.sevChecks)

  -- Broadcast quest ------------------------------------------------------
  header(f.questHeader, L["Broadcast quest"], true, L["Choose which quest your partner sees you tracking."])
  f.qLabel:ClearAllPoints(); f.qLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -y); f.qLabel:SetWidth(W)
  y = y + f.qLabel:GetStringHeight() + 6
  f.qBox:ClearAllPoints(); f.qBox:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -y)
  f.qClear:ClearAllPoints(); f.qClear:SetPoint("LEFT", f.qBox, "RIGHT", 10, 0)
  y = y + 26

  f:SetHeight(y + 14)
  return y + 14
end

SettingsTab.build = build
SettingsTab.refresh = refresh

return SettingsTab
