--[[ UI/Dashboard.lua
  The tab shell (ns.Dashboard). Native ButtonFrame with a shared header
  (portrait + class-colored name + verdict), a Plumber-style left nav list, and a
  content host that swaps page frames. Pages register via Dashboard.RegisterPage.
  The collapse (-) button drops to a compact single-column readiness card.

  Public API kept stable for Core.lua: Init / Refresh / ApplyMode / OpenTab /
  Select / Show / Hide / SetScale / SavePosition / RestorePosition / ApplyLock.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Dashboard = {}
ns.Dashboard = Dashboard

local S = ns.UI.Shared
local Theme = ns.UI.Theme
local Widgets = ns.UI.Widgets
local Row = ns.UI.Row
local L = ns.L

local WIDTH_COMPACT, WIDTH_EXPANDED, PAD = 320, 1280, 16
local PANEL_H_EXPANDED = 640        -- FIXED expanded height; content scrolls
local CONTENT_TOP = 60
local NAV_W, NAV_BTN_H = 178, 32
local HOST_X = PAD + NAV_W + 18
local SCROLLBAR_W = 26
local DETAIL_W = 300         -- right-side preview pane width (when a page uses it)

local panel, host, nav
local navButtons = {}
local pages, pagesByKey = {}, {}
local activeKey
local shouldShow = true

local function hostWidth(detail) return WIDTH_EXPANDED - HOST_X - PAD - (detail and (DETAIL_W + 18) or 0) end
local function scrollWidth(detail) return hostWidth(detail) - SCROLLBAR_W end

-- Auto-fit. The expanded panel is a fixed WIDTH_EXPANDED x PANEL_H_EXPANDED, sized
-- to nearly fill a standard 768-unit-tall UI. On large monitors / low WoW UI-scale
-- (notably 4K, where UIParent sits near its 768px floor) a raw scale of 1.0 makes
-- the panel dominate the screen, so we derive a base scale that keeps it within a
-- comfortable fraction of the available space. ns.db.scale then multiplies this:
-- 1.0 = the recommended fit; raise or lower to taste.
local FIT_W, FIT_H = 0.66, 0.46   -- target fraction of the screen the panel covers
local function fitScale()
  local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
  if not (sw and sh) or sw <= 0 or sh <= 0 then return 1.0 end
  local s = math.min((sw * FIT_W) / WIDTH_EXPANDED, (sh * FIT_H) / PANEL_H_EXPANDED)
  return math.max(0.5, math.min(1.0, s))   -- never upscale past the design size
end

local function applyScale()
  if not panel then return end
  panel:SetScale(math.max(0.4, math.min(2.0, fitScale() * (ns.db.scale or 1.0))))
end

-- Diagnostic: dump the numbers that drive scaling so the default can be tuned to
-- match a reference addon (e.g. Plumber). Invoked via `/bt scaleinfo`.
function Dashboard.PrintScaleInfo()
  local pw, ph = GetPhysicalScreenSize()
  ns:Print(string.format("physical screen: %s x %s", tostring(pw), tostring(ph)))
  ns:Print(string.format("UIParent: effScale=%.3f height=%.0f units", UIParent:GetEffectiveScale(), UIParent:GetHeight()))
  ns:Print(string.format("fitScale=%.3f  db.scale=%.2f", fitScale(), ns.db.scale or 1.0))
  if panel then
    ns:Print(string.format("panel: scale=%.3f effScale=%.3f  -> ~%.0f%% of screen height",
      panel:GetScale(), panel:GetEffectiveScale(), 100 * (PANEL_H_EXPANDED * panel:GetScale()) / UIParent:GetHeight()))
  end
  if _G.PlumberDB ~= nil or _G.Plumber ~= nil then ns:Print("(Plumber is loaded — compare its panel size by eye)") end
end

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
-- Header
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
local function updateHeader(snap, verdict)
  local r, g, b = S.classColor(snap.cls)
  setPortrait(snap.cls)
  setTitle(S.hex(r, g, b) .. (ns.state.partnerName or L["Partner"]) .. "|r")
  panel.vDot:SetTexture(Theme.INDICATOR[verdict] or Theme.INDICATOR.wait)
  local vc = Theme.VERDICT_RGB[verdict] or Theme.VERDICT_RGB.wait
  panel.vLabel:SetText(Theme.VERDICT_LABEL[verdict] or ""); panel.vLabel:SetTextColor(vc[1], vc[2], vc[3])
end

-- ---------------------------------------------------------------------------
-- Presence + readiness toasts (the proactive layer over the passive panel).
-- Refresh runs ~every 2s and computes a verdict; we watch for *transitions* and
-- surface a toast + a ping on the title-bar dot. Seeded silently on first sight so
-- a login / reload doesn't fire, and readiness toasts only fire between two "real"
-- verdicts (never to/from the wait/offline placeholders), so flicker stays quiet.
-- ---------------------------------------------------------------------------
local function classIcon(cls)
  local atlas = (cls and cls ~= "") and ("classicon-" .. strlower(cls)) or nil
  if atlas and Theme.AtlasExists(atlas) then return atlas end
  return "Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend"   -- friendly fallback
end

local toastSeeded, lastLinked, lastVerdict
local REAL_VERDICT = { ready = true, amber = true, red = true }
local function notifyTransitions(snap, verdict)
  local Toast = ns.UI and ns.UI.Toast
  local linked = ns.state.linked == true
  local name = ns.state.partnerName or L["Partner"]
  if not toastSeeded then   -- first observation this session: record, don't announce
    toastSeeded, lastLinked, lastVerdict = true, linked, verdict
    return
  end
  local pal, snd = Theme.VERDICT_RGB, SOUNDKIT
  if Toast then
    if linked ~= lastLinked then
      if linked then
        Toast.Show({ title = string.format(L["%s is online"], name), subtitle = L["Linked up — syncing now."],
          icon = classIcon(snap.cls), color = pal.ready, sound = snd and snd.UI_BNET_TOAST })
      else
        Toast.Show({ title = string.format(L["%s went offline"], name), subtitle = L["You'll reconnect automatically."],
          icon = classIcon(snap.cls), color = pal.offline, sound = snd and snd.UI_BNET_TOAST })
      end
    elseif linked and verdict ~= lastVerdict and REAL_VERDICT[verdict] and REAL_VERDICT[lastVerdict] then
      if verdict == "ready" then
        Toast.Show({ title = string.format(L["%s is ready"], name), subtitle = L["All checks passed — good to pull."],
          icon = classIcon(snap.cls), color = pal.ready, sound = snd and snd.READY_CHECK })
      elseif verdict == "red" and lastVerdict == "ready" then
        Toast.Show({ title = string.format(L["%s is no longer ready"], name), subtitle = L["Hold up — a check needs attention."],
          icon = classIcon(snap.cls), color = pal.red, sound = snd and snd.UI_BNET_TOAST })
      end
    end
  end
  if verdict ~= lastVerdict and panel and panel.vPing then
    panel.vPing(pal[verdict] or pal.wait)   -- visual cue even when toasts are off
  end
  lastLinked, lastVerdict = linked, verdict
end

-- ---------------------------------------------------------------------------
-- Nav buttons
-- ---------------------------------------------------------------------------
local function setNavActive(b, active)
  b.active = active
  b.accent:SetShown(active)
  b.glow:SetShown(active)
  if active then
    b.hl:Hide()
    b.fs:SetTextColor(Theme.CREAM[1], Theme.CREAM[2], Theme.CREAM[3])
  else
    if b.stub then b.fs:SetTextColor(0.5, 0.5, 0.5) else b.fs:SetTextColor(0.86, 0.82, 0.70) end
  end
end

local function makeNavButton(parent, desc)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(NAV_W - 10, NAV_BTN_H)
  b.key, b.stub = desc.key, desc.stub

  -- active glow (gold gradient fading right)
  local glow = b:CreateTexture(nil, "BACKGROUND"); glow:SetAllPoints(b); glow:SetColorTexture(1, 1, 1, 1)
  if CreateColor then
    glow:SetGradient("HORIZONTAL", CreateColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.28), CreateColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.0))
  else glow:SetColorTexture(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.16) end
  glow:Hide(); b.glow = glow
  -- hover highlight (subtle white)
  local hl = b:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(b); hl:SetColorTexture(1, 1, 1, 0.06); hl:Hide()
  b.hl = hl
  -- left accent bar
  local accent = b:CreateTexture(nil, "ARTWORK"); accent:SetSize(3, NAV_BTN_H - 10)
  accent:SetPoint("LEFT", b, "LEFT", 2, 0); accent:SetColorTexture(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3]); accent:Hide()
  b.accent = accent

  local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetPoint("LEFT", b, "LEFT", 14, 0); fs:SetText(desc.label)
  local ff = GameFontHighlight:GetFont(); if ff then fs:SetFont(ff, 15) end
  b.fs = fs

  b:SetScript("OnEnter", function() if not b.active then hl:Show() end end)
  b:SetScript("OnLeave", function() hl:Hide() end)
  b:SetScript("OnClick", function() Dashboard.Select(desc.key) end)
  setNavActive(b, false)
  return b
end

-- ---------------------------------------------------------------------------
-- Compact card widgets
-- ---------------------------------------------------------------------------
local function buildCompact(content)
  local c = {}
  c.roleIcon = content:CreateTexture(nil, "ARTWORK"); c.roleIcon:SetSize(15, 15)
  c.idFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); c.idFS:SetJustifyH("LEFT")
  c.ilvlFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormal"); c.ilvlFS:SetJustifyH("RIGHT")
  c.rows = {}
  for _, key in ipairs({ "durability", "flask", "food", "wpn", "rune", "bags" }) do
    c.rows[key] = Row.Create(content, Theme.ICON[key])
  end
  c.sep = content:CreateTexture(nil, "ARTWORK"); c.sep:SetColorTexture(1, 1, 1, 0.08); c.sep:SetHeight(1)
  c.details = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  c.details:SetJustifyH("LEFT"); c.details:SetJustifyV("TOP"); c.details:SetSpacing(6)
  local ff = GameFontHighlight:GetFont(); if ff then c.details:SetFont(ff, 14) end
  return c
end

local function showCompact(c, shown)
  c.roleIcon:SetShown(shown); c.idFS:SetShown(shown); c.ilvlFS:SetShown(shown)
  c.sep:SetShown(shown); c.details:SetShown(shown)
  for _, r in pairs(c.rows) do if not shown then r:SetShown(false) end end
end

local function layoutCompact(c, snap, r, g, b)
  local W = WIDTH_COMPACT
  local content = panel.content
  c.roleIcon:ClearAllPoints(); c.roleIcon:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -PAD)
  local sp, role = S.specInfo(snap.spec)
  local ra = S.roleAtlas(role)
  if ra then c.roleIcon:SetAtlas(ra); c.roleIcon:Show() else c.roleIcon:Hide() end
  c.idFS:ClearAllPoints()
  if c.roleIcon:IsShown() then c.idFS:SetPoint("LEFT", c.roleIcon, "RIGHT", 5, 0)
  else c.idFS:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -PAD) end
  local parts = {}
  local cn = S.classDisplayName(snap.cls)
  if sp ~= "" or cn ~= "" then table.insert(parts, S.hex(r, g, b) .. (sp ~= "" and (sp .. " ") or "") .. cn .. "|r") end
  if (snap.lvl or 0) > 0 then table.insert(parts, Theme.C.faint .. L["Lv "] .. snap.lvl .. "|r") end
  c.idFS:SetText(table.concat(parts, "  "))
  c.ilvlFS:ClearAllPoints(); c.ilvlFS:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, -PAD)
  c.ilvlFS:SetText((snap.ilvl or 0) > 0 and (Theme.C.gold .. snap.ilvl .. "|r " .. Theme.C.muted .. L["ilvl"] .. "|r") or "")

  S.setRowValues(c.rows, snap)
  local anchor, count = c.idFS, 0
  for _, key in ipairs({ "durability", "flask", "food", "wpn", "rune", "bags" }) do
    local row = c.rows[key]
    if ns.db.show[key] then
      row:SetShown(true); row:SetWidth(W - 2 * PAD)
      row.frame:ClearAllPoints()
      row.frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == c.idFS and 0 or 0, anchor == c.idFS and -8 or -3)
      anchor = row.frame; count = count + 1
    else row:SetShown(false) end
  end

  local combined = {}
  for _, fn in ipairs({ S.cActivity, S.cStatus, S.cGear, S.cQuest }) do
    local s = fn(snap); if s ~= "" then table.insert(combined, s) end
  end
  local text = table.concat(combined, "\n")
  c.details:SetWidth(W - 2 * PAD)
  c.sep:ClearAllPoints(); c.sep:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8); c.sep:SetWidth(W - 2 * PAD)
  c.sep:SetShown(text ~= "")
  c.details:ClearAllPoints(); c.details:SetPoint("TOPLEFT", c.sep, "BOTTOMLEFT", 0, -8); c.details:SetText(text)

  local h = PAD + 16 + 8 + count * (Row.HEIGHT + 3)
  if text ~= "" then h = h + 8 + 1 + 8 + c.details:GetStringHeight() end
  return h + PAD
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local compact

-- ---------------------------------------------------------------------------
-- Item detail renderer (custom, non-tooltip — styled as part of the addon)
-- ---------------------------------------------------------------------------
-- Play the detail pane's loading spinner, centered under the header at `y`. Idempotent
-- so a re-render mid-wait (e.g. GET_ITEM_INFO_RECEIVED) doesn't restart the comet.
local function startDetailSpinner(y)
  local sp = panel and panel.detailSpinner
  if not sp then return end
  sp:ClearAllPoints()
  sp:SetPoint("TOP", panel.detailBody, "TOP", 0, y or -64)
  if not sp:IsShown() then sp:Start() end
  return sp
end
local function stopDetailSpinner()
  if panel and panel.detailSpinner then panel.detailSpinner:Stop() end
end

local function renderItemDetail()
  local id = panel._detailID
  if not id then return end
  local icon = (select(5, GetItemInfoInstant(id))) or 134400
  panel.detailChip.icon:SetTexture(icon); panel.detailChip:Show()

  -- Awaiting the partner's full item string: show the (correct) name + a loading
  -- note rather than the base item's stats, so the item level doesn't visibly jump
  -- once the upgraded string lands.
  if panel._detailPending then
    local nm, _, quality = GetItemInfo(id)
    panel.detailName:SetText(nm or (L["item:"] .. tostring(id)))
    local qr, qg, qb = Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3]
    local qc = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if qc then qr, qg, qb = qc.r or qr, qc.g or qg, qc.b or qb end
    panel.detailName:SetTextColor(qr, qg, qb)
    panel.detailQChip:Hide(); panel.detailQLabel:Hide()
    local sp = startDetailSpinner(-66)
    panel.detailText:ClearAllPoints()
    panel.detailText:SetJustifyH("CENTER")
    if sp then panel.detailText:SetPoint("TOP", sp, "BOTTOM", 0, -14)
    else panel.detailText:SetPoint("TOPLEFT", panel.detailBody, "TOPLEFT", 2, -60) end
    panel.detailText:SetText(Theme.C.muted2 .. L["Loading partner's item details…"] .. "|r")
    panel.detailText:Show()
    panel.detailBody:SetHeight(150)
    if panel.detailScroll then panel.detailScroll:SetVerticalScroll(0); panel.detailScroll:UpdateScrollChildRect() end
    return
  end

  -- id may be a number (GetItemByID) or an item string with bonuses (GetHyperlink,
  -- so upgraded item level / stats render correctly).
  local data
  if C_TooltipInfo then
    if type(id) == "string" and C_TooltipInfo.GetHyperlink then data = C_TooltipInfo.GetHyperlink(id)
    elseif C_TooltipInfo.GetItemByID then data = C_TooltipInfo.GetItemByID(id) end
  end
  if not data or not data.lines or #data.lines == 0 then
    local numId = type(id) == "number" and id or tonumber(tostring(id):match("item:(%d+)"))
    if numId and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(numId) end
    panel.detailName:SetText(Theme.C.muted2 .. L["Loading…"] .. "|r")
    panel.detailText:Hide(); panel.detailQChip:Hide(); panel.detailQLabel:Hide()
    startDetailSpinner(-58)
    panel.detailBody:SetHeight(110); if panel.detailScroll then panel.detailScroll:UpdateScrollChildRect() end
    return
  end

  stopDetailSpinner()
  panel.detailText:SetJustifyH("LEFT")
  local function surface(t) if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(t) end end
  surface(data)
  local l1 = data.lines[1]; surface(l1)
  panel.detailName:SetText((l1 and l1.leftText) or (L["item:"] .. id))
  local qr, qg, qb = Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3]
  if l1 and l1.leftColor and l1.leftColor.GetRGB then qr, qg, qb = l1.leftColor:GetRGB() end
  panel.detailName:SetTextColor(qr, qg, qb)

  -- One fontstring for the whole body (like a tooltip) — single anchor, so no
  -- multi-widget interaction can ever shift it. Per-line color preserved; buff
  -- icons rendered inline + size-normalized so they sit on the text baseline.
  local BASE = 60
  local parts = {}
  for i = 2, #data.lines do
    local line = data.lines[i]; surface(line)
    local lt = line.leftText or ""
    if not (lt:find("Professions") or lt:find("CraftingQuality")) then
      local s = lt:gsub("|T([^:|]+):[^|]*|t", "|T%1:18:18:0:-3|t")  -- normalize inline icons
      if line.rightText and line.rightText ~= "" then s = s .. "   " .. Theme.C.white .. line.rightText .. "|r" end
      if line.leftColor and line.leftColor.GetRGB then
        local r, g, b = line.leftColor:GetRGB()
        s = Theme.Hex({ r, g, b }) .. s .. "|r"
      end
      parts[#parts + 1] = s
    end
  end
  panel.detailText:ClearAllPoints()
  panel.detailText:SetPoint("TOPLEFT", panel.detailBody, "TOPLEFT", 2, -BASE)
  panel.detailText:SetText(table.concat(parts, "\n"))
  panel.detailText:Show()

  -- crafting quality as a chip, below the text block
  local q
  if C_TradeSkillUI then
    if C_TradeSkillUI.GetItemCraftedQualityByItemInfo then local ok, v = pcall(C_TradeSkillUI.GetItemCraftedQualityByItemInfo, id); if ok then q = v end end
    if not q and C_TradeSkillUI.GetItemReagentQualityByItemInfo then local ok, v = pcall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, id); if ok then q = v end end
  end
  local qAtlas
  if q and q > 0 then
    for _, a in ipairs({ "Professions-ChatIcon-Quality-Tier" .. q, "Professions-Icon-Quality-Tier" .. q }) do
      if Theme.AtlasExists(a) then qAtlas = a; break end
    end
  end
  local contentH = 60 + (panel.detailText:GetStringHeight() or 0)
  if qAtlas then
    panel.detailQChip.icon:SetTexCoord(0, 1, 0, 1); panel.detailQChip.icon:SetAtlas(qAtlas)
    panel.detailQChip:ClearAllPoints()
    panel.detailQChip:SetPoint("TOPLEFT", panel.detailText, "BOTTOMLEFT", 0, -10)
    panel.detailQChip:Show()
    panel.detailQLabel:SetText(L["Quality "] .. Theme.C.white .. L["Tier "] .. q .. "|r"); panel.detailQLabel:Show()
    contentH = contentH + 10 + 30
  else
    panel.detailQChip:Hide(); panel.detailQLabel:Hide()
  end
  panel.detailBody:SetHeight(contentH + 14)
  if panel.detailScroll then panel.detailScroll:UpdateScrollChildRect() end
end

-- Quest detail (Quests tab): reuses the item pane's chip/name/body widgets to
-- render a quest's status + objectives. `q` = { id, title, status, you, partner }
-- where you/partner are { done, cur, total } (or nil if that side isn't on it).
local function renderQuestDetail()
  local q = panel._detailQuest
  if not q then return end
  stopDetailSpinner()
  panel.detailText:SetJustifyH("LEFT")
  panel.detailHint:Hide()
  Theme.ApplyIcon(panel.detailChip.icon, Theme.I_QUEST)
  panel.detailChip:Show()
  panel.detailName:SetText(q.title or (L["Quest #"] .. (q.id or 0)))
  panel.detailName:SetTextColor(Theme.CREAM[1], Theme.CREAM[2], Theme.CREAM[3])

  local function prog(side)
    if not side then return Theme.C.dim .. L["not on this quest"] .. "|r" end
    if side.done then return Theme.C.ready .. L["Complete"] .. "|r" end
    if (side.total or 0) > 0 then return Theme.C.white .. (side.cur or 0) .. " / " .. side.total .. "|r" end
    return Theme.C.white .. L["In progress"] .. "|r"
  end

  local parts = {}
  local statusText = ({
    both        = Theme.C.ready .. L["You're both on this quest."] .. "|r",
    partnerOnly = Theme.C.warn .. L["Only your partner is on this quest."] .. "|r",
    youOnly     = Theme.C.info .. L["Only you are on this quest."] .. "|r",
  })[q.status]
  if statusText then parts[#parts + 1] = statusText end
  parts[#parts + 1] = Theme.C.muted .. L["Quest ID"] .. "|r  " .. (q.id or 0)
  parts[#parts + 1] = " "

  -- Your side: real per-objective text when we're actually on the quest; else the
  -- synced aggregate.
  parts[#parts + 1] = Theme.C.gold .. L["Your progress"] .. "|r"
  local objs = C_QuestLog and C_QuestLog.GetQuestObjectives
    and C_QuestLog.GetQuestObjectives(q.id) or nil
  if objs and #objs > 0 then
    for _, o in ipairs(objs) do
      parts[#parts + 1] = (o.finished and Theme.C.ready or Theme.C.soft) .. (o.text or "") .. "|r"
    end
  else
    parts[#parts + 1] = prog(q.you)
  end
  parts[#parts + 1] = " "
  parts[#parts + 1] = Theme.C.gold .. L["Partner progress"] .. "|r"
  parts[#parts + 1] = prog(q.partner)

  panel.detailQChip:Hide(); panel.detailQLabel:Hide()
  panel.detailText:ClearAllPoints()
  panel.detailText:SetPoint("TOPLEFT", panel.detailBody, "TOPLEFT", 2, -60)
  panel.detailText:SetText(table.concat(parts, "\n"))
  panel.detailText:Show()

  panel.detailBody:SetHeight(60 + (panel.detailText:GetStringHeight() or 0) + 14)
  if panel.detailScroll then panel.detailScroll:UpdateScrollChildRect() end
end

-- Achievement detail (Achievements tab): reuses the item pane's chip/name/body to
-- show a shared achievement. `a` = { id, name, icon, points, desc, together, status,
-- youStr, partnerStr } — youStr/partnerStr are preformatted "earned on" dates (or nil).
local function renderAchvDetail()
  local a = panel._detailAchv
  if not a then return end
  stopDetailSpinner()
  panel.detailText:SetJustifyH("LEFT")
  panel.detailHint:Hide()
  panel.detailChip.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
  panel.detailChip.icon:SetTexture(a.icon or 134400)
  panel.detailChip:Show()
  panel.detailName:SetText(a.name or (L["Achievement #"] .. (a.id or 0)))
  if a.together then panel.detailName:SetTextColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3])
  else panel.detailName:SetTextColor(Theme.CREAM[1], Theme.CREAM[2], Theme.CREAM[3]) end

  local parts = {}
  if a.together then
    parts[#parts + 1] = Theme.C.ready .. L["You both earned this the same day."] .. "|r"
  else
    local st = ({ youOnly = Theme.C.info .. L["Only you have earned this."] .. "|r",
                  partnerOnly = Theme.C.warn .. L["Only your partner has earned this."] .. "|r" })[a.status]
    if st then parts[#parts + 1] = st end
  end
  if (a.points or 0) > 0 then parts[#parts + 1] = Theme.C.gold .. a.points .. L[" points"] .. "|r" end
  parts[#parts + 1] = " "
  if a.desc and a.desc ~= "" then
    parts[#parts + 1] = Theme.C.soft .. a.desc .. "|r"; parts[#parts + 1] = " "
  end
  parts[#parts + 1] = Theme.C.gold .. L["You"] .. "|r  " .. (a.youStr or (Theme.C.dim .. L["not earned"] .. "|r"))
  parts[#parts + 1] = Theme.C.gold .. L["Partner"] .. "|r  " .. (a.partnerStr or (Theme.C.dim .. L["not earned"] .. "|r"))

  panel.detailQChip:Hide(); panel.detailQLabel:Hide()
  panel.detailText:ClearAllPoints()
  panel.detailText:SetPoint("TOPLEFT", panel.detailBody, "TOPLEFT", 2, -60)
  panel.detailText:SetText(table.concat(parts, "\n"))
  panel.detailText:Show()
  panel.detailBody:SetHeight(60 + (panel.detailText:GetStringHeight() or 0) + 14)
  if panel.detailScroll then panel.detailScroll:UpdateScrollChildRect() end
end

-- Slim + recolor a UIPanelScrollFrameTemplate scrollbar (thin gold thumb, no arrows).
local function styleScrollbar(sf)
  local sb = sf and sf.ScrollBar
  if not sb then return end
  local up, down = sb.ScrollUpButton, sb.ScrollDownButton
  for _, b in ipairs({ up, down }) do
    if b then b:SetAlpha(0); b:SetSize(1, 1); b:EnableMouse(false); b:SetScript("OnShow", b.Hide); b:Hide() end
  end
  sb:SetWidth(8)
  local thumb = sb.GetThumbTexture and sb:GetThumbTexture()
  if thumb then thumb:SetColorTexture(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.5); thumb:SetWidth(6) end
end

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
  cb:SetScript("OnClick", function() ns.db.expanded = not ns.db.expanded; Dashboard.ApplyMode() end)
  panel.collapseBtn = cb

  -- left nav + divider + content host
  nav = CreateFrame("Frame", nil, content)
  nav:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -PAD)
  nav:SetSize(NAV_W, 10)
  local navDiv = content:CreateTexture(nil, "ARTWORK")
  navDiv:SetColorTexture(1, 1, 1, 0.08); navDiv:SetWidth(1)
  navDiv:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + NAV_W + 8, -PAD)
  navDiv:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", PAD + NAV_W + 8, PAD)
  panel.navDiv = navDiv

  -- Scrollable content host (fixed window; content scrolls — Plumber-style)
  host = CreateFrame("ScrollFrame", "BetterTogetherScroll", content, "UIPanelScrollFrameTemplate")
  -- Anchor top AND bottom to content so the scroll viewport's clip edge tracks the
  -- real inset bounds; with only a fixed inner-height estimate the last row spills
  -- past the bottom border before scrolling (same fix as the detail pane). Width is set live.
  host:SetPoint("TOPLEFT", content, "TOPLEFT", HOST_X, -PAD)
  host:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", HOST_X, PAD)
  host:SetWidth(scrollWidth())
  host:EnableMouseWheel(true)
  host:SetScript("OnMouseWheel", function(self, delta)
    local new = math.min(self:GetVerticalScrollRange(), math.max(0, self:GetVerticalScroll() - delta * 45))
    self:SetVerticalScroll(new)
  end)
  panel.host = host
  styleScrollbar(host)

  -- Right-side preview/detail pane (Plumber-style). Pages opt in via desc.detail.
  local detailDiv = content:CreateTexture(nil, "ARTWORK")
  detailDiv:SetColorTexture(1, 1, 1, 0.08); detailDiv:SetWidth(1)
  detailDiv:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD - DETAIL_W - 9, -PAD)
  detailDiv:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -PAD - DETAIL_W - 9, PAD)
  panel.detailDiv = detailDiv

  local detail = CreateFrame("Frame", nil, content)
  -- Anchor top AND bottom to content so the pane's height tracks the actual inset
  -- bounds (not a fixed inner-height estimate); otherwise the scroll frame's clip edge
  -- lands just past the bottom border and long tooltips peek out beneath it.
  detail:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, -PAD)
  detail:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -PAD, PAD)
  detail:SetWidth(DETAIL_W)
  panel.detail = detail
  local dHdr = Widgets.SectionHeader(detail)
  dHdr.label:SetPoint("TOPLEFT", detail, "TOPLEFT", 0, 0)
  Widgets.StyleHeader(dHdr, L["Item Details"], DETAIL_W)
  panel.detailHdr = dHdr
  -- scrollable area (long recipe/item tooltips can exceed the pane height)
  local dscroll = CreateFrame("ScrollFrame", nil, detail, "UIPanelScrollFrameTemplate")
  dscroll:SetPoint("TOPLEFT", detail, "TOPLEFT", 0, -38)
  dscroll:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -16, 0)
  dscroll:EnableMouseWheel(true)
  dscroll:SetScript("OnMouseWheel", function(self, d)
    self:SetVerticalScroll(math.min(self:GetVerticalScrollRange(), math.max(0, self:GetVerticalScroll() - d * 40)))
  end)
  panel.detailScroll = dscroll
  styleScrollbar(dscroll)
  local body = CreateFrame("Frame", nil, dscroll)
  body:SetWidth(DETAIL_W - 18); body:SetHeight(10)
  dscroll:SetScrollChild(body)
  panel.detailBody = body
  local hint = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  hint:SetPoint("TOPLEFT", body, "TOPLEFT", 2, -2); hint:SetWidth(DETAIL_W - 4); hint:SetJustifyH("LEFT")
  hint:SetTextColor(0.6, 0.6, 0.62); hint:SetText(L["Hover an item to preview it here."])
  panel.detailHint = hint
  -- Custom (non-tooltip) item detail, styled as part of the addon:
  -- chip (same as throughout) + name (vertically centered) + scanned lines.
  local chip = Widgets.Chip(body, 46); chip:SetPoint("TOPLEFT", body, "TOPLEFT", 2, -2); chip:Hide()
  panel.detailChip = chip

  local dn = body:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  dn:SetPoint("LEFT", chip, "RIGHT", 10, 0)   -- single anchor (vertical center of chip)
  dn:SetWidth(DETAIL_W - 64); dn:SetJustifyH("LEFT"); dn:SetJustifyV("MIDDLE"); dn:SetWordWrap(false)
  panel.detailName = dn

  local dt = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  dt:SetWidth(DETAIL_W - 26); dt:SetJustifyH("LEFT"); dt:SetJustifyV("TOP"); dt:SetSpacing(5)
  local dff = GameFontHighlight:GetFont(); if dff then dt:SetFont(dff, 13) end
  dt:Hide(); panel.detailText = dt

  -- Loading spinner for the detail pane: shown while we wait on the partner's full
  -- item string (the on-demand inventory lookup) or on the base item data load.
  local dspin = Widgets.Spinner(body, 36); panel.detailSpinner = dspin

  -- crafting-quality shown as one of our chips
  local qchip = Widgets.Chip(body, 30); qchip:Hide(); panel.detailQChip = qchip
  local qlbl = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  qlbl:SetPoint("LEFT", qchip, "RIGHT", 10, 0); qlbl:SetJustifyH("LEFT"); qlbl:Hide()
  local qff = GameFontHighlight:GetFont(); if qff then qlbl:SetFont(qff, 14) end
  panel.detailQLabel = qlbl
  detail:Hide()

  ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
    if panel and panel._detailID and panel.detail:IsShown() then renderItemDetail() end
  end)

  -- sort + build nav
  table.sort(pages, function(a, b) return (a.order or 99) < (b.order or 99) end)
  local prev
  for _, desc in ipairs(pages) do
    -- A page can open a new category: extra space + a thin gold divider above it.
    local gap = 2
    if desc.separator and prev then
      gap = 14
      local div = nav:CreateTexture(nil, "ARTWORK")
      div:SetHeight(1); div:SetColorTexture(1, 1, 1, 1)
      if CreateColor then
        div:SetGradient("HORIZONTAL", CreateColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.0),
          CreateColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.45))
      else div:SetVertexColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.3) end
      div:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 6, -(gap / 2))
      div:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", -6, -(gap / 2))
    end

    local b = makeNavButton(nav, desc)
    if prev then b:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -gap)
    else b:SetPoint("TOPLEFT", nav, "TOPLEFT", 0, 0) end
    prev = b
    table.insert(navButtons, b)
  end

  compact = buildCompact(content)

  Dashboard.RestorePosition()
  applyScale()
  -- Keep the fit current if the player changes resolution or WoW's UI scale.
  ns:RegisterEvent("DISPLAY_SIZE_CHANGED", applyScale)
  ns:RegisterEvent("UI_SCALE_CHANGED", applyScale)
  Dashboard.Select(ns.chardb.lastTab or "overview")
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
function Dashboard.SetScale(s) ns.db.scale = s; applyScale() end
function Dashboard.Show() shouldShow = true; if panel then panel:Show() end end
function Dashboard.Hide() shouldShow = false; if panel then panel:Hide() end end
function Dashboard.ApplyMode()
  if not panel then return end
  panel.collapseBtn:SetText(ns.db.expanded and "–" or "+")
  Dashboard.Refresh()
end
-- pending=true means this is the base item shown while we await the partner's full
-- string; renderItemDetail then shows a "loading" placeholder instead of the (about
-- to change) base item level.
function Dashboard.ShowItemDetail(id, pending)
  if not (panel and panel.detail:IsShown()) then return end
  panel.detailHint:Hide()
  panel._detailQuest = nil
  panel._detailAchv = nil
  panel._detailID = id
  panel._detailPending = pending and true or nil
  renderItemDetail()
end

-- A partner's full item string (bonus IDs) just arrived. If the detail pane is
-- currently showing this item (matched by base itemID), upgrade it in place so the
-- correct ilvl/stats render without the user re-clicking.
function Dashboard.OnItemDetailArrived(id, itemString)
  if not (panel and panel.detail:IsShown() and panel._detailID) then return end
  local cur = panel._detailID
  local curID = type(cur) == "number" and cur or tonumber(tostring(cur):match("item:(%d+)"))
  if curID == tonumber(id) then
    panel._detailID = itemString
    panel._detailPending = nil
    renderItemDetail()
  end
end
function Dashboard.ShowQuestDetail(q)
  if not (panel and panel.detail:IsShown()) then return end
  panel.detailHint:Hide()
  panel._detailID = nil
  panel._detailAchv = nil
  panel._detailQuest = q
  renderQuestDetail()
end
function Dashboard.ShowAchievementDetail(a)
  if not (panel and panel.detail:IsShown()) then return end
  panel.detailHint:Hide()
  panel._detailID = nil
  panel._detailQuest = nil
  panel._detailAchv = a
  renderAchvDetail()
end
function Dashboard.ClearDetail()
  if not panel then return end
  panel._detailID = nil
  panel._detailQuest = nil
  panel._detailAchv = nil
  panel._detailPending = nil
  stopDetailSpinner()
  if panel.detailChip then panel.detailChip:Hide() end
  if panel.detailQChip then panel.detailQChip:Hide() end
  if panel.detailQLabel then panel.detailQLabel:Hide() end
  if panel.detailText then panel.detailText:Hide() end
  if panel.detailName then panel.detailName:SetText("") end
  if panel.detailHint then panel.detailHint:Show() end
  if panel.detailBody then panel.detailBody:SetHeight(40) end
  if panel.detailScroll then panel.detailScroll:SetVerticalScroll(0); panel.detailScroll:UpdateScrollChildRect() end
end

function Dashboard.OpenTab(key)
  ns.db.expanded = true
  if panel then Dashboard.Select(key); Dashboard.ApplyMode(); Dashboard.Show() end
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
    Dashboard.ClearDetail()
    Widgets.StyleHeader(panel.detailHdr, desc.detailTitle or L["Item Details"], DETAIL_W)
    panel.detailHint:SetText(desc.detailHint or L["Hover an item to preview it here."])
  end
  if desc.onShow then desc.onShow() end
  for _, b in ipairs(navButtons) do setNavActive(b, b.key == desc.key) end
  Dashboard.Refresh()
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------
function Dashboard.Refresh()
  if not panel then return end
  local snap, verdict = getContext()
  updateHeader(snap, verdict)
  notifyTransitions(snap, verdict)

  local r, g, b = S.classColor(snap.cls)

  if not ns.db.expanded then
    -- COMPACT
    nav:Hide(); host:Hide(); panel.navDiv:Hide()
    for _, d in ipairs(pages) do if d.frame then d.frame:Hide() end end
    showCompact(compact, true)
    panel:SetWidth(WIDTH_COMPACT)
    local h = layoutCompact(compact, snap, r, g, b)
    panel:SetHeight(CONTENT_TOP + h)
    panel:SetShown(shouldShow)
    return
  end

  -- EXPANDED (tabbed) — FIXED window size, content scrolls
  showCompact(compact, false)
  nav:Show(); host:Show(); panel.navDiv:Show()
  panel:SetWidth(WIDTH_EXPANDED)
  panel:SetHeight(PANEL_H_EXPANDED)

  local desc = pagesByKey[activeKey] or pages[1]
  local detailOn = desc and desc.detail or false
  panel.detail:SetShown(detailOn)
  panel.detailDiv:SetShown(detailOn)
  host:SetWidth(scrollWidth(detailOn))

  if desc then
    if not desc.frame and desc.build then desc.frame = desc.build(host) end
    if desc.frame then
      if host:GetScrollChild() ~= desc.frame then host:SetScrollChild(desc.frame) end
      desc.frame:Show()
      if desc.refresh then desc.refresh(desc.frame, { snap = snap, verdict = verdict, width = scrollWidth(detailOn), r = r, g = g, b = b }) end
      host:UpdateScrollChildRect()
    end
  end
  if detailOn then
    if panel._detailAchv then renderAchvDetail()
    elseif panel._detailQuest then renderQuestDetail()
    elseif panel._detailID then renderItemDetail() end
  end
  -- Hide the scrollbar entirely when the page fits (no stray arrows).
  local sb = host.ScrollBar
  if sb then sb:SetShown((host:GetVerticalScrollRange() or 0) > 1) end
  panel:SetShown(shouldShow)
end

return Dashboard
