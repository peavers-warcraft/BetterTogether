--[[ InvSync.lua
  Scans the player's own bags into a compact item list and (de)serializes it for
  the chunked INV comm message. Only the partner's request turns on resending.

  We send each item's compact item STRING (item:id:...:bonusIDs) + count, so the
  receiver can show the correct upgraded item level / stats — a bare itemID only
  resolves the base item (wrong ilvl for upgraded gear). Trailing empty fields are
  trimmed to keep consumables/reagents short.
]]

local addonName, ns = ...

local InvSync = {}
ns.InvSync = InvSync

InvSync.partnerWantsInv = false
local MAX_ITEMS = 150

-- Extract a compact item string from a hyperlink, trimming trailing empty fields.
local function compactItemString(link)
  local s = link:match("|H(item[%-?%d:]+)|h")
  if not s then return nil end
  s = s:gsub(":+$", "")           -- trim trailing colons
  s = s:gsub("(:0)+$", "")        -- trim trailing :0 groups (consumables/reagents)
  return s
end

-- Aggregate every normal-bag item into { {link=itemString, count=}, ... }
function InvSync.Scan()
  local agg = {}
  if not (C_Container and C_Container.GetContainerNumSlots) then return {} end
  local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
  for bag = (BACKPACK_CONTAINER or 0), last do
    local slots = C_Container.GetContainerNumSlots(bag) or 0
    for s = 1, slots do
      local info = C_Container.GetContainerItemInfo(bag, s)
      if info and info.hyperlink then
        local str = compactItemString(info.hyperlink)
        if str then agg[str] = (agg[str] or 0) + (info.stackCount or 1) end
      end
    end
  end
  local list = {}
  for str, count in pairs(agg) do list[#list + 1] = { link = str, count = count } end
  return list
end

-- Wire format: "<itemString>*<count>" entries joined by ",". Item strings contain
-- only digits/colons/minus, so "," and "*" are safe delimiters.
function InvSync.Encode()
  local list = InvSync.Scan()
  local parts = {}
  for i = 1, math.min(#list, MAX_ITEMS) do parts[i] = list[i].link .. "*" .. list[i].count end
  return table.concat(parts, ",")
end

function InvSync.Decode(str)
  local list = {}
  for entry in (str or ""):gmatch("[^,]+") do
    local link, count = entry:match("^(item[%-?%d:]+)%*(%d+)$")
    if link then list[#list + 1] = { link = link, count = tonumber(count) } end
  end
  ns.state.partner = ns.state.partner or {}
  ns.state.partner.inv = list
end

-- Resend (debounced) when our bags change AND the partner is currently viewing.
local pending = false
ns:RegisterEvent("BAG_UPDATE_DELAYED", function()
  if not InvSync.partnerWantsInv or pending then return end
  pending = true
  C_Timer.After(3, function()
    pending = false
    if ns.Comm and ns.Comm.SendInventory then ns.Comm.SendInventory() end
  end)
end)

return InvSync
