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
local L = ns.L

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
    if ns.Dashboard and ns.Dashboard.ShowItemDetail then
      ns.Dashboard.ShowItemDetail(type(cached) == "string" and cached or id, pending)
    end

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

local function getSections(snap)
  -- Checked before cached data: turning sharing off stops the feed but we may still
  -- hold their last bags, so the opt-out message must win over a stale list.
  if not ns.PartnerShares("inventory") then
    return { fullPage = { text = "|cff808080" .. string.format(L["%s has turned off sharing their inventory."], ns.Util.PartnerName(L["Your partner"])) .. "|r" } }
  end

  -- Not paired yet: prompt to pair rather than spin forever on bags that won't come.
  if ns.state.partner == nil then
    return { fullPage = { text = "|cff808080" .. L["Pair with your partner to compare inventory."] .. "|r" } }
  end

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
  build = build, refresh = refresh,
  onShow = function() if ns.Comm and ns.Comm.RequestInventory then ns.Comm.RequestInventory() end end,
})
