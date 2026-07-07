--[[ UI/Pages/Gear.lua
  Gear page: per-slot enchant + gem-socket comparison for you and your partner —
  the detail behind the Enchants / Gem sockets readiness rows. Your side reads
  live local state (ns.state.self); the partner's arrives in the CARD message
  (enchMask/enchCheck/gs, privacy key "gear").
]]

local addonName, ns = ...
local S = ns.UI.Shared
local Theme = ns.UI.Theme
local L = ns.L
local C = Theme.C

ns.Pages = ns.Pages or {}
local M = {}
ns.Pages.Gear = M

-- Display labels for ENCHANT_SLOTS entries (same order; rings disambiguated —
-- SLOT_NAMES calls both plain "Ring").
local ENCH_LABELS = {
  L["Cloak"], L["Chest"], L["Wrist"], L["Legs"], L["Feet"],
  L["Ring 1"], L["Ring 2"], L["Weapon"], L["Off-hand"],
  L["Head"], L["Shoulder"],
}

-- One side's enchant status for ENCHANT_SLOTS index i, plus whether the slot was
-- evaluated at all. `check` is the evaluated-slot mask; nil (partner on an older
-- build) falls back to treating every slot as evaluated, matching that build's
-- own scan.
local function enchStatus(mask, check, i)
  local flag = 2 ^ (i - 1)
  if check and bit.band(check, flag) == 0 then return C.dim .. L["n/a"] .. "|r", false end
  if bit.band(mask or 0, flag) ~= 0 then return C.danger .. L["missing"] .. "|r", true end
  return C.ready .. L["enchanted"] .. "|r", true
end

-- One side's socket readout for a slot ({filled=, total=} or nil = no such item).
local function socketStatus(e)
  if not e then return C.dim .. "—|r" end
  local empty = math.max(0, (e.total or 0) - (e.filled or 0))
  local txt = (empty > 0 and C.danger or C.ready) .. (e.filled or 0) .. "/" .. (e.total or 0) .. "|r"
  if empty > 0 then txt = txt .. "  " .. C.orange .. empty .. L[" empty"] .. "|r" end
  return txt
end

-- Checked before cached data: a partner who turns gear sharing off may still have
-- an old enchMask on the merged table, so the opt-out state must win over it.
local function emptyState()
  if not ns.PartnerShares("gear") then
    return { title = L["Gear sharing is off"],
      sub = string.format(L["%s has turned off sharing their gear details."], ns.Util.PartnerName(L["Your partner"])) }
  end
end

local function getSections(snap)
  -- No CARD from this partner yet (fresh link, still syncing).
  if snap.enchMask == nil then
    return { fullPage = { spinner = true,
      text = C.soft .. string.format(L["Waiting for %s's gear info…"], ns.Util.PartnerName(L["your partner"])) .. "|r\n"
        .. C.dim .. L["It arrives automatically a few seconds after linking."] .. "|r" } }
  end

  local own = ns.state.self
  local pname = ns.Util.PartnerName(L["Partner"])
  local youPrefix = C.white .. L["You "] .. "|r"
  local partnerPrefix = C.faint .. pname .. " |r"

  -- Enchants: one row per enchantable slot, your status beside theirs. A slot
  -- neither side can enchant right now (cloak/wrist in Midnight, empty off-hand)
  -- would read "n/a / n/a" — skip it rather than pad the list with noise.
  local enchRows = {}
  for i = 1, #ns.Snapshot.ENCHANT_SLOTS do
    local yourStatus, youChecked = enchStatus(own.enchMask, own.enchCheck, i)
    local theirStatus, theyChecked = enchStatus(snap.enchMask, snap.enchCheck, i)
    if youChecked or theyChecked then
      enchRows[#enchRows + 1] = {
        icon = Theme.ICON.enchants, label = ENCH_LABELS[i],
        youText = youPrefix .. yourStatus,
        partnerText = partnerPrefix .. theirStatus,
      }
    end
  end

  -- Sockets: union of both sides' socketed slots, slot order.
  local mine = ns.Snapshot.ParseSockets(own.gs)
  local theirs = snap.gs and ns.Snapshot.ParseSockets(snap.gs) or {}
  local slots, seen = {}, {}
  for slot in pairs(mine) do if not seen[slot] then seen[slot] = true; slots[#slots + 1] = slot end end
  for slot in pairs(theirs) do if not seen[slot] then seen[slot] = true; slots[#slots + 1] = slot end end
  table.sort(slots)

  local sockRows = {}
  for _, slot in ipairs(slots) do
    sockRows[#sockRows + 1] = {
      icon = Theme.ICON.gems, label = ns.Snapshot.SLOT_NAMES[slot] or (L["Slot "] .. slot),
      youText = youPrefix .. socketStatus(mine[slot]),
      partnerText = partnerPrefix .. socketStatus(theirs[slot]),
    }
  end

  -- A partner build without the gs field can only report its total empty count.
  local sockNote
  if snap.gs == nil then
    sockNote = C.dim .. string.format(L["%s is on an older version — per-slot detail unavailable (their empty sockets: %d)."], pname, snap.gemMiss or 0) .. "|r"
  elseif #sockRows == 0 then
    sockNote = C.dim .. L["Neither of you has socketed gear equipped."] .. "|r"
  end

  return {
    { title = L["Enchants"], rows = enchRows },
    { title = L["Gem sockets"], rows = #sockRows > 0 and sockRows or nil, text = sockNote },
  }
end

local build, refresh = S.makeRowPage(getSections)

ns.Dashboard.RegisterPage({
  key = "gear", label = L["Enchants/Gems"], order = 5,
  build = build, refresh = refresh, emptyState = emptyState,
})
