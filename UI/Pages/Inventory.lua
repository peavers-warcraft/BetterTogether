--[[ UI/Pages/Inventory.lua
  Inventory page: the partner's bags as a categorized chip list. Item icon +
  category come from GetItemInfoInstant (synchronous); names/quality resolve
  lazily (the 2s page refresh picks them up once the client loads them).
  Requests a fresh feed from the partner whenever the tab is opened.
]]

local addonName, ns = ...
local S = ns.UI.Shared

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
    return { { title = "Inventory", text = "|cff808080Waiting for your partner's bags… (a request is sent when you open this tab).|r" } }
  end

  local groups = {}
  for _, it in ipairs(inv) do
    local key = it.link or it.id
    local _, _, _, _, icon, classID = GetItemInfoInstant(key)
    icon = icon or 134400
    local cat = bucketFor(classID or 15)
    local name, _, quality = GetItemInfo(key)
    if not name then name = key end
    local nm = name
    if quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
      nm = (ITEM_QUALITY_COLORS[quality].hex or "") .. name .. "|r"
    end
    groups[cat] = groups[cat] or {}
    table.insert(groups[cat], {
      icon = icon, label = nm, value = "|cffffffffx" .. it.count .. "|r", _s = name,
      onEnter = function() if ns.Dashboard and ns.Dashboard.ShowItemDetail then ns.Dashboard.ShowItemDetail(key) end end,
    })
  end

  local sections = {}
  for _, cat in ipairs(ORDER) do
    if groups[cat] then
      table.sort(groups[cat], function(a, b) return a._s < b._s end)
      sections[#sections + 1] = { title = cat .. "  |cff707070(" .. #groups[cat] .. ")|r", rows = groups[cat] }
    end
  end
  return sections
end

local build, refresh = S.makeRowPage(getSections)

ns.Dashboard.RegisterPage({
  key = "inventory", label = "Inventory", order = 6, detail = true,
  build = build, refresh = refresh,
  onShow = function() if ns.Comm and ns.Comm.RequestInventory then ns.Comm.RequestInventory() end end,
})
