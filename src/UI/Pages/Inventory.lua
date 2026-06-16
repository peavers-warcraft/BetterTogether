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
local FETCH_DELAY = 0.20  -- s; debounce so skimming the list doesn't spray requests
local fetchTimer          -- pending debounced detail request

-- Only gear (weapons/armor) has an item level that bonus IDs can shift, so it's the
-- only case where the base tooltip would mislead before the full string arrives.
local function isGear(id)
  local _, _, _, _, _, classID = GetItemInfoInstant(id)
  return classID == 2 or classID == 4
end

-- Hover-preview + click-lock detail controller (S.makePinController). Our show()
-- renders the item — the resolved upgrade if cached, else the base item (a "loading"
-- placeholder for gear until the full string lands, so its item level doesn't jump
-- base → upgraded with no explanation) — and fetches the partner's full string on
-- demand: immediately on a lock (click), debounced on a preview (hover).
local detail = S.makePinController({
  show = function(id, _, mode)
    if fetchTimer then fetchTimer:Cancel(); fetchTimer = nil end
    local cached = DETAIL[id]
    local pending = type(cached) ~= "string" and type(id) == "number" and isGear(id)
    if ns.Dashboard and ns.Dashboard.ShowItemDetail then
      ns.Dashboard.ShowItemDetail(type(cached) == "string" and cached or id, pending)
    end

    if type(id) ~= "number" or cached ~= nil then return end
    if not (ns.Comm and ns.Comm.RequestItemDetail) then return end
    local function fire()
      fetchTimer = nil
      if DETAIL[id] ~= nil then return end   -- landed or requested in the meantime
      DETAIL[id] = true                      -- mark in flight (cleared by next feed)
      ns.Comm.RequestItemDetail(id)
    end
    if mode == "lock" then fire() else fetchTimer = C_Timer.NewTimer(FETCH_DELAY, fire) end
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
  local inv = (ns.db.demoMode and S.demoInv()) or (ns.state.partner and ns.state.partner.inv) or {}
  if #inv == 0 then
    return { { title = L["Inventory"], text = "|cff808080" .. L["Waiting for your partner's bags… (a request is sent when you open this tab)."] .. "|r" } }
  end

  local groups = {}
  for _, it in ipairs(inv) do
    local id = it.id or it.link   -- feed is itemID-only now; tolerate legacy links
    local _, _, _, _, icon, classID = GetItemInfoInstant(id)
    icon = icon or 134400
    local cat = bucketFor(classID or 15)
    local name, _, quality = GetItemInfo(id)
    if not name then name = "item:" .. tostring(id) end
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
