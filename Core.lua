--[[ Core.lua
  DuoReady — Partner Readiness Dashboard
  Addon namespace, event dispatch, saved variables, init, slash commands.

  Architecture (see DuoReady-Spec.md §3, §5):
    - `DuoReady` is a global runtime-state table (matches spec naming).
    - `ns` is the private addon namespace shared across files; modules hang off it.
    - A single hidden event frame fans events out to per-event handler lists that
      modules register via ns:RegisterEvent(event, handler).
]]

local addonName, ns = ...

-- Global runtime state (spec §5). Kept global so /dump and the spec's naming work.
DuoReady = {
  self        = {},     -- own live readiness, recomputed on relevant events
  partner     = nil,    -- last decoded SNAP from partner (+ lastSeen)
  linked      = false,  -- true once HELLO handshake completed
  partnerName = nil,
}
ns.state = DuoReady

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
ns.PREFIX      = "DuoReady"
ns.VERSION     = "1.0.0"
ns.PROTO       = 1            -- wire protocol version (the <version> token)
ns.CHANNEL     = "PARTY"
ns.STALE_AFTER = 30           -- seconds without a SNAP before partner panel dims (§5)

-- ---------------------------------------------------------------------------
-- Saved-variable defaults
-- ---------------------------------------------------------------------------
-- Account-wide config (DuoReadyDB).
local DB_DEFAULTS = {
  scale       = 1.0,
  locked      = false,
  demoMode    = false,
  debug       = false,
  expanded    = true,         -- full-page view (vs collapsed compact card)
  pinnedQuestID = nil,        -- nil => broadcast the super-tracked quest
  thresholds  = {
    durability = 30,          -- percent; below this => blocking red (§8.2)
    bagsLow    = 4,           -- advisory amber when free slots <= this
  },
  -- Which checks are "blocking" (red on fail) vs "advisory" (amber on fail). §8.2
  checks = {
    durability    = "blocking",
    flask         = "blocking",
    food          = "blocking",
    bags          = "blocking",
    wpn           = "advisory",
    rune          = "advisory",
    questMismatch = "advisory",
  },
  -- Which rows are visible in the dashboard.
  show = {
    durability = true,
    flask      = true,
    food       = true,
    wpn        = true,
    rune       = true,
    bags       = true,
    quest      = true,
  },
}

-- Per-character config (DuoReadyCharDB) — frame position lives here (§8.4).
local CHARDB_DEFAULTS = {
  point = { "CENTER", nil, "CENTER", 0, 120 },
  lastTab = "overview",         -- remembered tab in the shell
  -- Persistent shared duo statistics (see SharedStats.lua).
  stats = {
    -- shared (both observe the same event; max-merged to stay in sync)
    bosses = 0, dungeons = 0, mplus = 0, togetherTime = 0, wipes = 0,
    firstTogether = 0,          -- earliest "grouped together" timestamp (min-merged)
    mplusRuns = {},             -- { {map=, level=, onTime=, ts=}, ... } capped
    -- personal (each tracks own; shown side-by-side)
    quests = 0, deaths = 0, mobs = 0, achievements = 0, levels = 0,
  },
}

-- Recursively fill missing keys in `dst` from `src`.
local function applyDefaults(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      applyDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end

-- ---------------------------------------------------------------------------
-- Lightweight logging
-- ---------------------------------------------------------------------------
local PREFIX_TAG = "|cff66ccffDuoReady|r: "
function ns:Print(...)
  print(PREFIX_TAG .. table.concat({ ... }, " "))
end

function ns:Debug(...)
  if ns.db and ns.db.debug then
    print("|cff999999[DuoReady dbg]|r", ...)
  end
end

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------
local handlers = {}          -- event -> { handler, ... }
local frame = CreateFrame("Frame", "DuoReadyEventFrame")
ns.frame = frame

-- Register a handler for a game event. Handlers receive (event, ...).
function ns:RegisterEvent(event, handler)
  if not handlers[event] then
    handlers[event] = {}
    frame:RegisterEvent(event)
  end
  table.insert(handlers[event], handler)
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for _, handler in ipairs(list) do
    -- Isolate handler errors so one module crashing can't break the others.
    local ok, err = pcall(handler, event, ...)
    if not ok then
      ns:Print("|cffff5555error in " .. event .. ":|r " .. tostring(err))
    end
  end
end)

-- ---------------------------------------------------------------------------
-- Combat gate (§9: v1 never operates in combat)
-- ---------------------------------------------------------------------------
function ns:InCombat()
  return InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player"))
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
local function onAddonLoaded(_, loaded)
  if loaded ~= addonName then return end

  DuoReadyDB     = applyDefaults(DuoReadyDB or {}, DB_DEFAULTS)
  DuoReadyCharDB = applyDefaults(DuoReadyCharDB or {}, CHARDB_DEFAULTS)
  ns.db     = DuoReadyDB
  ns.chardb = DuoReadyCharDB

  -- Register the addon-message prefix as early as possible (spec §4.1).
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)
  end

  if ns.Comm     and ns.Comm.Init     then ns.Comm.Init()     end
  if ns.Settings and ns.Settings.Init then ns.Settings.Init() end

  ns:Debug("ADDON_LOADED init complete")
end

local function onPlayerLogin()
  -- Build UI now that saved vars + media are available.
  if ns.Dashboard and ns.Dashboard.Init then ns.Dashboard.Init() end

  -- Compute our own state, then resume any saved pairing (whispers the partner).
  if ns.SelfState and ns.SelfState.Update then ns.SelfState.Update() end
  if ns.Pairing and ns.Pairing.Resume then ns.Pairing.Resume() end

  ns:Print("loaded v" .. ns.VERSION .. ". Type |cffffff00/dr|r for options.")
end

ns:RegisterEvent("ADDON_LOADED", onAddonLoaded)
ns:RegisterEvent("PLAYER_LOGIN", onPlayerLogin)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
SLASH_DUOREADY1 = "/duoready"
SLASH_DUOREADY2 = "/dr"
SlashCmdList["DUOREADY"] = function(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  -- Split into command + argument; only the command is case-folded so character
  -- names in `arg` keep their original capitalization.
  local cmd, arg = msg:match("^(%S+)%s*(.-)$")
  cmd = (cmd or ""):lower()

  if cmd == "lock" then
    ns.db.locked = not ns.db.locked
    if ns.Dashboard then ns.Dashboard.ApplyLock() end
    ns:Print("panel " .. (ns.db.locked and "locked" or "unlocked"))

  elseif cmd == "demo" then
    ns.db.demoMode = not ns.db.demoMode
    if ns.Dashboard then ns.Dashboard.Refresh() end
    ns:Print("demo mode " .. (ns.db.demoMode and "|cff44ff44ON|r" or "OFF"))

  elseif cmd == "collapse" or cmd == "expand" then
    ns.db.expanded = not ns.db.expanded
    if ns.Dashboard then ns.Dashboard.ApplyMode() end
    ns:Print("view: " .. (ns.db.expanded and "expanded" or "compact"))

  elseif cmd == "stats" then
    if ns.Dashboard then ns.Dashboard.OpenTab("statistics") end

  elseif cmd == "readycheck" or cmd == "rc" then
    if ns.Dashboard then ns.Dashboard.OpenTab("readycheck") end
    if ns.Comm and ns.Comm.SendReadyCheck then ns.Comm.SendReadyCheck() end

  elseif cmd == "invite" then
    if ns.Pairing then ns.Pairing.Invite(arg) end

  elseif cmd == "accept" then
    if ns.Pairing then ns.Pairing.Accept() end

  elseif cmd == "decline" then
    if ns.Pairing then ns.Pairing.Decline() end

  elseif cmd == "unpair" then
    if ns.Pairing then ns.Pairing.Unpair() end

  elseif cmd == "show" then
    if ns.Dashboard then ns.Dashboard.Show() end

  elseif cmd == "hide" then
    if ns.Dashboard then ns.Dashboard.Hide() end

  elseif cmd == "reset" then
    wipe(ns.chardb.point)
    for i, v in ipairs(CHARDB_DEFAULTS.point) do ns.chardb.point[i] = v end
    if ns.Dashboard then ns.Dashboard.RestorePosition() end
    ns:Print("panel position reset")

  elseif cmd == "sync" or cmd == "req" then
    if ns.Comm then ns.Comm.RequestSnapshot() end
    ns:Print("requested fresh snapshot from partner")

  elseif cmd == "test" then
    if ns.Comm then ns.Comm.RunLoopbackTest() end

  elseif cmd == "selftest" then
    if ns.Comm then ns.Comm.ToggleSelfTest() end

  elseif cmd == "debug" then
    ns.db.debug = not ns.db.debug
    ns:Print("debug " .. (ns.db.debug and "ON" or "OFF"))

  elseif cmd == "help" or cmd == "" and false then
    -- (falls through to default below)

  else
    if ns.Settings and ns.Settings.Open and cmd == "" then
      ns.Settings.Open()
    else
      ns:Print("commands:")
      ns:Print("  |cffffff00/dr invite <name>|r — pair with a partner   |cffffff00/dr accept|r / |cffffff00/dr decline|r")
      ns:Print("  |cffffff00/dr unpair|r · |cffffff00/dr sync|r · |cffffff00/dr lock|r · |cffffff00/dr demo|r · |cffffff00/dr show|r/|cffffff00hide|r · |cffffff00/dr reset|r")
      ns:Print("  |cffffff00/dr test|r (loopback) · |cffffff00/dr selftest|r · |cffffff00/dr debug|r · |cffffff00/dr|r (options)")
    end
  end
end
