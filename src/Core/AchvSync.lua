--[[ AchvSync.lua
  Scans the player's COMPLETED achievements into per-era buckets and (de)serializes
  each era for the chunked ACHV comm message — mirrors QuestSync/InvSync.

  Bucketing is by *date of completion* (when you actually earned it), not the
  achievement's home expansion: a vanilla exploration meta finished in 2020 lands
  in 2020 — because that's the real shared memory. The "Achievements" page intersects
  your era list with the partner's: same id + same calendar day == "earned together".

  Only id + packed date go on the wire ("<id>:<YYYYMMDD>", all numeric so "," is a
  safe joiner). Names / points / icons are resolved on the receiving client via
  GetAchievementInfo(id) — keeps the payload tiny and sidesteps name delimiter hazards.
]]

local addonName, ns = ...

local AchvSync = {}
ns.AchvSync = AchvSync

local MAX_PER_ERA = 500   -- safety cap per era bucket (chunked anyway)

-- Era boundaries keyed by *retail launch date*. Ordered newest-first; an achievement
-- earned on/after a boundary (and before the next newer one) belongs to that era.
-- key is a stable numeric id (1 = oldest) used as the era token on the wire.
local ERAS = {
  { key = 11, name = "The War Within",         y = 2024, m = 8  },
  { key = 10, name = "Dragonflight",           y = 2022, m = 11 },
  { key = 9,  name = "Shadowlands",            y = 2020, m = 11 },
  { key = 8,  name = "Battle for Azeroth",     y = 2018, m = 8  },
  { key = 7,  name = "Legion",                 y = 2016, m = 8  },
  { key = 6,  name = "Warlords of Draenor",    y = 2014, m = 11 },
  { key = 5,  name = "Mists of Pandaria",      y = 2012, m = 9  },
  { key = 4,  name = "Cataclysm",              y = 2010, m = 12 },
  { key = 3,  name = "Wrath of the Lich King", y = 2008, m = 11 },
  { key = 2,  name = "The Burning Crusade",    y = 2007, m = 1  },
  { key = 1,  name = "Classic",                y = 2004, m = 11 },
}
AchvSync.ERAS = ERAS

local NAME_BY_KEY = {}
for _, e in ipairs(ERAS) do NAME_BY_KEY[e.key] = e.name end
function AchvSync.EraName(key) return NAME_BY_KEY[key] or "Unknown" end

-- Newest-first list of era keys (for the page's prev/next navigation).
function AchvSync.EraOrder()
  local order = {}
  for _, e in ipairs(ERAS) do order[#order + 1] = e.key end
  return order
end

-- Map a completion (year, month) to its era key. ERAS is newest-first, so the first
-- boundary the date is not-before wins.
function AchvSync.EraOf(y, m)
  local code = (y or 0) * 100 + (m or 0)
  for _, e in ipairs(ERAS) do
    if code >= e.y * 100 + e.m then return e.key end
  end
  return ERAS[#ERAS].key   -- anything earlier than the oldest boundary → Classic
end

-- GetAchievementInfo returns the year as years-since-2000 on retail (e.g. 24). Older
-- clients have returned full years — normalise both to a 4-digit year.
local function normYear(y)
  y = tonumber(y) or 0
  if y > 0 and y < 100 then return 2000 + y end
  return y
end

-- Enumerate every completed achievement once, bucketed by era. The full DB is
-- thousands of entries, so the scan is spread across frames: `onWork` (if given)
-- is called every ACHV_BATCH achievements, letting an async driver yield. Pass
-- nil for a blocking scan. Entry: { id, y, m, d }.
-- Kept modest so each pumped frame does little work: the scan is normally pre-warmed
-- in the background shortly after login (Core), so a slightly longer wall-clock scan
-- is invisible — what matters is that no single frame hitches.
local ACHV_BATCH = 100
local function sweep(onWork)
  local byEra, seen = {}, {}
  if not (GetCategoryList and GetCategoryNumAchievements and GetAchievementInfo) then return byEra end
  local work = 0
  for _, cat in ipairs(GetCategoryList()) do
    local n = GetCategoryNumAchievements(cat) or 0
    for i = 1, n do
      local id, _, _, completed, mo, day, yr = GetAchievementInfo(cat, i)
      if id and completed and not seen[id] then
        yr = normYear(yr)
        if yr > 0 then
          seen[id] = true
          local era = AchvSync.EraOf(yr, mo)
          byEra[era] = byEra[era] or {}
          byEra[era][#byEra[era] + 1] = { id = id, y = yr, m = mo or 0, d = day or 0 }
        end
      end
      if onWork then
        work = work + 1
        if work >= ACHV_BATCH then work = 0; onWork() end
      end
    end
  end
  return byEra
end

-- The scan runs asynchronously (a coroutine pumped by a per-frame ticker) so
-- opening the page never blocks. `cache` stays nil until the first scan finishes;
-- consumers go through AchvSync.Ensure and act in its callback. Mirrors how the
-- Quests/Inventory pages stream their data in rather than building up front.
local cache, scanTicker, scanCo, waiters = nil, nil, nil, {}

-- True once the buckets are built (vs. nil = not scanned yet).
function AchvSync.Ready() return cache ~= nil end

local function flushWaiters()
  local w = waiters; waiters = {}
  for _, cb in ipairs(w) do cb(cache) end
end

-- Ensure the per-era buckets exist, then fire `onReady(cache)` — immediately if
-- already scanned, otherwise when the background scan completes.
function AchvSync.Ensure(onReady)
  if cache then if onReady then onReady(cache) end return end
  if onReady then waiters[#waiters + 1] = onReady end
  if scanTicker then return end                       -- a scan is already in flight
  if not (C_Timer and C_Timer.NewTicker and coroutine) then
    cache = sweep(nil); flushWaiters(); return         -- no async primitives: scan inline
  end
  scanCo = coroutine.create(function() return sweep(coroutine.yield) end)
  scanTicker = C_Timer.NewTicker(0, function()
    local ok, ret = coroutine.resume(scanCo)
    if not ok then
      ns:Debug("AchvSync scan error: " .. tostring(ret))
      cache = {}
    elseif coroutine.status(scanCo) ~= "dead" then
      return                                            -- still scanning; resume next frame
    else
      cache = ret or {}
    end
    scanTicker:Cancel(); scanTicker, scanCo = nil, nil
    flushWaiters()
  end)
end

function AchvSync.All() return cache or {} end

function AchvSync.Invalidate()
  cache = nil
  if scanTicker then scanTicker:Cancel(); scanTicker, scanCo = nil, nil end
  if #waiters > 0 then                                 -- a consumer is still waiting: rescan now
    local w = waiters; waiters = {}
    for _, cb in ipairs(w) do AchvSync.Ensure(cb) end
  end
end

-- Own achievements for one era as { id, y, m, d } (resolved live, not synced).
function AchvSync.EraList(eraKey) return (cache and cache[eraKey]) or {} end

-- Wire: "<id>:<YYYYMMDD>" joined by ",". All-numeric, "," / ":" safe.
function AchvSync.EncodeEra(eraKey)
  local list = AchvSync.EraList(eraKey)
  local parts = {}
  for i = 1, math.min(#list, MAX_PER_ERA) do
    local a = list[i]
    parts[i] = a.id .. ":" .. (a.y * 10000 + a.m * 100 + a.d)
  end
  return table.concat(parts, ",")
end

function AchvSync.DecodeEra(eraKey, str)
  local list = {}
  for entry in (str or ""):gmatch("[^,]+") do
    local id, date = entry:match("^(%d+):(%d+)$")
    if id then
      date = tonumber(date)
      list[#list + 1] = { id = tonumber(id),
        y = math.floor(date / 10000), m = math.floor(date / 100) % 100, d = date % 100 }
    end
  end
  ns.state.partner = ns.state.partner or {}
  ns.state.partner.achv = ns.state.partner.achv or {}
  ns.state.partner.achv[eraKey] = list
end

-- Tiny per-era summary so the page knows which eras the partner has data in (and the
-- earliest date in each, to seed the "where it began" featured card) without pulling
-- every era. Wire: "<eraKey>:<count>:<YYYYMMDD-earliest>" joined by ",".
function AchvSync.EncodeDigest()
  local all = AchvSync.All()
  local parts = {}
  for key, list in pairs(all) do
    local earliest
    for _, a in ipairs(list) do
      local code = a.y * 10000 + a.m * 100 + a.d
      if not earliest or code < earliest then earliest = code end
    end
    parts[#parts + 1] = key .. ":" .. #list .. ":" .. (earliest or 0)
  end
  return table.concat(parts, ",")
end

function AchvSync.DecodeDigest(str)
  local d = {}
  for entry in (str or ""):gmatch("[^,]+") do
    local key, cnt, earliest = entry:match("^(%d+):(%d+):(%d+)$")
    if key then d[tonumber(key)] = { count = tonumber(cnt), earliest = tonumber(earliest) } end
  end
  ns.state.partner = ns.state.partner or {}
  ns.state.partner.achvDigest = d
end

-- A freshly earned achievement invalidates the cache so the next sync includes it.
local function onAchievementEarned() AchvSync.Invalidate() end
ns:RegisterEvent("ACHIEVEMENT_EARNED", onAchievementEarned)

return AchvSync
