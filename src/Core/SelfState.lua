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

local function readWeaponEnchant()
  if not GetWeaponEnchantInfo then return false end
  local hasMain = GetWeaponEnchantInfo()
  return hasMain == true
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
local function readGear(s)
  local mask = 0
  for i, slot in ipairs(ns.Snapshot.ENCHANT_SLOTS) do
    local link = GetInventoryItemLink("player", slot)
    if link then
      local enchantID = link:match("item:%d+:(%d*)")
      if not enchantID or enchantID == "" or enchantID == "0" then
        mask = mask + 2 ^ (i - 1)   -- this enchantable slot is unenchanted
      end
    end
  end
  s.enchMask = mask

  -- Empty sockets: sockets present (from item stats) minus gems slotted (link).
  local missing = 0
  local getStats = (C_Item and C_Item.GetItemStats) or GetItemStats
  for slot = FIRST_SLOT, LAST_SLOT do
    local link = GetInventoryItemLink("player", slot)
    if link and getStats then
      local stats = safe(function() return getStats(link) end, nil)
      if type(stats) == "table" then
        local sockets = 0
        for k, v in pairs(stats) do
          if type(k) == "string" and k:find("EMPTY_SOCKET") then sockets = sockets + (v or 0) end
        end
        if sockets > 0 then
          -- count slotted gems in the link's gem fields
          local _, gem1, gem2, gem3, gem4 = link:match("item:%d+:%d*:(%d*):(%d*):(%d*):(%d*)")
          local slotted = 0
          for _, g in ipairs({ gem1, gem2, gem3, gem4 }) do
            if g and g ~= "" and g ~= "0" then slotted = slotted + 1 end
          end
          missing = missing + math.max(0, sockets - slotted)
        end
      end
    end
  end
  s.gemMiss = missing
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
  s.flask = cons.flask
  s.food  = cons.food
  s.rune  = cons.rune
  s.wpn   = readWeaponEnchant() or cons.wpnAura
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
    s.enchMask or 0, s.gemMiss or 0, s.pots or 0, s.hs or 0, s.foodCount or 0,
    math.floor(s.cx or 0), math.floor(s.cy or 0),
  }, ":")
end

-- ---------------------------------------------------------------------------
-- Events -> recompute + (debounced) sends
-- ---------------------------------------------------------------------------
local function onStateEvent(event, unit)
  if event == "UNIT_AURA" and unit ~= "player" then return end
  if event == "UNIT_INVENTORY_CHANGED" and unit ~= "player" then return end

  SelfState.Update()
  if ns.Comm then
    ns.Comm.QueueSnapshot(false)
    ns.Comm.QueueCard(false)
  end
  if ns.Dashboard and ns.Dashboard.Refresh then ns.Dashboard.Refresh() end
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
ns:RegisterEvent("ZONE_CHANGED_NEW_AREA",       onStateEvent)
ns:RegisterEvent("ZONE_CHANGED",                onStateEvent)
ns:RegisterEvent("PLAYER_UPDATE_RESTING",       onStateEvent)
ns:RegisterEvent("PLAYER_MONEY",                onStateEvent)
ns:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE",  onStateEvent)
ns:RegisterEvent("WEEKLY_REWARDS_UPDATE",       onStateEvent)
ns:RegisterEvent("AVERAGE_ITEM_LEVEL_UPDATE",   onStateEvent)

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
