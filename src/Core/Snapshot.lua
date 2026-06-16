--[[ Snapshot.lua
  Build a SNAP payload from BetterTogether.self; decode an incoming SNAP into a partner
  table. Also the shared readiness-verdict computation (spec §4.4, §8.2).

  Zero-dependency wire format (spec §4.4 recommends this over LibSerialize):
    SNAP|<proto>|dur=NN|bags=NN|flask=0/1|food=0/1|wpn=0/1|rune=0/1|hp=0/1|
         qid=NN|qstep=cur/total|qpct=NN|qname=<text>
  Fields are pipe-delimited key=value pairs; qname is last so it may contain
  spaces safely. We keep the whole thing under 240 chars to avoid chunking (§4.5).
]]

local addonName, ns = ...

local Snapshot = {}
ns.Snapshot = Snapshot

local function b(v) return v and "1" or "0" end

-- Split a pipe-delimited "k=v|k=v|..." body into a key->value table. Returns nil
-- for a nil/empty payload so every decoder can bail with one guard instead of
-- re-implementing the same parse loop and empty check.
local function parseKV(payload)
  if not payload or payload == "" then return nil end
  local kv = {}
  for field in payload:gmatch("[^|]+") do
    local k, v = field:match("^(%w+)=(.*)$")
    if k then kv[k] = v end
  end
  return kv
end

-- ---------------------------------------------------------------------------
-- Encode BetterTogether.self -> payload string (the part after "SNAP|<proto>|").
-- ---------------------------------------------------------------------------
--- @return string payload Pipe-delimited SNAP body (kept under the chunk threshold).
function Snapshot.Encode()
  local s = ns.state.self
  -- Each field is gated by a privacy flag (ns.Shares); an omitted field decodes to
  -- its default on the partner's side, so dropping one never corrupts the rest.
  local parts = {}
  local function add(key, str) if ns.Shares(key) then parts[#parts + 1] = str end end
  add("durability", "dur="   .. (s.dur or 100))
  add("bags",       "bags="  .. (s.bags or 0))
  add("flask",      "flask=" .. b(s.flask))
  add("food",       "food="  .. b(s.food))
  add("wpn",        "wpn="   .. b(s.wpn))
  add("rune",       "rune="  .. b(s.rune))
  add("hp",         "hp="    .. b(s.hp))
  if ns.Shares("quest") then
    -- qname must not contain our delimiters; strip pipes/carets defensively, then
    -- truncate so the total stays under the 240-char chunk threshold.
    local qname = ns.Util.Truncate((s.qname or ""):gsub("[|^]", " "), 40)
    parts[#parts + 1] = "qid="   .. (s.qid or 0)
    parts[#parts + 1] = "qstep=" .. (s.qcur or 0) .. "/" .. (s.qtotal or 0)
    parts[#parts + 1] = "qpct="  .. (s.qpct or 0)
    parts[#parts + 1] = "qname=" .. qname
  end
  return table.concat(parts, "|")
end

-- ---------------------------------------------------------------------------
-- Decode a payload string -> partner state table.
-- `payload` is everything after "SNAP|<proto>|". Returns a table or nil.
-- ---------------------------------------------------------------------------
--- @param payload string|nil The SNAP body (everything after "SNAP|<proto>|").
--- @return table|nil snap Decoded partner readiness, or nil if the payload was empty.
function Snapshot.Decode(payload)
  local kv = parseKV(payload)
  if not kv then return nil end

  local function num(key, default)
    return tonumber(kv[key]) or default
  end
  local function bool(key)
    return kv[key] == "1"
  end

  local qcur, qtotal = 0, 0
  if kv.qstep then
    qcur, qtotal = kv.qstep:match("^(%d+)/(%d+)$")
    qcur, qtotal = tonumber(qcur) or 0, tonumber(qtotal) or 0
  end

  return {
    dur    = num("dur", 100),
    bags   = num("bags", 0),
    flask  = bool("flask"),
    food   = bool("food"),
    wpn    = bool("wpn"),
    rune   = bool("rune"),
    hp     = bool("hp"),
    qid    = num("qid", 0),
    qcur   = qcur,
    qtotal = qtotal,
    qpct   = num("qpct", 0),
    qname  = kv.qname or "",
  }
end

-- ---------------------------------------------------------------------------
-- Shared gear-slot tables (used by SelfState to build, Dashboard to display).
-- The ENCHANT_SLOTS order defines the bit positions in the `ench` bitmask, so
-- both ends MUST agree — keeping it here guarantees that.
-- ---------------------------------------------------------------------------
Snapshot.ENCHANT_SLOTS = { 15, 5, 9, 7, 8, 11, 12, 16, 17 } -- back,chest,wrist,legs,feet,ring1,ring2,mh,oh
Snapshot.SLOT_NAMES = {
  [1]="Head", [3]="Shoulder", [5]="Chest", [7]="Legs", [8]="Feet", [9]="Wrist",
  [10]="Hands", [15]="Cloak", [11]="Ring", [12]="Ring", [16]="Weapon", [17]="Off-hand",
  [6]="Belt",
}

-- ---------------------------------------------------------------------------
-- CARD: the rich, slow-changing partner card (identity / location / M+ / gear).
-- Format mirrors SNAP: pipe-delimited key=value, qname-style strings last-safe
-- because we strip delimiters from any free text.
-- ---------------------------------------------------------------------------
--- @return string payload Pipe-delimited CARD body.
function Snapshot.EncodeCard()
  local s = ns.state.self
  local function clean(str, n)
    str = (str or ""):gsub("[|^]", " ")
    return n and ns.Util.Truncate(str, n) or str
  end
  -- Privacy-gated like SNAP: each group is emitted only if shared. Grouped fields
  -- (identity, gear, supplies) travel together so a single toggle hides them all.
  local parts = {}
  local function add(key, ...)
    if not ns.Shares(key) then return end
    for i = 1, select("#", ...) do parts[#parts + 1] = select(i, ...) end
  end
  add("identity", "cls=" .. (s.cls or ""), "spec=" .. (s.spec or 0), "lvl=" .. (s.lvl or 0), "ilvl=" .. (s.ilvl or 0))
  add("keystone", "key=" .. clean(s.key, 18), "klvl=" .. (s.klvl or 0))
  add("vault",    "vault=" .. (s.vr or 0) .. "/" .. (s.vm or 0) .. "/" .. (s.vw or 0))
  add("location", "zone=" .. clean(s.zone, 24), "rest=" .. (s.rest and 1 or 0))
  add("gold",     "gold=" .. (s.gold or 0))
  add("gear",     "ench=" .. (s.enchMask or 0), "gem=" .. (s.gemMiss or 0), "dslot=" .. (s.durSlot or 0), "dlow=" .. (s.durLowN or 0))
  add("supplies", "pots=" .. (s.pots or 0), "hs=" .. (s.hs or 0), "feast=" .. (s.foodCount or 0))
  add("coords",   "cx=" .. (s.cx or 0), "cy=" .. (s.cy or 0))
  return table.concat(parts, "|")
end

--- @param payload string|nil The CARD body.
--- @return table|nil card Decoded identity/location/M+/gear card, or nil.
function Snapshot.DecodeCard(payload)
  local kv = parseKV(payload)
  if not kv then return nil end
  local function num(key, default) return tonumber(kv[key]) or default end

  local vr, vm, vw = 0, 0, 0
  if kv.vault then
    vr, vm, vw = kv.vault:match("^(%d+)/(%d+)/(%d+)$")
    vr, vm, vw = tonumber(vr) or 0, tonumber(vm) or 0, tonumber(vw) or 0
  end

  return {
    cls     = kv.cls or "",
    spec    = num("spec", 0),
    lvl     = num("lvl", 0),
    ilvl    = num("ilvl", 0),
    key     = kv.key or "",
    klvl    = num("klvl", 0),
    vr = vr, vm = vm, vw = vw,
    zone    = kv.zone or "",
    rest    = kv.rest == "1",
    gold    = num("gold", 0),
    enchMask = num("ench", 0),
    gemMiss  = num("gem", 0),
    durSlot  = num("dslot", 0),
    durLowN  = num("dlow", 0),
    pots     = num("pots", 0),
    hs       = num("hs", 0),
    foodCount = num("feast", 0),
    cx       = num("cx", 0),
    cy       = num("cy", 0),
  }
end

-- ---------------------------------------------------------------------------
-- STATS: persistent shared duo counters (see SharedStats.lua). Reads from the
-- per-character saved store ns.chardb.stats.
-- ---------------------------------------------------------------------------
--- @return string payload Pipe-delimited STATS body from ns.chardb.stats.
function Snapshot.EncodeStats()
  local s = (ns.chardb and ns.chardb.stats) or {}
  local parts = {
    "bosses="   .. (s.bosses or 0),
    "dungeons=" .. (s.dungeons or 0),
    "mplus="    .. (s.mplus or 0),
    "tt="       .. math.floor(s.togetherTime or 0),
    "wipes="    .. (s.wipes or 0),
    "quests="   .. (s.quests or 0),
    "deaths="   .. (s.deaths or 0),
    "mobs="     .. (s.mobs or 0),
    "achv="     .. (s.achievements or 0),
    "levels="   .. (s.levels or 0),
  }
  return table.concat(parts, "|")
end

--- @param payload string|nil The STATS body.
--- @return table|nil stats Decoded duo counters, or nil.
function Snapshot.DecodeStats(payload)
  local kv = parseKV(payload)
  if not kv then return nil end
  local function num(key) return tonumber(kv[key]) or 0 end
  return {
    bosses = num("bosses"), dungeons = num("dungeons"), mplus = num("mplus"),
    togetherTime = num("tt"), wipes = num("wipes"),
    quests = num("quests"), deaths = num("deaths"), mobs = num("mobs"),
    achievements = num("achv"), levels = num("levels"),
  }
end

-- ---------------------------------------------------------------------------
-- PRIV: the privacy manifest. We send the list of keys we are NOT sharing (absence
-- = sharing), so the partner can render "hidden" states instead of "stuck loading".
-- ---------------------------------------------------------------------------
--- @return string payload "hidden=k1,k2,..." (empty list when sharing everything).
function Snapshot.EncodePrivacy()
  local hidden = {}
  for _, key in ipairs(ns.PRIVACY_KEYS) do
    if not ns.Shares(key) then hidden[#hidden + 1] = key end
  end
  return "hidden=" .. table.concat(hidden, ",")
end

--- @param payload string|nil The PRIV body.
--- @return table hidden Set of hidden keys ({} when the partner shares everything).
function Snapshot.DecodePrivacy(payload)
  local set = {}
  local kv = parseKV(payload)
  local list = kv and kv.hidden
  if list and list ~= "" then
    for key in list:gmatch("[^,]+") do set[key] = true end
  end
  return set
end

-- ---------------------------------------------------------------------------
-- Verdict (spec §8.2). Returns "ready" | "amber" | "red" plus a list of issues.
-- A failed *blocking* check => red; a failed *advisory* check => amber.
-- "questMismatch" is evaluated against our own super-tracked quest.
-- ---------------------------------------------------------------------------
--- @param snap table A partner snapshot.
--- @param db table|nil Config table (defaults to ns.db).
--- @return string worst "ready" | "amber" | "red".
--- @return table issues List of { key=, severity= } failures.
function Snapshot.ComputeVerdict(snap, db)
  db = db or ns.db
  local checks     = db.checks
  local thresholds = db.thresholds
  local issues = {}        -- { {key=, severity=}, ... }
  local worst  = "ready"   -- escalates to amber then red

  local function fail(key)
    local severity = checks[key] == "blocking" and "red" or "amber"
    table.insert(issues, { key = key, severity = severity })
    if severity == "red" then
      worst = "red"
    elseif worst == "ready" then
      worst = "amber"
    end
  end

  -- A field the partner has chosen not to share isn't a failure — we simply have no
  -- information, so skip its check rather than flagging a false "missing"/red.
  local function shared(key) return ns.PartnerShares(key) end
  if shared("durability") and (snap.dur or 100) < thresholds.durability then fail("durability") end
  if shared("flask") and not snap.flask then fail("flask") end
  if shared("food")  and not snap.food  then fail("food") end
  if shared("bags")  and (snap.bags or 0) <= 0 then fail("bags") end
  if shared("wpn")   and not snap.wpn  then fail("wpn") end
  if shared("rune")  and not snap.rune then fail("rune") end

  -- Quest mismatch: compare partner's broadcast quest with our super-tracked one.
  local myQuest = (C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID
    and C_SuperTrack.GetSuperTrackedQuestID()) or 0
  if shared("quest") and myQuest ~= 0 and (snap.qid or 0) ~= 0 and myQuest ~= snap.qid then
    fail("questMismatch")
  end

  return worst, issues
end

return Snapshot
