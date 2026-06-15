--[[ UI/Pages/Equipment.lua
  Equipment page: the partner's gear health (chip-row layout).
]]

local addonName, ns = ...
local S = ns.UI.Shared

local build, refresh = S.makeRowPage(function(snap)
  local rows = {}
  if (snap.ilvl or 0) > 0 then
    rows[#rows + 1] = { icon = S.I_GEAR, label = "Item level", value = "|cffffd100" .. snap.ilvl .. "|r" }
  end
  if snap.dur then
    local slot = snap.durSlot and ns.Snapshot.SLOT_NAMES[snap.durSlot]
    local low = (snap.durLowN or 0) > 0 and ("   |cffff8000" .. snap.durLowN .. " low|r") or ""
    rows[#rows + 1] = { icon = S.ICON.durability, label = "Durability", value = snap.dur .. "%" .. (slot and (" |cff808080(" .. slot .. ")|r") or "") .. low }
  end
  do
    local val
    if (snap.enchMask or 0) > 0 then
      local names = {}
      for i, slot in ipairs(ns.Snapshot.ENCHANT_SLOTS) do
        if bit.band(snap.enchMask, 2 ^ (i - 1)) ~= 0 then names[#names + 1] = ns.Snapshot.SLOT_NAMES[slot] or ("slot" .. slot) end
      end
      val = "|cffff8000" .. table.concat(names, ", ") .. "|r"
    else
      val = "|cff44ff44all present|r"
    end
    rows[#rows + 1] = { icon = S.I_GEAR, label = "Enchants", value = val }
  end
  rows[#rows + 1] = { icon = S.I_GEAR, label = "Sockets",
    value = (snap.gemMiss or 0) > 0 and ("|cffff8000" .. snap.gemMiss .. " empty|r") or "|cff44ff44none empty|r" }

  return {
    { title = "Gear", rows = rows },
    { title = "Coming soon", text = "Full equipment inspection — every slot with item level, enchant and gem detail, and upgrade suggestions." },
  }
end)

ns.Dashboard.RegisterPage({ key = "equipment", label = "Equipment", order = 5, build = build, refresh = refresh })
