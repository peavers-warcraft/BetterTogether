--[[ UI/Pages/Shared.lua
  Page composition + data formatting shared by the tab shell and all pages
  (ns.UI.Shared). Look/feel constants live in ns.UI.Theme; reusable frames in
  ns.UI.Widgets — this file is the layer above them: formatters, readiness-row
  population, content builders, the generic info/row page templates, the detail-pane
  pin controller.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local S = {}
ns.UI.Shared = S

local Theme = ns.UI.Theme
local Widgets = ns.UI.Widgets
local L = ns.L

-- ---------------------------------------------------------------------------
-- Formatters
-- ---------------------------------------------------------------------------
--- Class colour as r,g,b (falls back to a neutral grey for unknown classes).
--- @param cls string|nil Class token (e.g. "PALADIN").
--- @return number r
--- @return number g
--- @return number b
function S.classColor(cls)
  if C_ClassColor and C_ClassColor.GetClassColor and cls and cls ~= "" then
    local c = C_ClassColor.GetClassColor(cls); if c then return c.r, c.g, c.b end
  end
  local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
  if c then return c.r, c.g, c.b end
  return 0.8, 0.8, 0.82
end

--- Colour-escape prefix (|cffRRGGBB) for an r,g,b triple.
--- @return string escape
function S.hex(r, g, b) return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255) end

--- Localized class display name for a class token.
--- @param cls string|nil
--- @return string
function S.classDisplayName(cls)
  if cls and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls] then return LOCALIZED_CLASS_NAMES_MALE[cls] end
  return cls or ""
end

--- Spec name + role for a specialization id.
--- @param specID number|nil
--- @return string name
--- @return string|nil role
function S.specInfo(specID)
  if not specID or specID == 0 then return "", nil end
  local _, name, _, _, role = GetSpecializationInfoByID(specID)
  return name or "", role
end

--- Tiny role-icon atlas for TANK/HEALER/DAMAGER (nil if unavailable).
--- @param role string|nil
--- @return string|nil atlas
function S.roleAtlas(role)
  local a = role and ({ TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" })[role]
  if a and Theme.AtlasExists(a) then return a end
  return nil
end

--- Which unit token is our partner (for the live 3D model)?
--- @return string|nil unit "player"/"partyN"/"raidN" or nil.
function S.partnerUnit()
  if ns.Comm and ns.Comm.selftest then return "player" end
  local name = ns.state.partnerName
  if not name then return nil end
  -- Scan the right token namespace: party1..4 don't exist inside a raid group, so a
  -- raid partner would otherwise never resolve and the model would fall back to the
  -- class icon. IsInRaid() picks raid1..40 there, plain party tokens otherwise.
  local prefix, count = "party", 4
  if IsInRaid() then prefix, count = "raid", 40 end
  for i = 1, count do
    local u = prefix .. i
    if UnitExists(u) and UnitName(u) == name then return u end
  end
  return nil
end

--- Format a gold amount with the trailing gold glyph.
--- @param g number
--- @return string
function S.fmtGold(g)
  local n = BreakUpLargeNumbers and BreakUpLargeNumbers(g) or tostring(g)
  return "|cffffffff" .. n .. "|r|cffffd100g|r"
end

--- Truncate the MIDDLE of a string (keeps head + tail) so prefixes/suffixes survive.
--- @param s string|nil
--- @param max number
--- @return string
function S.midTruncate(s, max)
  if not s then return "" end
  local n = #s
  if n <= max then return s end
  local keep = max - 1
  local head = math.ceil(keep / 2)
  local tail = keep - head
  return s:sub(1, head) .. "…" .. s:sub(n - tail + 1)
end

--- Format a duration (seconds) as a compact "Xh Ym" / "Ym" / "Zs".
--- @param sec number|nil
--- @return string
function S.fmtTime(sec)
  sec = math.floor(sec or 0)
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  if h > 0 then return h .. "h " .. m .. "m" end
  if m > 0 then return m .. "m" end
  return sec .. "s"
end

-- ---------------------------------------------------------------------------
-- Readiness row values
-- ---------------------------------------------------------------------------
--- Active-buff value with a live remaining-time readout. `remSec` is the seconds
--- left sampled when the partner sent the SNAP; `snapAt` is when it arrived locally,
--- so we subtract elapsed time and the value ticks down on the ~2s dashboard repaint.
--- Falls back to a plain "active" when no duration was shared (older client / buff
--- with no timer) or once our local countdown runs out before the next sync.
--- @param active boolean Whether the buff is present.
--- @param remSec number|nil Remaining seconds at snapshot time.
--- @param snapAt number|nil Local GetTime() when the snapshot arrived.
--- @return string
local function buffValue(active, remSec, snapAt)
  if not active then return L["missing"] end
  if not remSec or remSec <= 0 or not snapAt then return L["active"] end
  local left = remSec - (GetTime() - snapAt)
  if left <= 0 then return L["active"] end
  return S.fmtTime(left) .. L[" left"]
end

--- Populate a keyed table of readiness rows from a snapshot (respects db.show).
--- @param rows table Map of rowKey -> Row object.
--- @param snap table Partner snapshot.
function S.setRowValues(rows, snap)
  local db = ns.db
  -- A row the partner has hidden gets a neutral "Hidden" value (no red/green mark)
  -- so it reads as "no info shared" rather than a failed check.
  local function set(key, label, value, ok)
    if not (db.show[key] and rows[key]) then return end
    if not ns.PartnerShares(key) then
      rows[key]:Set(label, L["Hidden"], nil, Theme.SUBHEADER_COLOR)
    else
      rows[key]:Set(label, value, ok)
    end
  end
  local slot = snap.durSlot and ns.Snapshot.SLOT_NAMES[snap.durSlot]
  set("durability", L["Repairs"] .. (slot and (" |cff808080" .. slot .. "|r") or ""), (snap.dur or 0) .. "%", (snap.dur or 100) >= db.thresholds.durability)
  local at = snap._snapAt
  set("flask", L["Flask"], buffValue(snap.flask, snap.flaskr, at), snap.flask)
  set("food", L["Food buff"], buffValue(snap.food, snap.foodr, at), snap.food)
  set("wpn", L["Weapon oil"], buffValue(snap.wpn, snap.wpnr, at), snap.wpn)
  set("rune", L["Aug rune"], buffValue(snap.rune, snap.runer, at), snap.rune)
  set("bags", L["Bag space"], (snap.bags or 0) .. L[" free"], (snap.bags or 0) > 0)
end

-- ---------------------------------------------------------------------------
-- Content builders (return a string of lines, or "")
-- ---------------------------------------------------------------------------
function S.cActivity(snap)
  local t = {}
  if (snap.key or "") ~= "" and (snap.klvl or 0) > 0 then
    table.insert(t, Theme.InlineIcon(Theme.I_KEY) .. "|cffa335ee" .. snap.key .. " +" .. snap.klvl .. "|r")
  end
  if ((snap.vm or 0) + (snap.vr or 0) + (snap.vw or 0)) > 0 then
    table.insert(t, Theme.InlineIcon(Theme.I_VAULT) .. L["Vault  "] .. "|cffffffff" .. L["M+ "] .. (snap.vm or 0) .. L["/3   Raid "] .. (snap.vr or 0) .. L["/3"] .. "|r")
  end
  return table.concat(t, "\n")
end
function S.cStatus(snap)
  local t = {}
  if (snap.zone or "") ~= "" then
    table.insert(t, Theme.InlineIcon(Theme.I_LOC) .. snap.zone .. (snap.rest and ("  |cff6cb6ff" .. L["(resting)"] .. "|r") or ""))
  end
  if (snap.gold or 0) > 0 then table.insert(t, Theme.InlineIcon(Theme.I_GOLD) .. S.fmtGold(snap.gold)) end
  return table.concat(t, "\n")
end
function S.cGear(snap)
  local t = {}
  if (snap.enchMask or 0) > 0 then
    local names = {}
    for i, slot in ipairs(ns.Snapshot.ENCHANT_SLOTS) do
      if bit.band(snap.enchMask, 2 ^ (i - 1)) ~= 0 then table.insert(names, ns.Snapshot.SLOT_NAMES[slot] or ("slot" .. slot)) end
    end
    table.insert(t, Theme.InlineIcon(Theme.I_GEAR) .. "|cffff8000" .. L["No enchant:"] .. "|r " .. table.concat(names, ", "))
  end
  if (snap.gemMiss or 0) > 0 then table.insert(t, Theme.InlineIcon(Theme.I_GEAR) .. "|cffff8000" .. L["Empty sockets:"] .. "|r " .. snap.gemMiss) end
  local sup = {}
  if (snap.pots or 0) > 0 then table.insert(sup, L["Pots x"] .. snap.pots) end
  table.insert(sup, L["Stone "] .. ((snap.hs or 0) > 0 and ("|cff44ff44" .. L["yes"] .. "|r") or ("|cffff5555" .. L["no"] .. "|r")))
  if (snap.foodCount or 0) > 0 then table.insert(sup, L["Food x"] .. snap.foodCount) end
  table.insert(t, Theme.InlineIcon(Theme.I_SUP) .. table.concat(sup, "   "))
  return table.concat(t, "\n")
end
function S.cQuest(snap)
  if not (ns.db.show.quest and (snap.qid or 0) ~= 0 and (snap.qname or "") ~= "") then return "" end
  local myQ = (C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()) or 0
  local mismatch = (myQ ~= 0 and snap.qid ~= 0 and myQ ~= snap.qid)
  local q = Theme.InlineIcon(Theme.I_QUEST) .. snap.qname
  if (snap.qtotal or 0) > 0 then q = q .. " |cff909090(" .. (snap.qcur or 0) .. "/" .. snap.qtotal .. ")|r" end
  if mismatch then q = q .. "  |cffffcc33" .. L["(off-quest)"] .. "|r" end
  return q
end

-- "Now" — current activity + location, compact (for Overview)
function S.cNow(snap)
  local t = {}
  if (snap.zone or "") ~= "" then
    table.insert(t, Theme.InlineIcon(Theme.I_LOC) .. snap.zone .. (snap.rest and "  |cff6cb6ff(resting)|r" or ""))
  end
  if (snap.key or "") ~= "" and (snap.klvl or 0) > 0 then
    table.insert(t, Theme.InlineIcon(Theme.I_KEY) .. "|cffa335ee" .. snap.key .. " +" .. snap.klvl .. "|r")
  end
  if ((snap.vm or 0) + (snap.vr or 0) + (snap.vw or 0)) > 0 then
    table.insert(t, Theme.InlineIcon(Theme.I_VAULT) .. "Vault  |cffffffffM+ " .. (snap.vm or 0) .. "/3   Raid " .. (snap.vr or 0) .. "/3|r")
  end
  if (snap.gold or 0) > 0 then table.insert(t, Theme.InlineIcon(Theme.I_GOLD) .. S.fmtGold(snap.gold)) end
  return table.concat(t, "\n")
end

-- Supplies detail (Inventory tab): consumables, bag space, wallet
function S.cSupplies(snap)
  local t = {}
  table.insert(t, Theme.InlineIcon(Theme.I_SUP) .. L["Combat potions: "] .. "|cffffffff" .. (snap.pots or 0) .. "|r")
  table.insert(t, Theme.InlineIcon(Theme.I_SUP) .. L["Healthstone: "] .. ((snap.hs or 0) > 0 and ("|cff44ff44" .. L["yes"] .. "|r") or ("|cffff5555" .. L["no"] .. "|r")))
  table.insert(t, Theme.InlineIcon(Theme.ICON.food) .. L["Food: "] .. "|cffffffff" .. (snap.foodCount or 0) .. "|r")
  table.insert(t, Theme.InlineIcon(Theme.ICON.bags) .. L["Bag space: "] .. "|cffffffff" .. (snap.bags or 0) .. L[" free"] .. "|r")
  if (snap.gold or 0) > 0 then table.insert(t, Theme.InlineIcon(Theme.I_GOLD) .. S.fmtGold(snap.gold)) end
  return table.concat(t, "\n")
end

-- ---------------------------------------------------------------------------
-- Centered full-page state (gold loading spinner + a centered message). The shared
-- "this tab is loading / empty / opted-out" affordance: any data page that has to
-- wait on synced data renders the same clean, centered state instead of a left-
-- aligned note. attach() once at build; show() to lay it out (vertically centered in
-- the scroll viewport, spinner optional); clear() when real content takes over.
-- ---------------------------------------------------------------------------
--- Create the spinner + message fontstring on a page frame. Call once in build().
--- @param f table The page frame (a scroll child).
function S.attachFullPageState(f)
  f._fpSpinner = Widgets.Spinner(f, 46)
  f._fpMsg = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f._fpMsg:SetJustifyH("CENTER"); f._fpMsg:SetJustifyV("TOP"); f._fpMsg:SetSpacing(5)
  f._fpMsg:Hide()
end

--- Lay the centered state out and size the page to fill the viewport so it sits in
--- the middle of the panel. Pass spinner=true to play the loading spinner above the
--- message. Returns the page height. Callers hide their own content widgets first.
--- @param f table Page frame (attached via attachFullPageState).
--- @param colW number Max message width reference.
--- @param text string Message (may contain colour escapes / a second \n line).
--- @param spinner boolean|nil Show the loading spinner.
--- @return number height
function S.showFullPageState(f, colW, text, spinner)
  local host = f:GetParent()
  local vh = (host and host:GetHeight()) or 0
  if vh < 160 then vh = 420 end

  f._fpMsg:Show()
  f._fpMsg:SetWidth(math.min(colW, 460))
  f._fpMsg:SetText(text)
  local msgH = f._fpMsg:GetStringHeight()

  if spinner then
    local SP, GAP = 46, 18
    local blockH = SP + GAP + msgH
    f._fpSpinner:ClearAllPoints()
    f._fpSpinner:SetPoint("TOP", f, "TOP", 0, -math.max(0, (vh - blockH) / 2))
    f._fpSpinner:Start()
    f._fpMsg:ClearAllPoints()
    f._fpMsg:SetPoint("TOP", f._fpSpinner, "BOTTOM", 0, -GAP)
  else
    f._fpSpinner:Stop()
    f._fpMsg:ClearAllPoints()
    f._fpMsg:SetPoint("TOP", f, "TOP", 0, -math.max(0, (vh - msgH) / 2))
  end

  f:SetHeight(vh)
  return vh
end

--- Tear the centered state down (stop the spinner, hide the message) before real
--- content renders. Safe to call every refresh.
--- @param f table Page frame.
function S.clearFullPageState(f)
  if f._fpSpinner then f._fpSpinner:Stop() end
  if f._fpMsg then f._fpMsg:Hide() end
end

-- ---------------------------------------------------------------------------
-- Generic vertical "info page" (sections of title + body text). Pools headers
-- and body fontstrings; getSections(snap) returns { {title=, text=}, ... }.
-- ---------------------------------------------------------------------------
function S.makeInfoPage(getSections, emptyText)
  local function build(host)
    local f = CreateFrame("Frame", nil, host); f:SetSize(10, 10)
    f.headers, f.bodies = {}, {}
    f._ff = GameFontHighlight:GetFont()
    return f
  end
  local function ensure(f, i)
    if f.headers[i] then return end
    f.headers[i] = Widgets.SectionHeader(f)
    local b = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b:SetJustifyH("LEFT"); b:SetJustifyV("TOP"); b:SetSpacing(7)
    if f._ff then b:SetFont(f._ff, Theme.FONT_BODY) end
    f.bodies[i] = b
  end
  local function refresh(f, ctx)
    local W = ctx.width; f:SetWidth(W)
    local secs = getSections(ctx.snap) or {}
    local prev, h, n = nil, 0, 0
    for i, s in ipairs(secs) do
      n = i; ensure(f, i)
      local hd, bd = f.headers[i], f.bodies[i]
      hd.label:ClearAllPoints()
      if prev then hd.label:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -24)
      else hd.label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0) end
      Widgets.StyleHeader(hd, s.title, math.min(W, 520))
      bd:Show(); bd:SetWidth(math.min(W, 520))
      bd:ClearAllPoints(); bd:SetPoint("TOPLEFT", hd.diamond, "BOTTOMLEFT", -3, -12)
      bd:SetText((s.text and s.text ~= "") and s.text or (emptyText or "—"))
      h = h + (prev and 24 or 0) + Theme.HEADER_H + bd:GetStringHeight()
      prev = bd
    end
    for i = n + 1, #f.headers do Widgets.HideHeader(f.headers[i]); f.bodies[i]:Hide() end
    f:SetHeight(h + 10)
    return h + 10
  end
  return build, refresh
end

-- ---------------------------------------------------------------------------
-- Generic chip-row page. getSections(snap) returns:
--   { { title=, rows = { {icon=, label=, value=}, ... }, text = "optional" }, ... }
-- Rows render with Row.CreateInfo (chip + label + value); text renders as a muted
-- paragraph. Pools all widgets and hides extras between refreshes.
-- ---------------------------------------------------------------------------
function S.makeRowPage(getSections)
  local Row = ns.UI.Row
  local SEC_GAP = Theme.SECTION_GAP

  local function build(host)
    local f = CreateFrame("Frame", nil, host); f:SetSize(10, 10)
    f._headers, f._rows, f._bodies = {}, {}, {}
    f._ff = GameFontHighlight:GetFont()
    S.attachFullPageState(f)
    return f
  end

  local function ensureBody(f, i)
    if f._bodies[i] then return end
    local b = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b:SetJustifyH("LEFT"); b:SetJustifyV("TOP"); b:SetSpacing(7)
    if f._ff then b:SetFont(f._ff, Theme.FONT_SMALL) end
    b:SetTextColor(0.7, 0.68, 0.6)
    f._bodies[i] = b
  end

  local function refresh(f, ctx)
    local W = ctx.width; f:SetWidth(W)
    -- Fill the whole viewport (these pages always run beside the detail sidebar, which
    -- already constrains the width) so content meets the divider with no dead gap.
    local colW = W
    local secs = getSections(ctx.snap) or {}

    -- A getSections may return a single centered full-page state (loading / empty /
    -- opted-out) instead of content sections: render the shared spinner + message.
    if secs.fullPage then
      for i = 1, #f._headers do Widgets.HideHeader(f._headers[i]) end
      for i = 1, #f._rows do f._rows[i]:SetShown(false) end
      for i = 1, #f._bodies do f._bodies[i]:Hide() end
      return S.showFullPageState(f, colW, secs.fullPage.text, secs.fullPage.spinner)
    end
    S.clearFullPageState(f)

    local prev, h, hi, ri, bi = nil, 0, 0, 0, 0

    for _, sec in ipairs(secs) do
      hi = hi + 1
      if not f._headers[hi] then f._headers[hi] = Widgets.SectionHeader(f) end
      local hd = f._headers[hi]
      hd.label:ClearAllPoints()
      if prev then hd.label:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -SEC_GAP)
      else hd.label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0) end
      Widgets.StyleHeader(hd, sec.title, colW)
      h = h + (prev and SEC_GAP or 0) + Theme.HEADER_H
      local anchor = hd.diamond

      if sec.rows and #sec.rows > 0 then
        for j, it in ipairs(sec.rows) do
          ri = ri + 1
          if not f._rows[ri] then f._rows[ri] = Row.CreateInfo(f, Theme.I_QUEST) end
          local r = f._rows[ri]
          r:SetShown(true); r:SetWidth(colW); r:SetIcon(it.icon)
          if it.youText or it.partnerText then
            r:SetSplit(it.label, it.youText, it.partnerText)
          else
            r:Set(it.label, it.value)
          end
          r:SetHover(it.onEnter, it.onLeave)
          r:SetClick(it.onClick); r:SetSelected(it.selected)
          r.frame:ClearAllPoints()
          r.frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", j == 1 and -3 or 0, j == 1 and -8 or -3)
          anchor = r.frame
        end
        h = h + 8 + #sec.rows * Row.HEIGHT + (#sec.rows - 1) * 3
      end

      if sec.text and sec.text ~= "" then
        bi = bi + 1; ensureBody(f, bi)
        local b = f._bodies[bi]; b:Show(); b:SetWidth(colW)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == hd.diamond and -3 or 0, anchor == hd.diamond and -10 or -10)
        b:SetText(sec.text)
        anchor = b
        h = h + 10 + b:GetStringHeight()
      end
      prev = anchor
    end

    for i = hi + 1, #f._headers do Widgets.HideHeader(f._headers[i]) end
    for i = ri + 1, #f._rows do f._rows[i]:SetShown(false) end
    for i = bi + 1, #f._bodies do f._bodies[i]:Hide() end
    f:SetHeight(h + 12)
    return h + 12
  end

  return build, refresh
end

-- ---------------------------------------------------------------------------
-- Hover-preview + click-to-lock controller for the shared detail pane.
-- Hovering a row previews its detail; clicking locks it (the lock survives hovering
-- other rows); leaving a row restores the locked detail (or clears to the hint),
-- deferred a beat so sliding between rows doesn't flash the restore state between.
--
-- opts.show(key, payload, mode)  render a row's detail. mode is "preview" (hover),
--                                "lock" (click) or "restore" (revert after leave).
-- opts.clear()                   restore the empty/hint pane (default Dashboard.ClearDetail).
-- opts.onLock()                  run after a click changes the lock, e.g. to repaint
--                                the selected-row highlight (default Dashboard.Refresh).
-- opts.revertDelay               seconds before restoring on leave (default 0.05).
--
-- Returns { preview(key, payload), leave(), lock(key, payload), isLocked(key),
-- unlock() }. unlock() drops the lock without touching the pane (pair with a
-- caller-side clear, e.g. on tab re-open).
function S.makePinController(opts)
  opts = opts or {}
  local show = opts.show
  local clear = opts.clear or function() if ns.Dashboard and ns.Dashboard.ClearDetail then ns.Dashboard.ClearDetail() end end
  local onLock = opts.onLock or function() if ns.Dashboard and ns.Dashboard.Refresh then ns.Dashboard.Refresh() end end
  local revertDelay = opts.revertDelay or 0.05

  local lockedKey, lockedPayload, revertTimer
  local ctrl = {}

  function ctrl.preview(key, payload)
    if revertTimer then revertTimer:Cancel(); revertTimer = nil end
    if show then show(key, payload, "preview") end
  end

  function ctrl.leave()
    if revertTimer then revertTimer:Cancel() end
    revertTimer = C_Timer.NewTimer(revertDelay, function()
      revertTimer = nil
      if lockedKey ~= nil then
        if show then show(lockedKey, lockedPayload, "restore") end
      else
        clear()
      end
    end)
  end

  function ctrl.lock(key, payload)
    if revertTimer then revertTimer:Cancel(); revertTimer = nil end
    lockedKey, lockedPayload = key, payload
    if show then show(key, payload, "lock") end
    onLock()
  end

  function ctrl.isLocked(key) return lockedKey == key end

  function ctrl.unlock()
    if revertTimer then revertTimer:Cancel(); revertTimer = nil end
    lockedKey, lockedPayload = nil, nil
  end

  return ctrl
end

return S
