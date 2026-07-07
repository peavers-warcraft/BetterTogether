--[[ SelfState.lua
  Reads the player's OWN out-of-combat state into BetterTogether.self (spec §3, §5, §7).
  All reads are local-player and unrestricted out of combat (self-report, §6.1).

  Two groups of fields, matching the two wire messages:
    SNAP (fast):  dur, durSlot, durLowN, bags, flask, food, wpn, rune, hp, quest
    CARD (slow):  cls, spec, lvl, ilvl, key, klvl, vault, zone, rest, gold,
                  enchMask, gemMiss, pots, hs, foodCount
]]

local addonName, ns = ...

local SelfState = {}
ns.SelfState = SelfState

-- Run a reader that touches optional/late APIs without letting an error escape
-- into a timer callback. Returns the value or the fallback.
local function safe(fn, fallback)
  local ok, a, b, c = pcall(fn)
  if ok then return a, b, c end
  return fallback
end

-- Midnight "Secret Values" (§9) taint on any arithmetic/relational use, so we must
-- check before doing maths on a value that the client may hand back protected.
local function isSecret(v)
  return type(issecretvalue) == "function" and issecretvalue(v)
end

-- ---------------------------------------------------------------------------
-- Durability: weakest slot %, which slot, and how many are below threshold
-- ---------------------------------------------------------------------------
local FIRST_SLOT = INVSLOT_FIRST_EQUIPPED or 1
local LAST_SLOT  = INVSLOT_LAST_EQUIPPED or 18

local function readDurability()
  local lowest, worstSlot, anyHas = 100, 0, false
  local threshold = (ns.db and ns.db.thresholds.durability) or 30
  local lowCount = 0
  for slot = FIRST_SLOT, LAST_SLOT do
    local cur, max = GetInventoryItemDurability(slot)
    if cur and max and max > 0 then
      anyHas = true
      local pct = (cur / max) * 100
      if pct < lowest then lowest = pct; worstSlot = slot end
      if pct < threshold then lowCount = lowCount + 1 end
    end
  end
  if not anyHas then return 100, 0, 0 end
  return math.floor(lowest + 0.5), worstSlot, lowCount
end

-- ---------------------------------------------------------------------------
-- Bags
-- ---------------------------------------------------------------------------
local function readBagSpace()
  local free, last = 0, NUM_BAG_SLOTS or 4
  if NUM_TOTAL_EQUIPPED_BAG_SLOTS then last = NUM_TOTAL_EQUIPPED_BAG_SLOTS end
  for bag = (BACKPACK_CONTAINER or 0), last do
    local n = C_Container and C_Container.GetContainerNumFreeSlots
      and C_Container.GetContainerNumFreeSlots(bag)
    if n then free = free + n end
  end
  return free
end

-- Returns hasMainHandEnchant + its remaining seconds (temporary enchants like oils
-- report a millisecond expiration; permanent enchants report none -> 0). The
-- expiration can come back as a secret value out of combat, so guard before any
-- maths on it (an unguarded comparison would error and abort the whole recompute).
local function readWeaponEnchant()
  if not GetWeaponEnchantInfo then return false, 0 end
  local hasMain, mainExpMs = GetWeaponEnchantInfo()
  local rem = 0
  if hasMain == true and mainExpMs ~= nil and not isSecret(mainExpMs) and mainExpMs > 0 then
    rem = mainExpMs / 1000
  end
  return hasMain == true, rem
end

-- ---------------------------------------------------------------------------
-- Full-HP flag — UnitHealth is SECRET out of combat in Midnight; guard it (§9)
-- ---------------------------------------------------------------------------
local function readFullHP()
  if not UnitHealth then return nil end
  local cur, max = UnitHealth("player"), UnitHealthMax("player")
  if type(issecretvalue) == "function" and (issecretvalue(cur) or issecretvalue(max)) then
    return nil
  end
  if not max or max == 0 then return nil end
  return cur >= max
end

-- ---------------------------------------------------------------------------
-- Quest
-- ---------------------------------------------------------------------------
local truncate = ns.Util.Truncate

local function readQuest()
  local qid = ns.db and ns.db.pinnedQuestID
  if not qid or qid == 0 then
    qid = safe(function() return C_SuperTrack.GetSuperTrackedQuestID() end, 0) or 0
  end
  local q = { qid = qid or 0, qname = "", qcur = 0, qtotal = 0, qpct = 0 }
  if not qid or qid == 0 then return q end

  q.qname = truncate(safe(function() return C_QuestLog.GetTitleForQuestID(qid) end, "") or "", 40)

  local objectives = safe(function() return C_QuestLog.GetQuestObjectives(qid) end, nil)
  if objectives then
    local total, done, pctAccum = 0, 0, 0
    for _, obj in ipairs(objectives) do
      total = total + 1
      if obj.finished then done = done + 1 end
      if obj.numRequired and obj.numRequired > 0 then
        pctAccum = pctAccum + math.min(1, (obj.numFulfilled or 0) / obj.numRequired)
      elseif obj.finished then
        pctAccum = pctAccum + 1
      end
    end
    q.qcur, q.qtotal = done, total
    if total > 0 then q.qpct = math.floor((pctAccum / total) * 100 + 0.5) end
  end
  return q
end

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------
local function readIdentity(s)
  s.cls = select(2, UnitClass("player")) or ""
  s.lvl = UnitLevel("player") or 0
  s.spec = safe(function()
    local idx = GetSpecialization()
    if idx then return (GetSpecializationInfo(idx)) end
    return 0
  end, 0) or 0
  local _, equipped = safe(function() return GetAverageItemLevel() end, 0)
  s.ilvl = math.floor((equipped or 0) + 0.5)
end

-- ---------------------------------------------------------------------------
-- Mythic+ keystone
-- ---------------------------------------------------------------------------
local function readMythic(s)
  local mapID = safe(function() return C_MythicPlus.GetOwnedKeystoneChallengeMapID() end, nil)
  local level = safe(function() return C_MythicPlus.GetOwnedKeystoneLevel() end, nil)
  if mapID and level and level > 0 then
    local name = safe(function() return (C_ChallengeMode.GetMapUIInfo(mapID)) end, nil)
    s.key, s.klvl = name or ("Map " .. mapID), level
  else
    s.key, s.klvl = "", 0
  end
end

-- ---------------------------------------------------------------------------
-- Great Vault progress (slots completed per track: raid / M+ / world)
-- ---------------------------------------------------------------------------
local function readVault(s)
  s.vr, s.vm, s.vw = 0, 0, 0
  if not C_WeeklyRewards or not C_WeeklyRewards.GetActivities then return end
  local activities = safe(function() return C_WeeklyRewards.GetActivities() end, nil)
  if not activities then return end
  local T = Enum and Enum.WeeklyRewardChestThresholdType
  for _, a in ipairs(activities) do
    if a.progress and a.threshold and a.progress >= a.threshold then
      if T and a.type == T.Raid then s.vr = s.vr + 1
      elseif T and a.type == T.World then s.vw = s.vw + 1
      else s.vm = s.vm + 1 end   -- Activities (M+) / default bucket
    end
  end
end

-- ---------------------------------------------------------------------------
-- Location & wallet
-- ---------------------------------------------------------------------------
local function readLocation(s)
  s.zone = safe(function() return GetZoneText() end, "") or ""
  if s.zone == "" then s.zone = safe(function() return GetRealZoneText() end, "") or "" end
  s.rest = safe(function() return IsResting() end, false) and true or false
  s.gold = math.floor((safe(function() return GetMoney() end, 0) or 0) / 10000)
end

-- Map coordinates (0-100, one decimal). Returns 0,0 where unavailable (instances).
local function readCoords(s)
  s.cx, s.cy = 0, 0
  if not (C_Map and C_Map.GetBestMapForUnit) then return end
  local mapID = safe(function() return C_Map.GetBestMapForUnit("player") end, nil)
  if not mapID then return end
  local pos = safe(function() return C_Map.GetPlayerMapPosition(mapID, "player") end, nil)
  if not pos then return end
  local x, y = pos:GetXY()
  if x and y then
    s.cx = math.floor(x * 1000 + 0.5) / 10
    s.cy = math.floor(y * 1000 + 0.5) / 10
  end
end

-- Light coord-only refresh; returns true if moved ≥0.1%. Used by the poll ticker
-- so we can sync position without a full (gear-scanning) recompute every tick.
function SelfState.PollCoords()
  local s = ns.state.self
  local ox, oy = s.cx or -1, s.cy or -1
  readCoords(s)
  return math.abs((s.cx or 0) - ox) >= 0.1 or math.abs((s.cy or 0) - oy) >= 0.1
end

-- ---------------------------------------------------------------------------
-- Gear quality: missing enchants (bitmask) + best-effort empty-socket count
-- ---------------------------------------------------------------------------
-- Weapon-slot equip locations that accept a permanent weapon enchant. Shields,
-- held-in-off-hand items, ranged weapons and wands take none on modern clients,
-- so an empty enchant field there is NOT a missing enchant (false "missing"
-- otherwise; if a future patch makes these enchantable we under-report, which is
-- the safer direction for an advisory check).
local ENCHANTABLE_WEAPON_LOC = {
  INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true,
  INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true,
}

-- Which inventory slots take a permanent enchant THIS expansion? Preferred
-- source: PeaversConsumablesData (per-spec enchant guide data, ships updates with
-- the game so we never chase patches here). Fallback when it isn't installed or
-- has no data for the spec: a built-in Midnight 12.x set — head, shoulder, chest,
-- legs, feet, rings, weapons; cloak and wrist enchants no longer exist.
local FALLBACK_ENCHANTABLE = {
  [1] = true, [3] = true, [5] = true, [7] = true, [8] = true,
  [11] = true, [12] = true, [16] = true, [17] = true,
}

-- Guide slot text -> inventory slot(s). Matched as substrings of the lowercased
-- slot label ("Helm"/"Helmet"/"Head", "Shoulders", "Boots", "Rings", ...).
local SLOT_TEXT_TO_INV = {
  helm = { 1 }, head = { 1 },
  shoulder = { 3 },
  chest = { 5 },
  legs = { 7 },
  boots = { 8 }, feet = { 8 },
  wrist = { 9 }, bracer = { 9 },
  ring = { 11, 12 },
  cloak = { 15 }, back = { 15 },
  weapon = { 16, 17 },
}

-- Cached per class:spec (readGear runs on every state event; the guide lookup
-- only needs to happen again after a spec change).
local enchantableCache, enchantableCacheKey

local function enchantableSlots()
  local classID = select(3, UnitClass("player"))
  local specID = 0
  local idx = GetSpecialization and GetSpecialization()
  if idx then specID = (GetSpecializationInfo(idx)) or 0 end
  local key = (classID or 0) .. ":" .. specID
  if enchantableCacheKey == key and enchantableCache then return enchantableCache end

  local set
  local api = _G.PeaversConsumablesData and _G.PeaversConsumablesData.API
  if api and api.GetConsumables and classID and specID ~= 0 then
    local items = safe(function() return api.GetConsumables(classID, specID, "enchants") end, nil)
    if type(items) == "table" and #items > 0 then
      set = {}
      for _, item in ipairs(items) do
        local slotText = tostring(item.slot or ""):lower()
        for word, invSlots in pairs(SLOT_TEXT_TO_INV) do
          if slotText:find(word, 1, true) then
            for _, invSlot in ipairs(invSlots) do set[invSlot] = true end
          end
        end
      end
    end
  end
  enchantableCache, enchantableCacheKey = set or FALLBACK_ENCHANTABLE, key
  return enchantableCache
end

-- Does this equipped slot expect a permanent enchant? Gated first on the
-- current-expansion enchantable set, then weapon slots additionally on the item
-- being an enchantable weapon type.
local function slotWantsEnchant(slot, link)
  if not enchantableSlots()[slot] then return false end
  if slot ~= (INVSLOT_MAINHAND or 16) and slot ~= (INVSLOT_OFFHAND or 17) then return true end
  local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not getInstant then return true end
  local equipLoc = safe(function() return select(4, getInstant(link)) end, nil)
  return ENCHANTABLE_WEAPON_LOC[equipLoc or ""] == true
end

-- Permanent enchant id from an item link ("item:<id>:<enchant>:..."), or nil.
local function linkEnchantID(link)
  local id = link:match("item:%d+:(%d*)")
  if not id or id == "" or id == "0" then return nil end
  return id
end

-- Socket count (from item stats) and slotted-gem count (from the link's four gem
-- fields) for one equipped item. Returns 0,0 when the item has no sockets.
local function socketCounts(link)
  local getStats = C_Item and C_Item.GetItemStats   -- bare GetItemStats global removed in 12.x
  if not getStats then return 0, 0 end
  local stats = safe(function() return getStats(link) end, nil)
  if type(stats) ~= "table" then return 0, 0 end
  local sockets = 0
  for k, v in pairs(stats) do
    if type(k) == "string" and k:find("EMPTY_SOCKET") then sockets = sockets + (v or 0) end
  end
  if sockets == 0 then return 0, 0 end
  local gem1, gem2, gem3, gem4 = link:match("item:%d+:%d*:(%d*):(%d*):(%d*):(%d*)")
  local slotted = 0
  for _, g in ipairs({ gem1, gem2, gem3, gem4 }) do
    if g and g ~= "" and g ~= "0" then slotted = slotted + 1 end
  end
  return sockets, slotted
end

local function readGear(s)
  -- enchMask: evaluated slots that lack an enchant. enchCheck: which slots were
  -- evaluated at all (equipped + enchantable) — lets the Gear tab tell "missing"
  -- apart from "empty slot / not enchantable" on the partner's side.
  local mask, check = 0, 0
  for i, slot in ipairs(ns.Snapshot.ENCHANT_SLOTS) do
    local link = GetInventoryItemLink("player", slot)
    if link and slotWantsEnchant(slot, link) then
      check = check + 2 ^ (i - 1)
      if not linkEnchantID(link) then
        mask = mask + 2 ^ (i - 1)   -- this enchantable slot is unenchanted
      end
    end
  end
  s.enchMask, s.enchCheck = mask, check

  -- Empty sockets: sockets present (from item stats) minus gems slotted (link).
  -- gs is the per-slot detail, slot ascending so the string — and thus the card
  -- signature — is deterministic. CARD travels as ONE unchunked addon message, so
  -- the encoding is kept compact: "slot:total" when every socket is filled (the
  -- common case), "slot:filled/total" only when some are empty.
  local missing, gsParts = 0, {}
  for slot = FIRST_SLOT, LAST_SLOT do
    local link = GetInventoryItemLink("player", slot)
    if link then
      local sockets, slotted = socketCounts(link)
      if sockets > 0 then
        missing = missing + math.max(0, sockets - slotted)
        gsParts[#gsParts + 1] = slot .. ":" ..
          (slotted >= sockets and sockets or (slotted .. "/" .. sockets))
      end
    end
  end
  s.gemMiss = missing
  s.gs = table.concat(gsParts, ",")
end

-- Diagnostic (/bt gear): print the per-slot decisions behind enchMask/gemMiss so a
-- wrong "missing" report can be pinned to a specific slot in-client.
function SelfState.DumpGear()
  local names = ns.Snapshot.SLOT_NAMES
  ns:Print("gear scan (enchant slots):")
  for _, slot in ipairs(ns.Snapshot.ENCHANT_SLOTS) do
    local label = (names[slot] or ("slot " .. slot)) .. " (" .. slot .. ")"
    local link = GetInventoryItemLink("player", slot)
    if not link then
      ns:Print("  " .. label .. ": |cff888888empty slot — skipped|r")
    elseif not slotWantsEnchant(slot, link) then
      ns:Print("  " .. label .. ": |cff888888not enchantable — skipped|r " .. link)
    else
      local id = linkEnchantID(link)
      if id then ns:Print("  " .. label .. ": |cff44ff44enchant " .. id .. "|r " .. link)
      else ns:Print("  " .. label .. ": |cffff5555NO ENCHANT -> counted missing|r " .. link) end
    end
  end
  ns:Print("gear scan (sockets):")
  local total = 0
  for slot = FIRST_SLOT, LAST_SLOT do
    local link = GetInventoryItemLink("player", slot)
    if link then
      local sockets, slotted = socketCounts(link)
      if sockets > 0 then
        local miss = math.max(0, sockets - slotted)
        total = total + miss
        local color = miss > 0 and "|cffff5555" or "|cff44ff44"
        ns:Print("  " .. (names[slot] or ("slot " .. slot)) .. ": " .. color .. slotted .. "/" .. sockets .. " gems|r " .. link)
      end
    end
  end
  ns:Print("=> empty sockets counted: " .. total)
end

-- ---------------------------------------------------------------------------
-- Full recompute
-- ---------------------------------------------------------------------------
function SelfState.Update()
  if ns:InCombat() then return end
  local s = ns.state.self

  -- SNAP fields
  local cons = ns.Consumables.ScanPlayer()
  local q = readQuest()
  s.dur, s.durSlot, s.durLowN = readDurability()
  s.bags  = readBagSpace()
  local hasWpn, wpnRem = readWeaponEnchant()
  s.flask = cons.flask
  s.food  = cons.food
  s.rune  = cons.rune
  s.wpn   = hasWpn or cons.wpnAura
  -- Remaining seconds per buff (0 = active but no countdown to show), sent so the
  -- partner can tick it down between syncs. Weapon time prefers the real enchant.
  s.flaskr = math.floor(cons.flaskRem or 0)
  s.foodr  = math.floor(cons.foodRem or 0)
  s.runer  = math.floor(cons.runeRem or 0)
  s.wpnr   = math.floor((hasWpn and wpnRem) or (cons.wpnAura and cons.wpnAuraRem) or 0)
  s.hp    = readFullHP()
  s.qid, s.qname, s.qcur, s.qtotal, s.qpct = q.qid, q.qname, q.qcur, q.qtotal, q.qpct

  -- CARD fields
  readIdentity(s)
  readMythic(s)
  readVault(s)
  readLocation(s)
  readCoords(s)
  readGear(s)
  local pots, hs, feast = ns.Consumables.CountSupplies()
  s.pots, s.hs, s.foodCount = pots, hs, feast
end

-- Fast-changing fingerprint (drives SNAP sends).
function SelfState.SnapSignature()
  local s = ns.state.self
  return table.concat({
    s.dur or -1, s.durSlot or 0, s.durLowN or 0, s.bags or -1,
    s.flask and 1 or 0, s.food and 1 or 0, s.wpn and 1 or 0, s.rune and 1 or 0,
    s.qid or 0, s.qcur or 0, s.qtotal or 0, s.qpct or 0,
  }, ":")
end

-- Slow-changing fingerprint (drives CARD sends).
function SelfState.CardSignature()
  local s = ns.state.self
  return table.concat({
    s.cls or "", s.spec or 0, s.lvl or 0, s.ilvl or 0,
    s.key or "", s.klvl or 0, s.vr or 0, s.vm or 0, s.vw or 0,
    s.zone or "", s.rest and 1 or 0, s.gold or 0,
    s.enchMask or 0, s.enchCheck or 0, s.gemMiss or 0, s.gs or "",
    s.pots or 0, s.hs or 0, s.foodCount or 0,
    math.floor(s.cx or 0), math.floor(s.cy or 0),
  }, ":")
end

-- ---------------------------------------------------------------------------
-- Events -> recompute + (debounced) sends
-- ---------------------------------------------------------------------------
-- Coalesce bursts of state events into one deferred recompute. UNIT_AURA (and
-- friends) can fire many times in a single frame — especially in a raid — and each
-- fire ran a full SelfState.Update (consumable/durability/bag/gear+gem scans) plus a
-- dashboard refresh. We instead mark dirty and flush once on the next frame, so a
-- burst costs a single recompute rather than one per event.
local flushScheduled = false
local lastSelfSig
local function flushStateEvents()
  flushScheduled = false
  SelfState.Update()
  if ns.Comm then
    ns.Comm.QueueSnapshot(false)
    ns.Comm.QueueCard(false)
  end
  -- Only repaint when our own state actually changed. Update() no-ops in combat, so
  -- the signature stays stable and the constant in-combat UNIT_AURA churn no longer
  -- drives a per-frame dashboard relayout even with the window open.
  local sig = SelfState.SnapSignature() .. "#" .. SelfState.CardSignature()
  if sig ~= lastSelfSig then
    lastSelfSig = sig
    if ns.Dashboard and ns.Dashboard.Refresh then ns.Dashboard.Refresh() end
  end
end

local function onStateEvent(event, unit)
  if event == "UNIT_AURA" and unit ~= "player" then return end
  if event == "UNIT_INVENTORY_CHANGED" and unit ~= "player" then return end
  SelfState._events = (SelfState._events or 0) + 1   -- diagnostics: see /bt perf
  if flushScheduled then return end
  flushScheduled = true
  SelfState._flushes = (SelfState._flushes or 0) + 1
  C_Timer.After(0, flushStateEvents)
end

-- SNAP-relevant
ns:RegisterEvent("UPDATE_INVENTORY_DURABILITY", onStateEvent)
ns:RegisterEvent("BAG_UPDATE_DELAYED",          onStateEvent)
ns:RegisterEvent("UNIT_AURA",                   onStateEvent)
ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED",    onStateEvent)
ns:RegisterEvent("UNIT_INVENTORY_CHANGED",      onStateEvent)
ns:RegisterEvent("QUEST_LOG_UPDATE",            onStateEvent)
ns:RegisterEvent("QUEST_WATCH_UPDATE",          onStateEvent)
ns:RegisterEvent("UNIT_QUEST_LOG_CHANGED",      onStateEvent)
ns:RegisterEvent("SUPER_TRACKING_CHANGED",      onStateEvent)
ns:RegisterEvent("PLAYER_REGEN_ENABLED",        onStateEvent)
-- CARD-relevant
ns:RegisterEvent("PLAYER_LEVEL_UP",             onStateEvent)
ns:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", onStateEvent)  -- spec field + enchantable-slot set
ns:RegisterEvent("ZONE_CHANGED_NEW_AREA",       onStateEvent)
ns:RegisterEvent("ZONE_CHANGED",                onStateEvent)
ns:RegisterEvent("PLAYER_UPDATE_RESTING",       onStateEvent)
ns:RegisterEvent("PLAYER_MONEY",                onStateEvent)
ns:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE",  onStateEvent)
ns:RegisterEvent("WEEKLY_REWARDS_UPDATE",       onStateEvent)
ns:RegisterEvent("PLAYER_AVG_ITEM_LEVEL_UPDATE", onStateEvent)

-- Ask the M+ subsystem to populate keystone/map data after login.
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
  if C_MythicPlus and C_MythicPlus.RequestMapInfo then pcall(C_MythicPlus.RequestMapInfo) end
end)

-- Poll position; sync a fresh card only when the partner-facing position moved.
C_Timer.NewTicker(3, function()
  if ns:InCombat() then return end
  if not (ns.Pairing and ns.Pairing.PartnerName()) then return end
  if SelfState.PollCoords() and ns.Comm and ns.Comm.QueueCard then
    ns.Comm.QueueCard(false)
  end
end)

return SelfState
