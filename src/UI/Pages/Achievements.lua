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
local Row = ns.UI.Row

local SEC_GAP = 24
local CARD_H = 64

-- Hover-preview + click-lock detail controller (shared with Quests/Inventory).
local detail = S.makePinController({
  show = function(_, a)
    if ns.Dashboard and ns.Dashboard.ShowAchievementDetail then ns.Dashboard.ShowAchievementDetail(a) end
  end,
})

-- Which era is on screen; survives refreshes. requested[] guards against re-spamming
-- the partner with ACHVREQ for an era we've already asked for this viewing.
local viewEra
local requested = {}

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
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

-- Resolve display fields. Demo entries carry their own; real entries (id + date only)
-- resolve through the achievement API on this client.
local function resolve(entry)
  if entry.name then return entry.name, entry.points or 0, entry.desc or "", entry.icon end
  local _, name, points, _, _, _, _, desc, _, icon = GetAchievementInfo(entry.id)
  return name or ("Achievement #" .. entry.id), points or 0, desc or "", icon
end

-- ---------------------------------------------------------------------------
-- Data access (own is always available; partner is demo or lazily-synced)
-- ---------------------------------------------------------------------------
local demoOwnCache, demoPartnerCache
local function bucketByEra(list)
  local by = {}
  for _, a in ipairs(list) do
    local k = ns.AchvSync.EraOf(a.y, a.m)
    by[k] = by[k] or {}; by[k][#by[k] + 1] = a
  end
  return by
end

local function ownEra(eraKey)
  if ns.db.demoMode then
    demoOwnCache = demoOwnCache or bucketByEra(S.demoAchvOwn())
    return demoOwnCache[eraKey] or {}
  end
  return (ns.AchvSync and ns.AchvSync.EraList(eraKey)) or {}
end

-- Returns the partner's era list, or nil if we don't have it yet (vs. {} = synced-empty).
local function partnerEra(eraKey)
  if ns.db.demoMode then
    demoPartnerCache = demoPartnerCache or bucketByEra(S.demoAchvPartner())
    return demoPartnerCache[eraKey] or {}
  end
  return ns.state.partner and ns.state.partner.achv and ns.state.partner.achv[eraKey] or nil
end

local function partnerLinked() return ns.db.demoMode or (ns.state.partner ~= nil) end

local function ensurePartnerEra(eraKey)
  if ns.db.demoMode or not eraKey or not ns.state.partner then return end
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
      add(best, n .. (n == 1 and " year ago today" or " years ago today"))
    end
  end

  -- 2) Where it began — the oldest shared memory.
  local oldest
  for _, m in ipairs(matches) do if not oldest or m.code < oldest.code then oldest = m end end
  add(oldest, "Where it began")

  -- 3) One to remember — the highest-point shared achievement.
  local biggest
  for _, m in ipairs(matches) do
    if (m.points or 0) > 0 and (not biggest or m.points > biggest.points) then biggest = m end
  end
  add(biggest, "One to remember")

  -- Pad toward 3 with the most recent matches so the section stays full.
  if #picks < 3 then
    local recent = {}
    for _, m in ipairs(matches) do recent[#recent + 1] = m end
    table.sort(recent, function(a, b) return a.code > b.code end)
    for _, m in ipairs(recent) do add(m, "Together, not long ago") end
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
  b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
  b:SetBackdropColor(0.13, 0.12, 0.10, 0.95)
  b:SetBackdropBorderColor(S.GOLD[1] * 0.7, S.GOLD[2] * 0.7, S.GOLD[3] * 0.7, 0.85)
  local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetPoint("CENTER", 0, 0); fs:SetText(label); fs:SetTextColor(S.GOLD[1], S.GOLD[2], S.GOLD[3])
  b.fs = fs
  b:SetScript("OnEnter", function(self)
    if not self:IsEnabled() then return end
    self:SetBackdropBorderColor(S.GOLD[1], S.GOLD[2], S.GOLD[3], 1)
    fs:SetTextColor(S.CREAM[1], S.CREAM[2], S.CREAM[3])
  end)
  b:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(S.GOLD[1] * 0.7, S.GOLD[2] * 0.7, S.GOLD[3] * 0.7, 0.85)
    fs:SetTextColor(S.GOLD[1], S.GOLD[2], S.GOLD[3])
  end)
  function b:SetEnabledLook(on)
    self:SetEnabled(on)
    local k = on and 0.7 or 0.35
    self:SetBackdropBorderColor(S.GOLD[1] * k, S.GOLD[2] * k, S.GOLD[3] * k, on and 0.85 or 0.5)
    fs:SetTextColor(on and S.GOLD[1] or 0.4, on and S.GOLD[2] or 0.4, on and S.GOLD[3] or 0.4)
  end
  return b
end

-- A featured "memory" card: chip on the left, a small gold tag above the achievement
-- name, with the date right-aligned on the name's line (so everything reads as one
-- centered block rather than scattered corners).
local function makeCard(parent)
  local c = CreateFrame("Button", nil, parent, "BackdropTemplate")
  c:SetHeight(CARD_H)
  c:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
  c:SetBackdropColor(0.12, 0.10, 0.07, 0.9)
  c:SetBackdropBorderColor(S.GOLD[1] * 0.6, S.GOLD[2] * 0.6, S.GOLD[3] * 0.6, 0.7)
  local hl = c:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(c); hl:SetColorTexture(1, 1, 1, 0.05); hl:Hide()
  c:HookScript("OnEnter", function() hl:Show() end)
  c:HookScript("OnLeave", function() hl:Hide() end)
  c.chip = Row.MakeChip(c, 44, S.I_BOSS); c.chip:SetPoint("LEFT", c, "LEFT", 12, 0)

  -- name + date sit on one centered line; tag floats just above the name.
  c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  c.name:SetPoint("LEFT", c.chip, "RIGHT", 14, -3); c.name:SetJustifyH("LEFT"); c.name:SetWordWrap(false)
  c.name:SetTextColor(S.CREAM[1], S.CREAM[2], S.CREAM[3])
  c.tag = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  c.tag:SetPoint("BOTTOMLEFT", c.name, "TOPLEFT", 0, 5); c.tag:SetTextColor(S.GOLD[1], S.GOLD[2], S.GOLD[3])
  c.date = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  c.date:SetPoint("RIGHT", c, "RIGHT", -14, -3); c.date:SetTextColor(0.72, 0.72, 0.74)
  return c
end

local function build(host)
  local f = CreateFrame("Frame", nil, host); f:SetSize(10, 10)
  f.cards = {}
  f.featHeader = S.makeSectionHeader(f)
  f.browseHeader = S.makeSectionHeader(f)
  f.subHeaders = {}
  f.rows = {}
  f.note  = S.makeSubText(f)   -- featured-area message (shared subheader font)
  f.note2 = S.makeSubText(f)   -- era-body message
  f.prev = makeNavButton(f, "<")
  f.next = makeNavButton(f, ">")
  f.eraLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.eraLabel:SetTextColor(S.CREAM[1], S.CREAM[2], S.CREAM[3])
  f.prev:SetScript("OnClick", function() stepEra(-1) end)
  f.next:SetScript("OnClick", function() stepEra(1) end)
  return f
end

local function ensureCard(f, i)
  if not f.cards[i] then f.cards[i] = makeCard(f) end
  return f.cards[i]
end
local function ensureSubHeader(f, i)
  if not f.subHeaders[i] then f.subHeaders[i] = S.makeSectionHeader(f) end
  return f.subHeaders[i]
end
local function ensureRow(f, i)
  if not f.rows[i] then f.rows[i] = Row.CreateInfo(f, S.I_BOSS) end
  return f.rows[i]
end

-- A single full-page message under the "Memories together" header (pairing prompt
-- or a loading note). Hides every other widget so the page reads as one clean state.
local function fullPageNote(f, colW, text, topPad)
  f.featHeader.label:ClearAllPoints(); f.featHeader.label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  S.styleHeader(f.featHeader, "Memories together", colW)
  local yOff = S.HEADER_H
  f.note:Show(); f.note:ClearAllPoints(); f.note:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -(yOff + topPad))
  f.note:SetWidth(colW - 6); f.note:SetText(text)
  f.note2:Hide()
  f.prev:Hide(); f.next:Hide(); f.eraLabel:Hide()
  for i = 1, #f.cards do f.cards[i]:Hide() end
  for i = 1, #f.subHeaders do S.hideHeader(f.subHeaders[i]) end
  for i = 1, #f.rows do f.rows[i]:SetShown(false) end
  local h = yOff + topPad + f.note:GetStringHeight() + 14
  f:SetHeight(h); return h
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
local function refresh(f, ctx)
  local W = ctx.width; f:SetWidth(W)
  local colW = math.min(W, 600)

  -- The "Browse by era" section header was removed by design; the era nav is
  -- centered beneath the list instead. f.browseHeader stays hidden.
  S.hideHeader(f.browseHeader)

  -- Not linked: a single prompt — nothing to browse or feature yet.
  if not partnerLinked() then
    return fullPageNote(f, colW,
      "|cff808080Pair with your partner to start collecting the achievements you've earned together.|r", 10)
  end

  -- Our own achievements are scanned across frames (the full DB is large), so the
  -- page opens instantly. Show a note while the first scan runs, then repaint — this
  -- is what keeps clicking "Together" from freezing the client. Skipped in demo mode,
  -- which serves canned data.
  if not ns.db.demoMode and not ns.AchvSync.Ready() then
    ns.AchvSync.Ensure(function() if ns.Dashboard then ns.Dashboard.Refresh() end end)
    return fullPageNote(f, colW,
      "|cffd0d0d0Gathering your achievements…|r\n|cff808080This only takes a moment the first time you open it.|r", 18)
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
  if not ns.db.demoMode and not next(ns.state.partner.achv or {}) then
    return fullPageNote(f, colW,
      "|cffd0d0d0Gathering the achievements you've earned together…|r\n|cff808080This can take a few seconds the first time you open it.|r", 18)
  end

  -- MEMORIES TOGETHER (top) --------------------------------------------------
  f.featHeader.label:ClearAllPoints(); f.featHeader.label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  S.styleHeader(f.featHeader, "Memories together", colW)
  yOff = yOff + S.HEADER_H

  local feats = selectFeaturedMemories(allMatches())
  if #feats > 0 then
    f.note:Hide()
    yOff = yOff + 8
    for _, fm in ipairs(feats) do
      ci = ci + 1
      local c = ensureCard(f, ci)
      local m = fm.m
      c:Show(); c:SetWidth(colW)
      c:ClearAllPoints(); c:SetPoint("TOPLEFT", f, "TOPLEFT", -1, -yOff)
      c.chip.icon:SetTexture(m.icon or S.I_BOSS); c.chip.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
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
    local loading = not ns.db.demoMode and not (ns.state.partner and ns.state.partner.achv)
    f.note:SetText(loading
      and "|cff808080Looking back through your shared history…|r"
      or "|cff808080No achievements earned on the same day yet — go make some memories together!|r")
    yOff = yOff + 10 + f.note:GetStringHeight() + 8
  end
  for i = ci + 1, #f.cards do f.cards[i]:Hide() end

  -- ERA LIST (no header) — "Earned together" (capped to 10 most recent) +
  -- "Partner earned"; the solo "You earned" bucket is intentionally omitted, since
  -- this page is about the two of you. Era nav is rendered centered below the list.
  yOff = yOff + SEC_GAP
  local both, _, partnerOnly = eraSplit(viewEra)

  local TOGETHER_CAP = 10
  local function section(title, list, kind, cap)
    if #list == 0 then return end
    hi = hi + 1
    local hd = ensureSubHeader(f, hi)
    hd.label:ClearAllPoints(); hd.label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -yOff)
    S.styleHeader(hd, title, colW)
    yOff = yOff + S.HEADER_H + 8
    table.sort(list, function(a, b) return dateCode(a) > dateCode(b) end)
    local status = (kind == "both" and "both") or "partnerOnly"
    local n = cap and math.min(#list, cap) or #list
    for j = 1, n do
      local a = list[j]
      ri = ri + 1
      local r = ensureRow(f, ri)
      local name, _, _, icon = resolve(a)
      r:SetShown(true); r:SetWidth(colW); r:SetIcon(icon or S.I_BOSS)
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

  if not ns.db.demoMode and partnerEra(viewEra) == nil then
    f.note2:Show(); f.note2:ClearAllPoints(); f.note2:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -yOff)
    f.note2:SetWidth(colW - 6)
    f.note2:SetText("|cff808080Syncing " .. ns.AchvSync.EraName(viewEra) .. " achievements…|r")
    yOff = yOff + 10 + f.note2:GetStringHeight() + (SEC_GAP - 10)
  else
    local togCount = #both > TOGETHER_CAP and (TOGETHER_CAP .. " of " .. #both) or tostring(#both)
    section("Earned together  |cff707070(" .. togCount .. ")|r", both, "both", TOGETHER_CAP)
    section("Partner earned  |cff707070(" .. #partnerOnly .. ")|r", partnerOnly, "partner")
    if #both == 0 and #partnerOnly == 0 then
      f.note2:Show(); f.note2:ClearAllPoints(); f.note2:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -yOff)
      f.note2:SetWidth(colW - 6)
      f.note2:SetText("|cff808080No shared achievements in this era yet.|r")
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
  f.eraLabel:SetText(ns.AchvSync.EraName(viewEra) .. "   |cff707070(" .. #both .. " together)|r")
  local lw = f.eraLabel:GetStringWidth() or 120
  local total = 26 + 10 + lw + 10 + 26
  local startX = math.max(0, math.floor((colW - total) / 2))
  f.prev:ClearAllPoints(); f.prev:SetPoint("TOPLEFT", f, "TOPLEFT", startX, -yOff)
  f.eraLabel:ClearAllPoints(); f.eraLabel:SetPoint("LEFT", f.prev, "RIGHT", 10, 0)
  f.next:ClearAllPoints(); f.next:SetPoint("LEFT", f.eraLabel, "RIGHT", 10, 0)
  yOff = yOff + 26 + 8

  for i = hi + 1, #f.subHeaders do S.hideHeader(f.subHeaders[i]) end
  for i = ri + 1, #f.rows do f.rows[i]:SetShown(false) end

  local h = yOff + 14
  f:SetHeight(h); return h
end

ns.Dashboard.RegisterPage({
  key = "achievements", label = "Together", order = 3, detail = true,
  detailTitle = "Achievement", detailHint = "Hover or click an achievement to see it here.",
  build = build, refresh = refresh,
  onShow = function()
    detail.unlock()
    viewEra = nil           -- reopen lands on the newest era you have
    requested = {}
    if not ns.db.demoMode and ns.Comm and ns.Comm.RequestAchvDigest then ns.Comm.RequestAchvDigest() end
  end,
})
