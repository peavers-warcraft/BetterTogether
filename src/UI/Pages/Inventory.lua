--[[ UI/Pages/Inventory.lua
  Inventory page: the partner's bags as a categorized chip list. The feed is
  itemID-only (fast first load), which is all the list needs: icon + category from
  GetItemInfoInstant, name/quality from the itemID (both synchronous; names resolve
  lazily via the 2s refresh). The hover detail wants the partner's *full* item
  string (bonus IDs → correct upgraded ilvl/stats), so we fetch that one item on
  demand when its row is hovered or clicked (see the detail controller below).
  Requests a fresh feed from the partner on tab open.
]]

local addonName, ns = ...
local S = ns.UI.Shared
local Theme = ns.UI.Theme
local DP = ns.UI.DetailPane
local L = ns.L

ns.Pages = ns.Pages or {}
local M = {}
ns.Pages.Inventory = M

-- Partner's on-demand item strings. DETAIL[id] is one of: a string (resolved full
-- "item:…" with bonus IDs), the boolean true (a request is in flight), or nil
-- (untouched). InvSync mutates/wipes this same table, so the reference stays live
-- across feeds and ClearDetailCache resets both states together — nothing leaks.
local DETAIL = ns.InvSync and ns.InvSync.detailCache or {}
local FETCH_DELAY = 0.20      -- s; debounce so skimming the list doesn't spray requests
local REQUEST_TIMEOUT = 5     -- s; free the gate if a reply never lands (dropped, or the
                             -- partner no longer holds the item) so it can't wedge
local fetchTimer             -- pending debounced detail request
local inFlightID             -- the one outstanding request's itemID, or nil
local inFlightTimeout        -- backstop timer that frees the gate if no reply arrives
local wantID                 -- itemID the user is currently interested in (latest hover)

-- Only gear (weapons/armor) has an item level that bonus IDs can shift, so it's the
-- only case where the base tooltip would mislead before the full string arrives.
local function isGear(id)
  local _, _, _, _, _, classID = GetItemInfoInstant(id)
  return classID == 2 or classID == 4
end

local function needsFetch(id)
  return type(id) == "number" and type(DETAIL[id]) ~= "string" and isGear(id)
end

-- Send the partner one detail request and arm the single-in-flight gate. Guards on
-- DETAIL so we never re-ask for something cached or already requested. The timeout
-- frees the gate (and un-marks the item, so a later hover can retry) if no reply lands.
local function sendRequest(id)
  if DETAIL[id] ~= nil then return end
  DETAIL[id] = true            -- mark in flight (cleared by next feed or reply)
  inFlightID = id
  if inFlightTimeout then inFlightTimeout:Cancel() end
  inFlightTimeout = C_Timer.NewTimer(REQUEST_TIMEOUT, function()
    inFlightTimeout = nil
    if inFlightID ~= id then return end
    inFlightID = nil
    if DETAIL[id] == true then DETAIL[id] = nil end   -- never answered; allow a retry
    if wantID and wantID ~= id and needsFetch(wantID) then sendRequest(wantID) end
  end)
  ns.Comm.RequestItemDetail(id)
end

-- A detail reply landed (for any id). Free the gate, then — if the user has since
-- moved on to a still-unresolved item — fetch that one now. So rapid browsing only
-- ever chases the item you've settled on, not every row the cursor crossed: the
-- request for an item you've already left is effectively cancelled (we just stop
-- waiting on it and never send the ones for the rows in between).
local function onDetailResolved(id)
  if inFlightID ~= tonumber(id) then return end
  inFlightID = nil
  if inFlightTimeout then inFlightTimeout:Cancel(); inFlightTimeout = nil end
  if wantID and needsFetch(wantID) then sendRequest(wantID) end
end
if ns.InvSync then ns.InvSync.onDetailResolved = onDetailResolved end

-- ---------------------------------------------------------------------------
-- Item detail renderer (custom, non-tooltip — styled as part of the addon). Draws
-- into the shared detail pane (ns.UI.DetailPane). Reads the page-owned target state
-- (shownItemID / shownPending) so a re-render after the partner's full string lands
-- picks up the upgrade without re-clicking.
-- ---------------------------------------------------------------------------
local shownItemID, shownPending

local function renderItemDetail()
  local id = shownItemID
  if not id then return end
  local icon = (select(5, GetItemInfoInstant(id))) or 134400
  DP.chip.icon:SetTexture(icon); DP.chip:Show()

  -- Awaiting the partner's full item string: show the (correct) name + a loading
  -- note rather than the base item's stats, so the item level doesn't visibly jump
  -- once the upgraded string lands.
  if shownPending then
    local nm, _, quality = GetItemInfo(id)
    DP.name:SetText(nm or (L["item:"] .. tostring(id)))
    local qr, qg, qb = Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3]
    local qc = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if qc then qr, qg, qb = qc.r or qr, qc.g or qg, qc.b or qb end
    DP.name:SetTextColor(qr, qg, qb)
    DP.qchip:Hide(); DP.qlabel:Hide()
    local sp = DP.StartSpinner(-66)
    DP.text:ClearAllPoints()
    DP.text:SetJustifyH("CENTER")
    if sp then DP.text:SetPoint("TOP", sp, "BOTTOM", 0, -14)
    else DP.text:SetPoint("TOPLEFT", DP.body, "TOPLEFT", 2, -60) end
    DP.text:SetText(Theme.C.muted2 .. string.format(L["Loading %s's item details…"], ns.Util.PartnerName(L["your partner"])) .. "|r")
    DP.text:Show()
    DP.body:SetHeight(150)
    if DP.scroll then DP.scroll:SetVerticalScroll(0); DP.scroll:UpdateScrollChildRect() end
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
    DP.name:SetText(Theme.C.muted2 .. L["Loading…"] .. "|r")
    DP.text:Hide(); DP.qchip:Hide(); DP.qlabel:Hide()
    DP.StartSpinner(-58)
    DP.body:SetHeight(110); if DP.scroll then DP.scroll:UpdateScrollChildRect() end
    return
  end

  DP.StopSpinner()
  DP.text:SetJustifyH("LEFT")
  local function surface(t) if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(t) end end
  surface(data)
  local l1 = data.lines[1]; surface(l1)
  DP.name:SetText((l1 and l1.leftText) or (L["item:"] .. id))
  local qr, qg, qb = Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3]
  if l1 and l1.leftColor and l1.leftColor.GetRGB then qr, qg, qb = l1.leftColor:GetRGB() end
  DP.name:SetTextColor(qr, qg, qb)

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
  DP.text:ClearAllPoints()
  DP.text:SetPoint("TOPLEFT", DP.body, "TOPLEFT", 2, -BASE)
  DP.text:SetText(table.concat(parts, "\n"))
  DP.text:Show()

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
  local contentH = 60 + (DP.text:GetStringHeight() or 0)
  if qAtlas then
    DP.qchip.icon:SetTexCoord(0, 1, 0, 1); DP.qchip.icon:SetAtlas(qAtlas)
    DP.qchip:ClearAllPoints()
    DP.qchip:SetPoint("TOPLEFT", DP.text, "BOTTOMLEFT", 0, -10)
    DP.qchip:Show()
    DP.qlabel:SetText(L["Quality "] .. Theme.C.white .. L["Tier "] .. q .. "|r"); DP.qlabel:Show()
    contentH = contentH + 10 + 30
  else
    DP.qchip:Hide(); DP.qlabel:Hide()
  end
  DP.body:SetHeight(contentH + 14)
  if DP.scroll then DP.scroll:UpdateScrollChildRect() end
end

-- Show an item in the detail pane. `pending` means this is the base item shown while
-- we await the partner's full string; renderItemDetail then shows a "loading"
-- placeholder instead of the (about to change) base item level.
local function showItemDetail(id, pending)
  shownItemID = id
  shownPending = pending and true or nil
  DP.Render(renderItemDetail)
end

-- A partner's full item string (bonus IDs) just arrived (InvSync calls this). If the
-- detail pane is currently showing this item (matched by base itemID), upgrade it in
-- place so the correct ilvl/stats render without the user re-clicking.
function M.OnItemDetailArrived(id, itemString)
  if not (DP.IsActiveRenderer(renderItemDetail) and DP.IsShown()) then return end
  local cur = shownItemID
  local curID = type(cur) == "number" and cur or tonumber(tostring(cur):match("item:(%d+)"))
  if curID == tonumber(id) then
    shownItemID = itemString
    shownPending = nil
    renderItemDetail()
  end
end

-- The base item's data finished loading: re-render in place if we're still showing it.
ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
  if DP.IsActiveRenderer(renderItemDetail) and DP.IsShown() then renderItemDetail() end
end)

-- Hover-preview + click-lock detail controller (S.makePinController). Our show()
-- renders the item — the resolved upgrade if cached, else the base item (a "loading"
-- placeholder for gear until the full string lands, so its item level doesn't jump
-- base → upgraded with no explanation) — and fetches the partner's full string on
-- demand: immediately on a lock (click), debounced on a preview (hover). Only one
-- request is ever outstanding (see sendRequest/onDetailResolved); a fresh hover just
-- updates wantID, and the in-flight reply hands off to whatever we've settled on.
local detail = S.makePinController({
  show = function(id, _, mode)
    if fetchTimer then fetchTimer:Cancel(); fetchTimer = nil end
    local cached = DETAIL[id]
    local pending = type(cached) ~= "string" and type(id) == "number" and isGear(id)
    showItemDetail(type(cached) == "string" and cached or id, pending)

    if type(id) ~= "number" or cached ~= nil then wantID = nil; return end
    if not (ns.Comm and ns.Comm.RequestItemDetail) then return end
    wantID = id
    if inFlightID then return end   -- one at a time; the reply handler will pick up wantID
    if mode == "lock" then
      sendRequest(id)
    else
      fetchTimer = C_Timer.NewTimer(FETCH_DELAY, function()
        fetchTimer = nil
        if wantID == id and not inFlightID and DETAIL[id] == nil then sendRequest(id) end
      end)
    end
  end,
})

local ORDER = { "Consumables", "Reagents", "Quest Items", "Equipment", "Other" }
local function bucketFor(classID)
  if classID == 0 then return "Consumables"
  elseif classID == 7 or classID == 5 or classID == 3 then return "Reagents"
  elseif classID == 12 then return "Quest Items"
  elseif classID == 2 or classID == 4 then return "Equipment"
  else return "Other" end
end

-- Partner opt-out / no-partner are handled by the shell's shared full-width empty state
-- (ns.UI.EmptyState) before this page renders — opt-out via the descriptor's emptyState
-- hook below, no-partner centrally. So getSections only ever runs with a sharing partner.
local function emptyState()
  -- Checked before cached data: turning sharing off stops the feed but we may still
  -- hold their last bags, so the opt-out message must win over a stale list.
  if not ns.PartnerShares("inventory") then
    return { title = L["Inventory sharing is off"],
      sub = string.format(L["%s has turned off sharing their inventory."], ns.Util.PartnerName(L["Your partner"])) }
  end
end

local function getSections(snap)
  local inv = ns.state.partner.inv or {}
  if #inv == 0 then
    return { fullPage = { spinner = true,
      text = "|cffd0d0d0" .. string.format(L["Waiting for %s's bags…"], ns.Util.PartnerName(L["your partner"])) .. "|r\n|cff808080" .. L["A request is sent when you open this tab."] .. "|r" } }
  end

  local groups = {}
  for _, it in ipairs(inv) do
    local id = it.id or it.link   -- feed is itemID-only now; tolerate legacy links
    local _, _, _, _, icon, classID = GetItemInfoInstant(id)
    icon = icon or 134400
    local cat = bucketFor(classID or 15)
    local name, _, quality = GetItemInfo(id)
    if not name then name = L["item:"] .. tostring(id) end
    local nm = name
    if quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
      nm = (ITEM_QUALITY_COLORS[quality].hex or "") .. name .. "|r"
    end
    groups[cat] = groups[cat] or {}
    table.insert(groups[cat], {
      icon = icon, label = nm, value = "|cffffffffx" .. it.count .. "|r", _s = name,
      selected = detail.isLocked(id),
      onEnter = function() detail.preview(id) end,
      onLeave = function() detail.leave() end,
      onClick = function() detail.lock(id) end,
    })
  end

  local sections = {}
  for _, cat in ipairs(ORDER) do
    if groups[cat] then
      table.sort(groups[cat], function(a, b) return a._s < b._s end)
      sections[#sections + 1] = { title = L[cat] .. "  |cff707070(" .. #groups[cat] .. ")|r", rows = groups[cat] }
    end
  end
  return sections
end

local build, refresh = S.makeRowPage(getSections)

ns.Dashboard.RegisterPage({
  key = "inventory", label = L["Inventory"], order = 6, detail = true,
  build = build, refresh = refresh, emptyState = emptyState,
  onShow = function() if ns.Comm and ns.Comm.RequestInventory then ns.Comm.RequestInventory() end end,
})
