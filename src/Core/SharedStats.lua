--[[ SharedStats.lua
  Persistent shared duo statistics — the "what we've done together" counters that
  make BetterTogether a home base for a pair (bosses, dungeons, M+, quests, deaths,
  mobs, time played together).

  Storage: BetterTogetherCharDB.stats (see Core.lua CHARDB_DEFAULTS).
    - shared counters (bosses/dungeons/mplus/togetherTime): both clients observe
      the same event, so they max-merge on sync and self-heal if one missed it.
    - personal counters (quests/deaths/mobs): each tracks its own; shown side by
      side and summed for a "together" total.

  All counting is gated by IsTogether() (grouped with the bonded partner) and uses
  only non-secret reads, so it's safe even though some events fire in combat.
]]

local addonName, ns = ...

local SharedStats = {}
ns.SharedStats = SharedStats

local MPLUS_HISTORY_MAX = 10
local FLUSH_INTERVAL = 10          -- seconds; accrues time + flushes mob kills
local playerGUID
local lastChallengeAt = 0
local mobsDirty = false

local function stats() return ns.chardb and ns.chardb.stats end

-- ---------------------------------------------------------------------------
-- "Together" detection — grouped with the bonded partner (no secret reads)
-- ---------------------------------------------------------------------------
function SharedStats.IsTogether()
  if not IsInGroup() then return false end
  local partner = ns.Pairing and ns.Pairing.PartnerName()
  if not partner then return false end
  local short = ns.Pairing.ShortName(partner)
  for i = 1, 4 do
    local u = "party" .. i
    if UnitExists(u) and UnitName(u) == short then return true end
  end
  if IsInRaid() then
    for i = 1, 40 do
      local u = "raid" .. i
      if UnitExists(u) and UnitName(u) == short then return true end
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Counters
-- ---------------------------------------------------------------------------
-- Stamp the "together since" timestamp the first time we ever count something
-- together (min-merged across the pair, so the earlier client's date wins).
local function markFirstTogether(s)
  if s and (s.firstTogether or 0) == 0 then
    s.firstTogether = (GetServerTime and GetServerTime()) or 0
  end
end

local function bump(key, amount)
  local s = stats(); if not s then return end
  markFirstTogether(s)
  s[key] = (s[key] or 0) + (amount or 1)
  if ns.Comm and ns.Comm.QueueStats then ns.Comm.QueueStats() end
  if ns.Dashboard and ns.Dashboard.Refresh then ns.Dashboard.Refresh() end
end
SharedStats.Bump = bump

-- Signature for the Comm debounce (togetherTime excluded so it doesn't spam sends).
function SharedStats.Signature()
  local s = stats() or {}
  return table.concat({ s.bosses or 0, s.dungeons or 0, s.mplus or 0, s.wipes or 0,
    s.quests or 0, s.deaths or 0, s.mobs or 0, s.achievements or 0, s.levels or 0 }, ":")
end

-- Merge an incoming partner stats table: max-merge shared counters into our own
-- store (self-healing), stash partner's table for side-by-side display.
function SharedStats.MergePartner(p)
  local s = stats(); if not (s and p) then return end
  local weAreAhead = false
  for _, k in ipairs({ "bosses", "dungeons", "mplus", "togetherTime", "wipes" }) do
    if (p[k] or 0) > (s[k] or 0) then s[k] = p[k] end
    if (s[k] or 0) > (p[k] or 0) then weAreAhead = true end
  end
  -- "Together since" min-merges: the earliest non-zero timestamp wins so both
  -- clients agree on the anniversary even if one started counting later.
  if (p.firstTogether or 0) > 0 and ((s.firstTogether or 0) == 0 or p.firstTogether < s.firstTogether) then
    s.firstTogether = p.firstTogether
  elseif (s.firstTogether or 0) > 0 and (p.firstTogether or 0) ~= s.firstTogether then
    weAreAhead = true   -- push our earlier/known date so the partner converges
  end
  ns.state.partner = ns.state.partner or {}
  ns.state.partner.stats = p
  -- If we hold a higher shared value, push it so the partner converges too.
  if weAreAhead and ns.Comm and ns.Comm.QueueStats then ns.Comm.QueueStats() end
  if ns.Dashboard and ns.Dashboard.Refresh then ns.Dashboard.Refresh() end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
ns:RegisterEvent("PLAYER_LOGIN", function() playerGUID = UnitGUID("player") end)

ns:RegisterEvent("QUEST_TURNED_IN", function()
  if SharedStats.IsTogether() then bump("quests") end
end)

ns:RegisterEvent("ENCOUNTER_END", function(_, encID, name, diff, size, success)
  if not SharedStats.IsTogether() then return end
  if success and success ~= 0 then bump("bosses") else bump("wipes") end
end)

ns:RegisterEvent("ACHIEVEMENT_EARNED", function()
  if SharedStats.IsTogether() then bump("achievements") end
end)

ns:RegisterEvent("PLAYER_LEVEL_UP", function()
  if SharedStats.IsTogether() then bump("levels") end
end)

-- C_ChallengeMode.GetCompletionInfo returns nils/zeros for a short beat after
-- CHALLENGE_MODE_COMPLETED, so a synchronous read records "+0 <unknown>, over time".
-- Read with retries until the level resolves, and turn the map *ID* it returns into
-- a name via GetMapUIInfo (same resolution SelfState.readMythic uses for keystones).
local MPLUS_CAPTURE_RETRIES = 6
local MPLUS_CAPTURE_DELAY = 0.5

local function readChallengeRun()
  if not (C_ChallengeMode and C_ChallengeMode.GetCompletionInfo) then return nil end
  local ok, mapID, level, _, onTime = pcall(C_ChallengeMode.GetCompletionInfo)
  if not ok or not level or level == 0 then return nil end
  local name
  if mapID and C_ChallengeMode.GetMapUIInfo then
    name = (C_ChallengeMode.GetMapUIInfo(mapID))
  end
  return {
    map = name or (mapID and ("Map " .. mapID)) or nil,
    level = level,
    onTime = onTime and true or false,
    ts = (GetServerTime and GetServerTime()) or 0,
  }
end

local function recordChallengeRun(attempt)
  local s = stats(); if not s then return end
  local run = readChallengeRun()
  if not run then
    if attempt < MPLUS_CAPTURE_RETRIES then
      C_Timer.After(MPLUS_CAPTURE_DELAY, function() recordChallengeRun(attempt + 1) end)
    end
    return
  end
  s.mplusRuns = s.mplusRuns or {}
  table.insert(s.mplusRuns, 1, run)
  while #s.mplusRuns > MPLUS_HISTORY_MAX do table.remove(s.mplusRuns) end
  if ns.Comm and ns.Comm.QueueStats then ns.Comm.QueueStats() end
  if ns.Dashboard and ns.Dashboard.Refresh then ns.Dashboard.Refresh() end
end

ns:RegisterEvent("CHALLENGE_MODE_COMPLETED", function()
  if not SharedStats.IsTogether() then return end
  lastChallengeAt = GetTime()
  local s = stats(); if not s then return end
  markFirstTogether(s)
  s.mplus = (s.mplus or 0) + 1
  s.dungeons = (s.dungeons or 0) + 1
  -- Counters are correct now; push them immediately. The detailed run row lands once
  -- GetCompletionInfo populates (see recordChallengeRun), with its own queue/refresh.
  if ns.Comm and ns.Comm.QueueStats then ns.Comm.QueueStats() end
  if ns.Dashboard and ns.Dashboard.Refresh then ns.Dashboard.Refresh() end
  recordChallengeRun(1)
end)

ns:RegisterEvent("LFG_COMPLETION_REWARD", function()
  if not SharedStats.IsTogether() then return end
  if GetTime() - lastChallengeAt < 5 then return end  -- avoid double-count with M+
  local _, instanceType = IsInInstance()
  if instanceType == "party" then bump("dungeons") end
end)

ns:RegisterEvent("PLAYER_DEAD", function()
  if SharedStats.IsTogether() then bump("deaths") end
end)

-- Mob kills: count own killing blows (PARTY_KILL). High frequency, so increment
-- silently and flush on the periodic ticker rather than per kill.
ns:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function()
  local _, sub, _, srcGUID = CombatLogGetCurrentEventInfo()
  if sub ~= "PARTY_KILL" then return end
  if not playerGUID then playerGUID = UnitGUID("player") end
  if srcGUID == playerGUID and SharedStats.IsTogether() then
    local s = stats(); if s then s.mobs = (s.mobs or 0) + 1; mobsDirty = true end
  end
end)

-- Periodic: accrue together-time and flush buffered mob kills.
C_Timer.NewTicker(FLUSH_INTERVAL, function()
  local s = stats(); if not s then return end
  if SharedStats.IsTogether() then markFirstTogether(s); s.togetherTime = (s.togetherTime or 0) + FLUSH_INTERVAL end
  if mobsDirty then
    mobsDirty = false
    if ns.Comm and ns.Comm.QueueStats then ns.Comm.QueueStats() end
    if ns.Dashboard and ns.Dashboard.Refresh then ns.Dashboard.Refresh() end
  end
end)

return SharedStats
