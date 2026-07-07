--[[ Consumables.lua
  spellID tables for current-tier flask / food / rune / weapon-enchant buffs,
  plus helpers to test the player's own auras against them (spec §4.4, §7).

  These are AURA spellIDs (the buff applied), NOT item IDs. Many flasks/foods use
  a single shared buff spellID across ranks, so a small table covers a whole tier.

  The live per-tier data comes from PeaversConsumablesData (hard dependency),
  imported at PLAYER_LOGIN — see the import section at the bottom. The hardcoded
  lists below are only seeds/fallbacks so detection isn't empty if the data addon
  ever ships without a category. ScanPlayer additionally matches stable buff
  *names* (NAME_HINTS below) as a last-resort tier-proof net.
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
  -- Fallback seeds only — live tier IDs are imported from PeaversConsumablesData:
  431971,  -- Flask of Tempered Versatility (TWW placeholder)
  431972,  -- Flask of Tempered Swiftness
  431973,  -- Flask of Tempered Mastery
  431974,  -- Flask of Tempered Aggression
  432021,  -- Flask of Alchemical Chaos
}

-- Well Fed / food buffs. A single "Well Fed" aura often covers many foods.
local FOOD_IDS = {
  -- Well Fed aura IDs aren't derivable from item data (the item's use-spell is
  -- the eating channel, not the buff), so food detection leans on NAME_HINTS:
  462210,  -- Well Fed (feast, TWW placeholder)
  461957,  -- Well Fed (stat food placeholder)
  104280,  -- Generic "Well Fed" fallback (older shared id)
}

-- Augment runes (the per-character augment buff).
local RUNE_IDS = {
  -- Fallback seeds only — live tier IDs are imported from PeaversConsumablesData:
  453250,  -- Crystallized Augment Rune (TWW placeholder)
  393438,  -- Draconic Augment Rune (prior tier fallback)
}

-- Temporary weapon enhancements that show up as *auras* (e.g. some oils/stones
-- apply a player buff). The primary weapon-enchant check uses GetWeaponEnchantInfo()
-- in SelfState; this set is a secondary aura-based signal.
local WEAPON_AURA_IDS = {
  -- TODO[VERIFY IN-CLIENT]: weapon buff aura spellIDs if any apply as player auras.
}

-- Name-substring fallback. The spellID sets above are precise but go stale every
-- patch (Blizzard re-IDs consumables); the buff *names* are far more stable. When
-- an aura's id isn't in our sets we still catch the common cases by name, so a
-- fresh tier keeps working before anyone updates the numbers. enUS-oriented — non-
-- English clients fall back to the ID sets (and can extend via Consumables.Add).
local NAME_HINTS = {
  food  = { "Well Fed" },
  flask = { "Flask", "Phial" },
  rune  = { "Augment Rune", "Augmented" },
}

-- Exact aura names imported from PeaversConsumablesData at login. GetItemSpell
-- returns the client-locale spell name, so unlike the enUS NAME_HINTS these
-- exact matches work on any locale.
local EXACT_NAMES = {
  flask = {},
  rune  = {},
}

local function nameMatches(name, hints)
  for _, h in ipairs(hints) do
    if name:find(h, 1, true) then return true end   -- plain (non-pattern) substring
  end
  return false
end

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

local GetTime = GetTime

-- Returns true if a value came back "secret" (Midnight Secret Values, §9).
-- We never do arithmetic/concat on secret values.
local function isSecret(v)
  return type(issecretvalue) == "function" and issecretvalue(v)
end

-- Seconds left on an aura, from its absolute (GetTime-based) expiration. Returns 0
-- when the buff has no duration (expirationTime 0), is secret, or already lapsed —
-- callers treat 0 as "active, but no countdown to show".
local function auraRemaining(aura)
  local exp = aura.expirationTime
  if exp == nil or isSecret(exp) or exp == 0 then return 0 end
  return math.max(0, exp - GetTime())
end

-- Scan the player's helpful auras once and return booleans for each category, plus
-- the remaining seconds (<cat>Rem) of the matched buff so partners can show a live
-- countdown. Uses AuraUtil.ForEachAura when available (modern, handles paging), else
-- falls back to a manual C_UnitAuras index loop.
function Consumables.ScanPlayer()
  local found = { flask = false, food = false, rune = false, wpnAura = false }

  local function consider(aura)
    if not aura then return end
    local rem = auraRemaining(aura)
    -- Record a category hit and keep the longest remaining we've seen for it (a
    -- character can carry two matching auras; the longer one is the live buff).
    local function hit(cat)
      found[cat] = true
      local key = cat .. "Rem"
      if rem > (found[key] or 0) then found[key] = rem end
    end
    local spellId = aura.spellId
    if spellId ~= nil and not isSecret(spellId) then
      if Consumables.flask[spellId]   then hit("flask") end
      if Consumables.food[spellId]    then hit("food") end
      if Consumables.rune[spellId]    then hit("rune") end
      if Consumables.wpnAura[spellId] then hit("wpnAura") end
    end
    -- Tier-proof name fallback (see NAME_HINTS): only fill gaps the IDs missed.
    local name = aura.name
    if type(name) == "string" and not isSecret(name) and name ~= "" then
      if not found.food  and nameMatches(name, NAME_HINTS.food)  then hit("food")  end
      if not found.flask and (EXACT_NAMES.flask[name] or nameMatches(name, NAME_HINTS.flask)) then hit("flask") end
      if not found.rune  and (EXACT_NAMES.rune[name]  or nameMatches(name, NAME_HINTS.rune))  then hit("rune")  end
    end
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
-- Potion/food item IDs are extended from PeaversConsumablesData at login; the
-- entries below are fallback seeds.
-- ---------------------------------------------------------------------------
local POTION_IDS = {
  211880,  -- Algari Healing Potion (TWW seed)
  212265,  -- Tempered Potion (TWW seed)
}
local HEALTHSTONE_IDS = {
  5512,    -- Healthstone (long-stable item id)
}
local FEAST_IDS = {
  222732,  -- feast seed (TWW)
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

-- ---------------------------------------------------------------------------
-- PeaversConsumablesData import (hard dependency, so it loads before us).
-- The data addon publishes curated per-spec item lists (itemID/itemName) that
-- are regenerated every patch, so detection tracks the live tier instead of
-- the hand-pinned seeds above. The lists are ITEM ids; we bridge to aura
-- spellIDs via GetItemSpell: for flasks/phials and augment runes the item's
-- use-spell IS the applied buff (same id and name). Food is skipped for aura
-- purposes (its use-spell is the eating channel, not "Well Fed" — NAME_HINTS
-- covers that) but feeds the supplies count, as do potions.
-- ---------------------------------------------------------------------------

local GetItemSpell = C_Item and C_Item.GetItemSpell

local function forEachSpecID(classID, fn)
  -- Split homes in 12.0.7 (per wow-api's 120007 dump): GetNumSpecializationsForClassID
  -- moved onto C_SpecializationInfo, but GetSpecializationInfoForClassID is still a
  -- bare global. Check both homes for each so the import survives either migrating.
  local getNum  = (C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID)
      or GetNumSpecializationsForClassID
  local getInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoForClassID)
      or GetSpecializationInfoForClassID
  if not (getNum and getInfo) then return end
  for i = 1, getNum(classID) or 0 do
    local specID = getInfo(classID, i)
    if specID then fn(specID) end
  end
end

-- Resolve an item's use-spell to an aura id + localized name. Item data is
-- server-side and usually cold at login, so resolve after the async item load;
-- the sets mutate in place and the next UNIT_AURA rescan picks them up.
local function addAuraFromItem(itemID, cat)
  if not GetItemSpell then return end   -- nothing to resolve with; skip the item request too
  local function resolve()
    local spellName, spellID = GetItemSpell(itemID)
    if spellID then Consumables[cat][spellID] = true end
    if type(spellName) == "string" and spellName ~= "" then
      EXACT_NAMES[cat][spellName] = true   -- cat is always "flask" or "rune" (see handlers)
    end
    -- Cold-cache items resolve after the import pump has finished, so poke the
    -- (coalesced) rescan from here too — a flask active at login must not wait
    -- for the next organic UNIT_AURA to be detected.
    if ns.SelfState and ns.SelfState.MarkDirty then ns.SelfState.MarkDirty() end
  end
  if Item and Item.CreateFromItemID then
    local item = Item:CreateFromItemID(itemID)
    if not item:IsItemEmpty() then
      item:ContinueOnItemLoad(resolve)
      return
    end
  end
  resolve()
end

local function ImportConsumablesData()
  local data = rawget(_G, "PeaversConsumablesData")
  local API = data and data.API
  if not (API and API.GetConsumables) then return end

  -- Union across every class/spec: flasks aren't class-locked and a player may
  -- run an off-spec (or cheaper) consumable, so detection shouldn't care whose
  -- "best list" an item came from.
  local seen = {}
  for _, id in ipairs(POTION_IDS) do seen[id] = true end
  for _, id in ipairs(FEAST_IDS)  do seen[id] = true end

  local handlers = {
    flasks  = function(id) addAuraFromItem(id, "flask") end,
    runes   = function(id) addAuraFromItem(id, "rune") end,
    potions = function(id) POTION_IDS[#POTION_IDS + 1] = id end,
    food    = function(id) FEAST_IDS[#FEAST_IDS + 1] = id end,
  }

  local function importClass(classID)
    forEachSpecID(classID, function(specID)
      for category, handle in pairs(handlers) do
        local items = API.GetConsumables(classID, specID, category)
        if items then
          for _, item in ipairs(items) do
            local id = item.itemID
            if id and not seen[id] then
              seen[id] = true
              handle(id)
            end
          end
        end
      end
    end)
  end

  -- One class per pumped frame instead of all in one login hit — each slice is
  -- small (a dozen GetConsumables calls), but at /reload every addon competes for
  -- the same frames, so stay polite. Detection is name-hint-covered until the
  -- import lands, so the spread is safe.
  local numClasses = (GetNumClasses and GetNumClasses()) or 13
  local co = coroutine.create(function()
    for classID = 1, numClasses do importClass(classID); coroutine.yield() end
  end)
  ns.PumpCoroutine(co, {
    onDone = function(ok, err)
      if not ok then ns:Debug("Consumables import error: " .. tostring(err)) end
      -- The lookup sets just changed under the login-time scan. Recompute + resync
      -- through the normal coalescing path so a flask/rune that was already active
      -- at login is reported correctly now, not on the next organic UNIT_AURA.
      if ns.SelfState and ns.SelfState.MarkDirty then ns.SelfState.MarkDirty() end
    end,
  })
end

ns:RegisterEvent("PLAYER_LOGIN", ImportConsumablesData)

return Consumables
