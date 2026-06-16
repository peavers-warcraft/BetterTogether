--[[ UI/Pages/Privacy.lua
  Privacy page: per-field toggles for everything DuoReady broadcasts to the
  partner. Each checkbox flips a flag in ns.db.privacy; the Snapshot/Comm encoders
  consult ns.Shares(key) before emitting a field, so an unticked item simply never
  leaves this client. Flags default to true (share), preserving prior behaviour.

  Layout: a short intro + "Share all / nothing" buttons, then the toggles laid out
  in three columns (Readiness / Character / History & data).
]]

local addonName, ns = ...
local Theme = ns.UI.Theme
local Widgets = ns.UI.Widgets
local L = ns.L

local CHECK_H = 28       -- vertical pitch between checkboxes
local COL_GAP = 36       -- gap between the three columns

-- Toggle groups. Each key matches a privacy flag in DB_DEFAULTS.privacy and is
-- read back by ns.Shares() in the encoders. Grouped wire fields (identity, gear,
-- supplies) hide together under one toggle.
local GROUPS = {
  {
    title = L["Readiness"],
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
    keys = {
      { "stats",        L["Shared statistics"] },
      { "inventory",    L["Inventory / bags"] },
      { "questlog",     L["Quest log"] },
      { "achievements", L["Achievements"] },
    },
  },
}

-- A privacy change can't move the snap/card/stats signatures (it doesn't touch our
-- own state), so force a resend to push the new, filtered payload immediately —
-- then repaint so the checkboxes reflect the stored flags.
local function applyPrivacy()
  if ns.Comm then
    -- Tell the partner what changed FIRST, so by the time the filtered SNAP/CARD
    -- lands their UI already knows to show "hidden" rather than "stuck loading".
    if ns.Comm.SendPrivacy then ns.Comm.SendPrivacy() end
    if ns.Comm.QueueSnapshot then ns.Comm.QueueSnapshot(true) end
    if ns.Comm.QueueCard then ns.Comm.QueueCard(true) end
    if ns.Comm.QueueStats then ns.Comm.QueueStats(true) end
  end
  if ns.Dashboard then ns.Dashboard.Refresh() end
end

local function setAll(value)
  for _, g in ipairs(GROUPS) do
    for _, def in ipairs(g.keys) do ns.db.privacy[def[1]] = value end
  end
  applyPrivacy()
end

local function makeCheck(parent, key, label)
  local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
  cb.privKey = key
  cb.Text:SetText(label)
  cb.Text:SetTextColor(Theme.CREAM[1], Theme.CREAM[2], Theme.CREAM[3])
  local ff = GameFontHighlight:GetFont()
  if ff then cb.Text:SetFont(ff, Theme.FONT_SMALL, "") end
  cb:SetScript("OnClick", function(self)
    ns.db.privacy[self.privKey] = self:GetChecked() and true or false
    applyPrivacy()
  end)
  return cb
end

local function build(host)
  local f = CreateFrame("Frame", nil, host)
  f:SetSize(10, 10)

  f.intro = Widgets.SubText(f)
  f.intro:SetText(L["Choose what DuoReady shares with your partner. Unticked items stay on this client and are never broadcast."])

  f.allBtn = Widgets.Button(f, L["Share all"], 110, 24)
  f.allBtn:SetScript("OnClick", function() setAll(true) end)
  f.noneBtn = Widgets.Button(f, L["Share nothing"], 130, 24)
  f.noneBtn:SetScript("OnClick", function() setAll(false) end)

  f.groups = {}
  for gi, g in ipairs(GROUPS) do
    local grp = { header = Widgets.SectionHeader(f), checks = {} }
    for _, def in ipairs(g.keys) do
      grp.checks[#grp.checks + 1] = makeCheck(f, def[1], def[2])
    end
    f.groups[gi] = grp
  end
  return f
end

local function refresh(f, ctx)
  local W = ctx.width
  f:SetWidth(W)

  f.intro:ClearAllPoints()
  f.intro:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  f.intro:SetWidth(W)
  local introH = f.intro:GetStringHeight()

  f.allBtn:ClearAllPoints(); f.allBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(introH + 12))
  f.noneBtn:ClearAllPoints(); f.noneBtn:SetPoint("LEFT", f.allBtn, "RIGHT", 10, 0)

  -- Everything below the intro + action buttons starts here.
  local topH = introH + 12 + 24 + 22

  local cols = #f.groups
  local colW = math.max(180, (W - COL_GAP * (cols - 1)) / cols)

  local maxColH = topH
  for gi, grp in ipairs(f.groups) do
    local x = (gi - 1) * (colW + COL_GAP)
    local hd = grp.header
    hd.label:ClearAllPoints()
    hd.label:SetPoint("TOPLEFT", f, "TOPLEFT", x, -topH)
    Widgets.StyleHeader(hd, GROUPS[gi].title, colW)

    local y = topH + Theme.HEADER_H
    for _, cb in ipairs(grp.checks) do
      cb:ClearAllPoints()
      cb:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
      cb:SetChecked(ns.db.privacy[cb.privKey] ~= false)
      y = y + CHECK_H
    end
    if y > maxColH then maxColH = y end
  end

  f:SetHeight(maxColH + 10)
  return maxColH + 10
end

ns.Dashboard.RegisterPage({ key = "privacy", label = L["Privacy"], order = 9, separator = true, build = build, refresh = refresh })
