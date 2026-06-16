--[[ InvSync.lua
  Scans the player's own bags into a compact item list and (de)serializes it for
  the chunked INV comm message. Only the partner's request turns on resending.

  Two-phase design (load speed): the bulk INV feed carries only bare itemIDs +
  counts, which keeps the chunk stream tiny so the page paints fast. That's enough
  for the list view (icon/category from GetItemInfoInstant, name/quality from the
  itemID). The heavy compact item STRING (item:id:...:bonusIDs) — needed only for
  the hover detail's correct upgraded item level / stats — is fetched on demand,
  one item at a time, via Comm's INVITEMREQ/INVITEM pair (ResolveItemString below).
]]

local addonName, ns = ...

local InvSync = {}
ns.InvSync = InvSync

InvSync.partnerWantsInv = false
-- Partner's full item strings, resolved on demand: [itemID] = "item:id:...:bonusIDs".
InvSync.detailCache = {}
local MAX_ITEMS = 150

-- Extract a compact item string from a hyperlink, trimming trailing empty fields.
local function compactItemString(link)
  local s = link:match("|H(item[%-?%d:]+)|h")
  if not s then return nil end
  s = s:gsub(":+$", "")           -- trim trailing colons
  s = s:gsub("(:0)+$", "")        -- trim trailing :0 groups (consumables/reagents)
  return s
end

-- Aggregate every normal-bag item into { {id=itemID, count=}, ... } (quick scan).
function InvSync.Scan()
  local agg = {}
  if not (C_Container and C_Container.GetContainerNumSlots) then return {} end
  local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
  for bag = (BACKPACK_CONTAINER or 0), last do
    local slots = C_Container.GetContainerNumSlots(bag) or 0
    for s = 1, slots do
      local info = C_Container.GetContainerItemInfo(bag, s)
      if info and info.itemID then
        agg[info.itemID] = (agg[info.itemID] or 0) + (info.stackCount or 1)
      end
    end
  end
  local list = {}
  for id, count in pairs(agg) do list[#list + 1] = { id = id, count = count } end
  return list
end

-- Wire format: "<itemID>*<count>" entries joined by ",". IDs are digits only, so
-- "," and "*" are safe delimiters.
function InvSync.Encode()
  local list = InvSync.Scan()
  local parts = {}
  for i = 1, math.min(#list, MAX_ITEMS) do parts[i] = list[i].id .. "*" .. list[i].count end
  return table.concat(parts, ",")
end

function InvSync.Decode(str)
  local list = {}
  for entry in (str or ""):gmatch("[^,]+") do
    local id, count = entry:match("^(%d+)%*(%d+)$")
    if id then list[#list + 1] = { id = tonumber(id), count = tonumber(count) } end
  end
  ns.state.partner = ns.state.partner or {}
  ns.state.partner.inv = list
end

-- Resolve one itemID to its full compact string (with bonus IDs) from OUR bags, to
-- answer a partner's on-demand detail request. First matching stack wins; if the
-- partner holds two upgraded items sharing an itemID this picks one (rare in bags).
function InvSync.ResolveItemString(id)
  id = tonumber(id)
  if not id or not (C_Container and C_Container.GetContainerNumSlots) then return nil end
  local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
  for bag = (BACKPACK_CONTAINER or 0), last do
    local slots = C_Container.GetContainerNumSlots(bag) or 0
    for s = 1, slots do
      local info = C_Container.GetContainerItemInfo(bag, s)
      if info and info.itemID == id and info.hyperlink then
        return compactItemString(info.hyperlink)
      end
    end
  end
  return nil
end

-- Cache a partner's resolved item string and let the open detail pane upgrade in place.
function InvSync.StoreItemDetail(id, str)
  id = tonumber(id)
  if not id or not str or str == "" then return end
  InvSync.detailCache[id] = str
  if ns.Dashboard and ns.Dashboard.OnItemDetailArrived then
    ns.Dashboard.OnItemDetailArrived(id, str)
  end
end

-- A fresh feed invalidates cached strings (counts/upgrades may have changed).
function InvSync.ClearDetailCache()
  wipe(InvSync.detailCache)
end

-- Resend (debounced) when our bags change AND the partner is currently viewing.
local RESEND_DELAY = 3   -- seconds to coalesce a burst of bag updates into one send
local pending = false
local function onBagUpdate()
  if not InvSync.partnerWantsInv or pending then return end
  pending = true
  C_Timer.After(RESEND_DELAY, function()
    pending = false
    if ns.Comm and ns.Comm.SendInventory then ns.Comm.SendInventory() end
  end)
end
ns:RegisterEvent("BAG_UPDATE_DELAYED", onBagUpdate)

return InvSync
