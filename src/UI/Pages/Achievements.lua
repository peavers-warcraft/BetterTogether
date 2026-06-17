--[[ UI/Pages/Achievements.lua
  "Achievements Together" page — the shared-memory view.

  Two layers:
    • Featured memories — a handful of special cards (where it began / an anniversary
      on today's date / a standout) drawn from across all loaded eras.
    • Browse by era — page back through expansion eras; each era lists the
      achievements you earned the SAME calendar day (highlighted "together"), plus
      the ones only one of you has.

  "Together" is a heuristic: GetAchievementInfo gives a date but no time, so we treat
  same-day matches as earned together — and the UI says "the same day", not more.

  Partner data is pulled lazily per era (AchvSync + the ACHV comm channel), so opening
  the page never blocks on a full achievement dump.
]]

local addonName, ns = ...
local S = ns.UI.Shared
local Theme = ns.UI.Theme
local Widgets = ns.UI.Widgets
local Row = ns.UI.Row
local DP = ns.UI.DetailPane
local L = ns.L

ns.Pages = ns.Pages or {}
local M = {}
ns.Pages.Achievements = M

local SEC_GAP = Theme.SECTION_GAP
local CARD_H = 64

-- Achievement detail renderer: draws a shared achievement into the detail pane
-- (ns.UI.DetailPane), reusing its chip/name/body widgets. `a` = { id, name, icon,
-- points, desc, together, status, youStr, partnerStr } — youStr/partnerStr are
-- preformatted "earned on" dates (or nil).
local shownAchv

local function renderAchvDetail()
  local a = shownAchv
  if not a then return end
  DP.StopSpinner()
  DP.text:SetJustifyH("LEFT")
  DP.hint:Hide()
  DP.chip.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
  DP.chip.icon:SetTexture(a.icon or 134400)
  DP.chip:Show()
  DP.name:SetText(a.name or (L["Achievement #"] .. (a.id or 0)))
  if a.together then DP.name:SetTextColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3])
  else DP.name:SetTextColor(Theme.CREAM[1], Theme.CREAM[2], Theme.CREAM[3]) end

  local parts = {}
  if a.together then
    parts[#parts + 1] = Theme.C.ready .. L["You both earned this the same day."] .. "|r"
  else
    local st = ({ youOnly = Theme.C.info .. L["Only you have earned this."] .. "|r",
                  partnerOnly = Theme.C.warn .. string.format(L["Only %s has earned this."], ns.Util.PartnerName(L["your partner"])) .. "|r" })[a.status]
    if st then parts[#parts + 1] = st end
  end
  if (a.points or 0) > 0 then parts[#parts + 1] = Theme.C.gold .. a.points .. L[" points"] .. "|r" end
  parts[#parts + 1] = " "
  if a.desc and a.desc ~= "" then
    parts[#parts + 1] = Theme.C.soft .. a.desc .. "|r"; parts[#parts + 1] = " "
  end
  parts[#parts + 1] = Theme.C.gold .. L["You"] .. "|r  " .. (a.youStr or (Theme.C.dim .. L["not earned"] .. "|r"))
  parts[#parts + 1] = Theme.C.gold .. ns.Util.PartnerName(L["Partner"]) .. "|r  " .. (a.partnerStr or (Theme.C.dim .. L["not earned"] .. "|r"))

  DP.qchip:Hide(); DP.qlabel:Hide()
  DP.text:ClearAllPoints()
  DP.text:SetPoint("TOPLEFT", DP.body, "TOPLEFT", 2, -60)
  DP.text:SetText(table.concat(parts, "\n"))
  DP.text:Show()
  DP.body:SetHeight(60 + (DP.text:GetStringHeight() or 0) + 14)
  if DP.scroll then DP.scroll:UpdateScrollChildRect() end
end

local function showAchvDetail(a)
  shownAchv = a
  DP.Render(renderAchvDetail)
end

-- Hover-preview + click-lock detail controller (shared with Quests/Inventory).
local detail = S.makePinController({
  show = function(_, a) showAchvDetail(a) end,
})

-- Which era is on screen; survives refreshes. requested[] guards against re-spamming
-- the partner with ACHVREQ for an era we've already asked for this viewing.
local viewEra
local requested = {}

local MONTHS = { L["Jan"], L["Feb"], L["Mar"], L["Apr"], L["May"], L["Jun"], L["Jul"], L["Aug"], L["Sep"], L["Oct"], L["Nov"], L["Dec"] }
local function fmtDate(e)
  if not e then return nil end
  return (e.d or 0) .. " " .. (MONTHS[e.m] or "?") .. " " .. (e.y or 0)
end
local function dateCode(e) return (e.y or 0) * 10000 + (e.m or 0) * 100 + (e.d or 0) end
local function sameDay(a, b) return a and b and a.y == b.y and a.m == b.m and a.d == b.d end

local function todayYMD()
  if not (C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime) then return nil end
  local t = C_DateAndTime.GetCurrentCalendarTime()
  if not t then return nil end
  return { y = t.year, m = t.month, d = t.monthDay }
end

-- Resolve display fields from an entry's id (id + date only) through the
-- achievement API on this client. Memoized: an achievement's name/points/desc/icon
-- never change once earned, and refresh() re-resolves every visible row on each 2s
-- tick + era switch — caching keeps those repaints from re-hitting the API in bulk.
local resolveCache = {}
local function resolve(entry)
  local id = entry.id
  local hit = resolveCache[id]
  if hit then return hit[1], hit[2], hit[3], hit[4] end
  local _, name, points, _, _, _, _, desc, _, icon = GetAchievementInfo(id)
  name, points, desc = name or (L["Achievement #"] .. id), points or 0, desc or ""
  resolveCache[id] = { name, points, desc, icon }
  return name, points, desc, icon
end

-- ---------------------------------------------------------------------------
-- Data access (own is always available; partner is lazily-synced)
-- ---------------------------------------------------------------------------
local function ownEra(eraKey)
  return (ns.AchvSync and ns.AchvSync.EraList(eraKey)) or {}
end

-- Returns the partner's era list, or nil if we don't have it yet (vs. {} = synced-empty).
local function partnerEra(eraKey)
  return ns.state.partner and ns.state.partner.achv and ns.state.partner.achv[eraKey] or nil
end

local function ensurePartnerEra(eraKey)
  if not eraKey or not ns.state.partner then return end
  ns.state.partner.achv = ns.state.partner.achv or {}
  if ns.state.partner.achv[eraKey] or requested[eraKey] then return end
  requested[eraKey] = true
  if ns.Comm and ns.Comm.RequestAchvEra then ns.Comm.RequestAchvEra(eraKey) end
end

-- Same-day / you-only / partner-only split for one era. "both" = own entries with a
-- same-day partner match; an id held by both on DIFFERENT days falls through to each
-- side's one-sided bucket (honest: it wasn't a shared moment).
local function eraSplit(eraKey)
  local own, partner = ownEra(eraKey), partnerEra(eraKey)
  local both, youOnly, partnerOnly = {}, {}, {}
  local pById, oById = {}, {}
  if partner then for _, a in ipairs(partner) do pById[a.id] = a end end
  for _, a in ipairs(own) do oById[a.id] = a end
  for _, a in ipairs(own) do
    local p = pById[a.id]
    if sameDay(a, p) then both[#both + 1] = a else youOnly[#youOnly + 1] = a end
  end
  if partner then
    for _, a in ipairs(partner) do
      if not sameDay(a, oById[a.id]) then partnerOnly[#partnerOnly + 1] = a end
    end
  end
  return both, youOnly, partnerOnly
end

-- All same-day matches across every era we currently hold partner data for. Featured
-- memories are chosen from this (it grows as more eras stream in).
local function allMatches()
  local out = {}
  for _, eraKey in ipairs(ns.AchvSync.EraOrder()) do
    local partner = partnerEra(eraKey)
    if partner then
      local pById = {}
      for _, a in ipairs(partner) do pById[a.id] = a end
      for _, a in ipairs(ownEra(eraKey)) do
        if sameDay(a, pById[a.id]) then
          local name, points, desc, icon = resolve(a)
          out[#out + 1] = { id = a.id, y = a.y, m = a.m, d = a.d, code = dateCode(a),
            name = name, points = points, desc = desc, icon = icon }
        end
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Featured memory selection — the taste layer: which shared moments are special
-- enough to surface as cards. Returns up to 3 { m = match, tag = "label" }.
-- ---------------------------------------------------------------------------
local function selectFeaturedMemories(matches)
  if #matches == 0 then return {} end
  local picks, used = {}, {}
  local function add(m, tag)
    if not m or used[m.id] or #picks >= 3 then return end
    used[m.id] = true
    picks[#picks + 1] = { m = m, tag = tag }
  end

  -- 1) Anniversary — earned this same month/day in an earlier year ("X years ago today").
  local today = todayYMD()
  if today then
    local best
    for _, m in ipairs(matches) do
      if m.m == today.m and m.d == today.d and m.y < today.y and (not best or m.y < best.y) then best = m end
    end
    if best then
      local n = today.y - best.y
      add(best, n .. (n == 1 and L[" year ago today"] or L[" years ago today"]))
    end
  end

  -- 2) Where it began — the oldest shared memory.
  local oldest
  for _, m in ipairs(matches) do if not oldest or m.code < oldest.code then oldest = m end end
  add(oldest, L["Where it began"])

  -- 3) One to remember — the highest-point shared achievement.
  local biggest
  for _, m in ipairs(matches) do
    if (m.points or 0) > 0 and (not biggest or m.points > biggest.points) then biggest = m end
  end
  add(biggest, L["One to remember"])

  -- Pad toward 3 with the most recent matches so the section stays full.
  if #picks < 3 then
    local recent = {}
    for _, m in ipairs(matches) do recent[#recent + 1] = m end
    table.sort(recent, function(a, b) return a.code > b.code end)
    for _, m in ipairs(recent) do add(m, L["Together, not long ago"]) end
  end
  return picks
end

-- Detail-pane object for a same-day match (used by featured cards).
local function matchDetail(m)
  return { id = m.id, name = m.name, points = m.points, desc = m.desc, icon = m.icon,
    together = true, status = "both", youStr = fmtDate(m), partnerStr = fmtDate(m) }
end

-- Detail-pane object for an era row: fills in each side's actual earned date by id.
local function rowDetail(a, status)
  local name, points, desc, icon = resolve(a)
  local ownE, partE
  for _, x in ipairs(ownEra(viewEra)) do if x.id == a.id then ownE = x break end end
  for _, x in ipairs(partnerEra(viewEra) or {}) do if x.id == a.id then partE = x break end end
  return { id = a.id, name = name, points = points, desc = desc, icon = icon,
    together = sameDay(ownE, partE), status = status,
    youStr = ownE and fmtDate(ownE) or nil, partnerStr = partE and fmtDate(partE) or nil }
end

-- ---------------------------------------------------------------------------
-- Era navigation
-- ---------------------------------------------------------------------------
local function defaultEra()
  local order = ns.AchvSync.EraOrder()        -- newest-first
  for _, k in ipairs(order) do if #ownEra(k) > 0 then return k end end
  return order[1]
end

local function eraIndex(key)
  for i, k in ipairs(ns.AchvSync.EraOrder()) do if k == key then return i end end
  return 1
end

-- timeDir: -1 = older (back in the album), +1 = newer. Newer = lower index.
local function stepEra(timeDir)
  local order = ns.AchvSync.EraOrder()
  local newIdx = eraIndex(viewEra) - timeDir
  if newIdx < 1 or newIdx > #order then return end
  viewEra = order[newIdx]
  detail.unlock()
  if ns.Dashboard then ns.Dashboard.Refresh() end
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
-- Themed nav button: dark fill + gold rim + gold glyph (replaces the stock red
-- UIPanelButtonTemplate, which clashes with the panel's dark/gold look). Brightens on
-- hover; dims when disabled. Call b:SetEnabledLook(bool) instead of SetEnabled.
local function makeNavButton(parent, label)
  local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
  b:SetSize(26, 24)
  b:SetBackdrop(Theme.BACKDROP_HAIRLINE)
  b:SetBackdropColor(0.13, 0.12, 0.10, 0.95)
  b:SetBackdropBorderColor(Theme.GOLD[1] * 0.7, Theme.GOLD[2] * 0.7, Theme.GOLD[3] * 0.7, 0.85)
  local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetPoint("CENTER", 0, 0); fs:SetText(label); fs:SetTextColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3])
  b.fs = fs
  b:SetScript("OnEnter", function(self)
    if not self:IsEnabled() then return end
    self:SetBackdropBorderColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 1)
    fs:SetTextColor(Theme.CREAM[1], Theme.CREAM[2], Theme.CREAM[3])
  end)
  b:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(Theme.GOLD[1] * 0.7, Theme.GOLD[2] * 0.7, Theme.GOLD[3] * 0.7, 0.85)
    fs:SetTextColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3])
  end)
  function b:SetEnabledLook(on)
    self:SetEnabled(on)
    local k = on and 0.7 or 0.35
    self:SetBackdropBorderColor(Theme.GOLD[1] * k, Theme.GOLD[2] * k, Theme.GOLD[3] * k, on and 0.85 or 0.5)
    fs:SetTextColor(on and Theme.GOLD[1] or 0.4, on and Theme.GOLD[2] or 0.4, on and Theme.GOLD[3] or 0.4)
  end
  return b
end

-- A featured "memory" card: chip on the left, a small gold tag above the achievement
-- name, with the date right-aligned on the name's line (so everything reads as one
-- centered block rather than scattered corners).
local function makeCard(parent)
  local c = CreateFrame("Button", nil, parent, "BackdropTemplate")
  c:SetHeight(CARD_H)
  c:SetBackdrop(Theme.BACKDROP_HAIRLINE)
  c:SetBackdropColor(0.12, 0.10, 0.07, 0.9)
  c:SetBackdropBorderColor(Theme.GOLD[1] * 0.6, Theme.GOLD[2] * 0.6, Theme.GOLD[3] * 0.6, 0.7)
  local hl = c:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(c); hl:SetColorTexture(1, 1, 1, 0.05); hl:Hide()
  c:HookScript("OnEnter", function() hl:Show() end)
  c:HookScript("OnLeave", function() hl:Hide() end)
  c.chip = Row.MakeChip(c, 44, Theme.I_BOSS); c.chip:SetPoint("LEFT", c, "LEFT", 12, 0)

  -- name + date sit on one centered line; tag floats just above the name.
  c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  c.name:SetPoint("LEFT", c.chip, "RIGHT", 14, -3); c.name:SetJustifyH("LEFT"); c.name:SetWordWrap(false)
  c.name:SetTextColor(Theme.CREAM[1], Theme.CREAM[2], Theme.CREAM[3])
  c.tag = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  c.tag:SetPoint("BOTTOMLEFT", c.name, "TOPLEFT", 0, 5); c.tag:SetTextColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3])
  c.date = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  c.date:SetPoint("RIGHT", c, "RIGHT", -14, -3); c.date:SetTextColor(0.72, 0.72, 0.74)
  return c
end

local function build(host)
  local f = CreateFrame("Frame", nil, host); f:SetSize(10, 10)
  f.cards = {}
  f.featHeader = Widgets.SectionHeader(f)
  f.browseHeader = Widgets.SectionHeader(f)
  f.subHeaders = {}
  f.rows = {}
  f.note  = Widgets.SubText(f)   -- featured-area message (shared subheader font)
  f.note2 = Widgets.SubText(f)   -- era-body message
  -- Centered full-page loading/empty state: gold spinner over a centered message
  -- (shared with the Quests/Inventory data pages so every wait reads the same).
  S.attachFullPageState(f)
  -- Inline loader for the era body while a freshly-selected expansion's partner data
  -- streams in — keeps the featured cards + era nav on screen so you can keep paging.
  f.eraSpinner = Widgets.Spinner(f, 34)
  f.prev = makeNavButton(f, "<")
  f.next = makeNavButton(f, ">")
  f.eraLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.eraLabel:SetTextColor(Theme.CREAM[1], Theme.CREAM[2], Theme.CREAM[3])
  f.prev:SetScript("OnClick", function() stepEra(-1) end)
  f.next:SetScript("OnClick", function() stepEra(1) end)
  return f
end

local function ensureCard(f, i)
  if not f.cards[i] then f.cards[i] = makeCard(f) end
  return f.cards[i]
end
local function ensureSubHeader(f, i)
  if not f.subHeaders[i] then f.subHeaders[i] = Widgets.SectionHeader(f) end
  return f.subHeaders[i]
end
local function ensureRow(f, i)
  if not f.rows[i] then f.rows[i] = Row.CreateInfo(f, Theme.I_BOSS) end
  return f.rows[i]
end

-- A single clean, centered full-page state: a message (pairing prompt, partner-off
-- note, or loading text) centered horizontally and vertically in the visible panel,
-- with an optional gold loading spinner above it. Hides every other widget so the
-- page reads as one calm state rather than a half-built layout.
local function fullPageNote(f, colW, text, spinner)
  Widgets.HideHeader(f.featHeader); Widgets.HideHeader(f.browseHeader)
  f.note:Hide(); f.note2:Hide()
  f.prev:Hide(); f.next:Hide(); f.eraLabel:Hide()
  for i = 1, #f.cards do f.cards[i]:Hide() end
  for i = 1, #f.subHeaders do Widgets.HideHeader(f.subHeaders[i]) end
  for i = 1, #f.rows do f.rows[i]:SetShown(false) end
  if f.eraSpinner then f.eraSpinner:Stop() end
  return S.showFullPageState(f, colW, text, spinner)
end

-- Partner has turned off achievement sharing: their list will never arrive, so hand
-- the page to the shared full-width empty state rather than holding a note forever.
local function emptyState()
  if not ns.PartnerShares("achievements") then
    return { title = L["Achievement sharing is off"],
      sub = string.format(L["%s has turned off sharing their achievements."], ns.Util.PartnerName(L["Your partner"])) }
  end
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
local function refresh(f, ctx)
  local W = ctx.width; f:SetWidth(W)
  -- Fill the whole viewport (this page always runs beside the detail sidebar, which
  -- already constrains the width) so content meets the divider with no dead gap.
  local colW = W

  -- The "Browse by era" section header was removed by design; the era nav is
  -- centered beneath the list instead. f.browseHeader stays hidden.
  Widgets.HideHeader(f.browseHeader)

  -- No-partner / partner-offline AND the partner-opted-out state are handled by the
  -- shell's shared full-width empty state (ns.UI.EmptyState) before this page renders —
  -- opt-out via the descriptor's emptyState hook, no-partner centrally. So refresh only
  -- ever runs with a sharing partner.

  -- Our own achievements are scanned across frames (the full DB is large), so the
  -- page opens instantly. Show a note while the first scan runs, then repaint — this
  -- is what keeps clicking the Achievements tab from freezing the client.
  if not ns.AchvSync.Ready() then
    ns.AchvSync.Ensure(function() if ns.Dashboard then ns.Dashboard.Refresh() end end)
    return fullPageNote(f, colW,
      "|cffd0d0d0" .. L["Gathering your achievements…"] .. "|r\n|cff808080" .. L["This only takes a moment the first time you open it."] .. "|r", true)
  end

  viewEra = viewEra or defaultEra()

  -- Pull what we need: the era on screen, plus the oldest era the partner reports
  -- (so "Where it began" can resolve without loading everything).
  ensurePartnerEra(viewEra)
  -- Defer the oldest-era pull (only needed for the "Where it began" card) until the
  -- on-screen era has arrived, so the first load fetches ONE era, not two, over the
  -- throttled comm queue.
  local dig = ns.state.partner and ns.state.partner.achvDigest
  if dig and partnerEra(viewEra) ~= nil then
    local oldest
    for k, info in pairs(dig) do if (info.count or 0) > 0 and (not oldest or k < oldest) then oldest = k end end
    if oldest then ensurePartnerEra(oldest) end
  end

  local yOff, ci, hi, ri = 0, 0, 0, 0

  -- Initial load: hold a single full-page message until the first era's data lands,
  -- rather than flashing a half-populated page as chunks stream in. Once any era has
  -- arrived (even an empty one), we fall through to the real layout; later era
  -- navigation uses the inline "Syncing…" note instead of blanking the page.
  if not next(ns.state.partner.achv or {}) then
    return fullPageNote(f, colW,
      "|cffd0d0d0" .. L["Gathering the achievements you've earned together…"] .. "|r\n|cff808080" .. L["This can take a few seconds the first time you open it."] .. "|r", true)
  end

  -- Real content is about to render: tear down the centered loading state.
  S.clearFullPageState(f)

  -- MEMORIES TOGETHER (top) --------------------------------------------------
  f.featHeader.label:ClearAllPoints(); f.featHeader.label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  Widgets.StyleHeader(f.featHeader, L["Memories together"], colW)
  yOff = yOff + Theme.HEADER_H

  local feats = selectFeaturedMemories(allMatches())
  if #feats > 0 then
    f.note:Hide()
    yOff = yOff + 8
    for _, fm in ipairs(feats) do
      ci = ci + 1
      local c = ensureCard(f, ci)
      local m = fm.m
      c:Show(); c:SetWidth(colW)
      -- Anchor flush at x=0: the card's gold backdrop border draws inside its bounds,
      -- so a negative offset pushes the left border column outside the scroll frame's
      -- clip region and shaves it off ("off screen on the left").
      c:ClearAllPoints(); c:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -yOff)
      c.chip.icon:SetTexture(m.icon or Theme.I_BOSS); c.chip.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
      c.tag:SetText(fm.tag)
      c.name:SetText(m.name); c.name:SetWidth(colW - 170)
      c.date:SetText(fmtDate(m))
      local a = matchDetail(m)
      c:SetScript("OnEnter", function() detail.preview(a.id, a) end)
      c:SetScript("OnLeave", function() detail.leave() end)
      c:SetScript("OnClick", function() detail.lock(a.id, a) end)
      yOff = yOff + CARD_H + 8
    end
  else
    f.note:Show(); f.note:ClearAllPoints(); f.note:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -(yOff + 10))
    f.note:SetWidth(colW - 6)
    local loading = not (ns.state.partner and ns.state.partner.achv)
    f.note:SetText(loading
      and "|cff808080" .. L["Looking back through your shared history…"] .. "|r"
      or "|cff808080" .. L["No achievements earned on the same day yet — go make some memories together!"] .. "|r")
    yOff = yOff + 10 + f.note:GetStringHeight() + 8
  end
  for i = ci + 1, #f.cards do f.cards[i]:Hide() end

  -- ERA LIST (no header) — just "Earned together" (capped to 10 most recent). The
  -- one-sided buckets ("You earned" / "Partner earned") are intentionally omitted:
  -- this page is about the moments the two of you share. Era nav is centered below.
  yOff = yOff + SEC_GAP
  local both = eraSplit(viewEra)

  local TOGETHER_CAP = 10
  local function section(title, list, kind, cap)
    if #list == 0 then return end
    hi = hi + 1
    local hd = ensureSubHeader(f, hi)
    hd.label:ClearAllPoints(); hd.label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -yOff)
    Widgets.StyleHeader(hd, title, colW)
    yOff = yOff + Theme.HEADER_H + 8
    table.sort(list, function(a, b) return dateCode(a) > dateCode(b) end)
    local status = (kind == "both" and "both") or "partnerOnly"
    local n = cap and math.min(#list, cap) or #list
    for j = 1, n do
      local a = list[j]
      ri = ri + 1
      local r = ensureRow(f, ri)
      local name, _, _, icon = resolve(a)
      r:SetShown(true); r:SetWidth(colW); r:SetIcon(icon or Theme.I_BOSS)
      local value = (kind == "both") and ("|cff44ff44" .. fmtDate(a) .. "|r") or ("|cffa0a0a0" .. fmtDate(a) .. "|r")
      r:Set(name, value)
      local ad = rowDetail(a, status)
      r:SetSelected(detail.isLocked(a.id))
      r:SetHover(function() detail.preview(a.id, ad) end, function() detail.leave() end)
      r:SetClick(function() detail.lock(a.id, ad) end)
      r.frame:ClearAllPoints(); r.frame:SetPoint("TOPLEFT", f, "TOPLEFT", -3, -yOff)
      yOff = yOff + Row.HEIGHT + 3
    end
    yOff = yOff + SEC_GAP - 3
  end

  if partnerEra(viewEra) == nil then
    -- Switching to an expansion we haven't pulled the partner's data for yet: show the
    -- same gold loader, centered in the era body, above a "Syncing…" line. The era nav
    -- below stays put, so paging on through the album never blocks.
    local sp = f.eraSpinner
    sp:ClearAllPoints(); sp:SetPoint("TOP", f, "TOPLEFT", colW / 2, -yOff); sp:Start()
    f.note2:Show(); f.note2:ClearAllPoints()
    f.note2:SetPoint("TOP", sp, "BOTTOM", 0, -12)
    f.note2:SetWidth(colW); f.note2:SetJustifyH("CENTER")
    f.note2:SetText("|cff808080" .. L["Syncing "] .. ns.AchvSync.EraName(viewEra) .. L[" achievements…"] .. "|r")
    yOff = yOff + 34 + 12 + f.note2:GetStringHeight() + (SEC_GAP - 6)
  else
    f.eraSpinner:Stop()
    local togCount = #both > TOGETHER_CAP and (TOGETHER_CAP .. L[" of "] .. #both) or tostring(#both)
    section(L["Earned together"] .. "  |cff707070(" .. togCount .. ")|r", both, "both", TOGETHER_CAP)
    if #both == 0 then
      f.note2:Show(); f.note2:ClearAllPoints(); f.note2:SetJustifyH("LEFT")
      f.note2:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -yOff)
      f.note2:SetWidth(colW - 6)
      f.note2:SetText("|cff808080" .. L["No shared achievements in this era yet."] .. "|r")
      yOff = yOff + 10 + f.note2:GetStringHeight() + (SEC_GAP - 10)
    else
      f.note2:Hide()
    end
  end

  -- ERA NAV — centered beneath the list: < EraName (N together) >
  local order = ns.AchvSync.EraOrder()
  local idx = eraIndex(viewEra)
  f.prev:Show(); f.next:Show(); f.eraLabel:Show()
  f.prev:SetEnabledLook(idx < #order)   -- older exists
  f.next:SetEnabledLook(idx > 1)        -- newer exists
  f.eraLabel:SetText(ns.AchvSync.EraName(viewEra) .. "   |cff707070(" .. #both .. L[" together)"] .. "|r")
  local lw = f.eraLabel:GetStringWidth() or 120
  local total = 26 + 10 + lw + 10 + 26
  local startX = math.max(0, math.floor((colW - total) / 2))
  f.prev:ClearAllPoints(); f.prev:SetPoint("TOPLEFT", f, "TOPLEFT", startX, -yOff)
  f.eraLabel:ClearAllPoints(); f.eraLabel:SetPoint("LEFT", f.prev, "RIGHT", 10, 0)
  f.next:ClearAllPoints(); f.next:SetPoint("LEFT", f.eraLabel, "RIGHT", 10, 0)
  yOff = yOff + 26 + 8

  for i = hi + 1, #f.subHeaders do Widgets.HideHeader(f.subHeaders[i]) end
  for i = ri + 1, #f.rows do f.rows[i]:SetShown(false) end

  local h = yOff + 14
  f:SetHeight(h); return h
end

ns.Dashboard.RegisterPage({
  key = "achievements", label = L["Achievements"], order = 3, detail = true,
  detailTitle = L["Achievement"], detailHint = L["Hover or click an achievement to see it here."],
  build = build, refresh = refresh, emptyState = emptyState,
  onShow = function()
    detail.unlock()
    viewEra = nil           -- reopen lands on the newest era you have
    requested = {}
    if ns.Comm and ns.Comm.RequestAchvDigest then ns.Comm.RequestAchvDigest() end
  end,
})
