--[[ Consumables.lua
  spellID tables for current-tier flask / food / rune / weapon-enchant buffs,
  plus helpers to test the player's own auras against them (spec §4.4, §7).

  These are AURA spellIDs (the buff applied), NOT item IDs. Many flasks/foods use
  a single shared buff spellID across ranks, so a small table covers a whole tier.

  [VERIFY IN-CLIENT] (spec §11.4): the spellIDs below are placeholders / known
  values from prior tiers and MUST be confirmed for the current Midnight 12.0
  tier in-client. Use `/dump C_UnitAuras.GetAuraDataByIndex("player", i)` while a
  buff is active to read the live spellId, then add it here. The detection logic
  is complete and correct; only the numbers need verifying.
]]

local addonName, ns = ...

local Consumables = {}
ns.Consumables = Consumables

-- ---------------------------------------------------------------------------
-- spellID sets. Stored as { [spellID] = true } for O(1) lookup.
-- Keep the human-readable list in the array part for maintenance; we fold it
-- into a lookup set at the bottom of the file.
-- ---------------------------------------------------------------------------

-- Flasks / phials (the long-duration primary-stat consumable).
local FLASK_IDS = {
  -- TODO[VERIFY IN-CLIENT]: Midnight 12.0 flask/phial buff spellIDs.
  -- Examples from prior tiers kept as fallbacks so detection isn't empty:
  431971,  -- Flask of Tempered Versatility (TWW placeholder)
  431972,  -- Flask of Tempered Swiftness
  431973,  -- Flask of Tempered Mastery
  431974,  -- Flask of Tempered Aggression
  432021,  -- Flask of Alchemical Chaos
}

-- Well Fed / food buffs. A single "Well Fed" aura often covers many foods.
local FOOD_IDS = {
  -- TODO[VERIFY IN-CLIENT]: Midnight 12.0 Well Fed buff spellIDs.
  462210,  -- Well Fed (feast, TWW placeholder)
  461957,  -- Well Fed (stat food placeholder)
  104280,  -- Generic "Well Fed" fallback (older shared id)
}

-- Augment runes (the per-character augment buff).
local RUNE_IDS = {
  -- TODO[VERIFY IN-CLIENT]: Midnight 12.0 augment rune buff spellID.
  453250,  -- Crystallized Augment Rune (TWW placeholder)
  393438,  -- Draconic Augment Rune (prior tier fallback)
}

-- Temporary weapon enhancements that show up as *auras* (e.g. some oils/stones
-- apply a player buff). The primary weapon-enchant check uses GetWeaponEnchantInfo()
-- in SelfState; this set is a secondary aura-based signal.
local WEAPON_AURA_IDS = {
  -- TODO[VERIFY IN-CLIENT]: weapon buff aura spellIDs if any apply as player auras.
}

-- ---------------------------------------------------------------------------
-- Build lookup sets
-- ---------------------------------------------------------------------------
local function toSet(list)
  local set = {}
  for _, id in ipairs(list) do set[id] = true end
  return set
end

Consumables.flask  = toSet(FLASK_IDS)
Consumables.food   = toSet(FOOD_IDS)
Consumables.rune   = toSet(RUNE_IDS)
Consumables.wpnAura = toSet(WEAPON_AURA_IDS)

-- Allow other layers (e.g. a future settings importer) to extend a category.
function Consumables.Add(category, spellID)
  local set = Consumables[category]
  if set then set[spellID] = true end
end

-- ---------------------------------------------------------------------------
-- Aura scanning (own player only — restriction-proof, spec §6.1)
-- ---------------------------------------------------------------------------

-- Returns true if a value came back "secret" (Midnight Secret Values, §9).
-- We never do arithmetic/concat on secret values.
local function isSecret(v)
  return type(issecretvalue) == "function" and issecretvalue(v)
end

-- Scan the player's helpful auras once and return booleans for each category.
-- Uses AuraUtil.ForEachAura when available (modern, handles paging), else falls
-- back to a manual C_UnitAuras index loop.
function Consumables.ScanPlayer()
  local found = { flask = false, food = false, rune = false, wpnAura = false }

  local function consider(aura)
    if not aura then return end
    local spellId = aura.spellId
    if spellId == nil or isSecret(spellId) then return end
    if Consumables.flask[spellId]   then found.flask = true end
    if Consumables.food[spellId]    then found.food = true end
    if Consumables.rune[spellId]    then found.rune = true end
    if Consumables.wpnAura[spellId] then found.wpnAura = true end
  end

  if AuraUtil and AuraUtil.ForEachAura then
    -- usePackedAura = true => callback receives the aura data table.
    AuraUtil.ForEachAura("player", "HELPFUL", nil, function(aura)
      consider(aura)
      return false -- keep iterating
    end, true)
  elseif C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
    for i = 1, 60 do
      local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
      if not aura then break end
      consider(aura)
    end
  end

  return found
end

-- ---------------------------------------------------------------------------
-- Supply stock (bag item counts) for the gear/supplies dashboard section.
-- [VERIFY IN-CLIENT] (§11.4): item IDs are current/known placeholders; confirm.
-- ---------------------------------------------------------------------------
local POTION_IDS = {
  -- combat potions (healing + primary-stat) — TODO confirm Midnight tier IDs
  211880,  -- Algari Healing Potion (TWW placeholder)
  212265,  -- Tempered Potion (TWW placeholder)
}
local HEALTHSTONE_IDS = {
  5512,    -- Healthstone (long-stable item id)
}
local FEAST_IDS = {
  -- portable food / feasts the player might carry — TODO confirm
  222732,  -- placeholder feast
}

local function sumCount(ids)
  local total = 0
  if not (C_Item and C_Item.GetItemCount) then return 0 end
  for _, id in ipairs(ids) do
    total = total + (C_Item.GetItemCount(id) or 0)
  end
  return total
end

-- Returns pots, healthstones, feastFood counts carried in bags.
function Consumables.CountSupplies()
  return sumCount(POTION_IDS), sumCount(HEALTHSTONE_IDS), sumCount(FEAST_IDS)
end

return Consumables
