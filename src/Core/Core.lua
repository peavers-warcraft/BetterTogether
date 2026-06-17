--[[ Core.lua
  BetterTogether — Partner Readiness Dashboard
  Addon namespace, event dispatch, saved variables, init, slash commands.

  Architecture (see BetterTogether-Spec.md §3, §5):
    - `BetterTogether` is a global runtime-state table (matches spec naming).
    - `ns` is the private addon namespace shared across files; modules hang off it.
    - A single hidden event frame fans events out to per-event handler lists that
      modules register via ns:RegisterEvent(event, handler).
]]

local addonName, ns = ...

-- Global runtime state (spec §5). Kept global so /dump and the spec's naming work.
BetterTogether = {
  self        = {},     -- own live readiness, recomputed on relevant events
  partner     = nil,    -- last decoded SNAP from partner (+ lastSeen)
  linked      = false,  -- true once HELLO handshake completed
  partnerName = nil,
}
ns.state = BetterTogether

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
ns.PREFIX      = "BetterTogether"
ns.VERSION     = "1.0.0"
ns.PROTO       = 1            -- wire protocol version (the <version> token)
ns.CHANNEL     = "PARTY"
ns.STALE_AFTER = 30           -- seconds without a SNAP before partner panel dims (§5)
ns.OFFLINE_AFTER = 50         -- seconds of total silence before we treat the partner as logged off

-- ---------------------------------------------------------------------------
-- Saved-variable defaults
-- ---------------------------------------------------------------------------
-- Account-wide config (BetterTogetherDB).
local DB_DEFAULTS = {
  scale       = 1.0,
  locked      = false,
  debug       = false,
  expanded    = true,         -- full-page view (vs collapsed compact card)
  toasts      = true,         -- slide-in notifications on partner presence/readiness
  toastSound  = true,         -- play a soft sound with each toast
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
  -- Privacy: which data we broadcast to the partner. Every key defaults to true
  -- (share), so existing users and any future field keep today's behaviour until
  -- they opt out. Keys are consumed by Snapshot/Comm encoders via ns.Shares().
  privacy = {
    -- Readiness (SNAP)
    durability = true, bags = true, flask = true, food = true,
    wpn = true, rune = true, hp = true, quest = true,
    -- Character card (CARD)
    identity = true,  -- class / spec / level / item level
    gear     = true,  -- enchants / empty sockets / durability detail
    keystone = true,  -- Mythic+ keystone
    vault    = true,  -- Great Vault progress
    location = true,  -- zone / resting
    coords   = true,  -- map coordinates
    gold     = true,
    supplies = true,  -- potions / healthstone / food count
    -- Counters & bulk (STATS / INV / QLOG / ACHV)
    stats        = true,
    inventory    = true,
    questlog     = true,
    achievements = true,
  },
}

-- Per-character config (BetterTogetherCharDB) — frame position lives here (§8.4).
local CHARDB_DEFAULTS = {
  point = { "CENTER", nil, "CENTER", 0, 120 },
  lastTab = "overview",         -- remembered left-nav page in the shell
  lastMainTab = "dashboard",    -- remembered bottom tab: "dashboard" | "settings"
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

-- Canonical ordered list of privacy keys (mirrors DB_DEFAULTS.privacy). Used to
-- encode/decode the privacy manifest we exchange with the partner so each side can
-- explain *why* a field is blank rather than spinning forever.
ns.PRIVACY_KEYS = {
  "durability", "bags", "flask", "food", "wpn", "rune", "hp", "quest",
  "identity", "gear", "keystone", "vault", "location", "coords", "gold", "supplies",
  "stats", "inventory", "questlog", "achievements",
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
local PREFIX_TAG = "|cff66ccffBetterTogether|r: "
function ns:Print(...)
  print(PREFIX_TAG .. table.concat({ ... }, " "))
end

function ns:Debug(...)
  if ns.db and ns.db.debug then
    print("|cff999999[BetterTogether dbg]|r", ...)
  end
end

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------
local handlers = {}          -- event -> { handler, ... }
local frame = CreateFrame("Frame", "BetterTogetherEventFrame")
ns.frame = frame

-- Register a handler for a game event. Handlers receive (event, ...).
function ns:RegisterEvent(event, handler)
  if not handlers[event] then
    -- An unknown/renamed event makes frame:RegisterEvent throw (and on modern
    -- clients can raise ADDON_ACTION_FORBIDDEN), which would abort the rest of the
    -- calling module's main chunk. Isolate it — same spirit as the handler pcall in
    -- OnEvent — so one bad event name can't stop the addon from loading/rendering.
    local ok, err = pcall(frame.RegisterEvent, frame, event)
    if not ok then
      ns:Print("|cffff5555cannot register event " .. tostring(event) .. ":|r " .. tostring(err))
      return
    end
    handlers[event] = {}
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
-- Privacy gate: do we share `key` with the partner? Defaults to true so a missing
-- or newly-added field is never silently withheld. The Snapshot/Comm encoders ask
-- this before emitting each field; the Settings tab (src/UI/SettingsTab.lua)
-- flips the flags in ns.db.privacy.
-- ---------------------------------------------------------------------------
--- @param key string A privacy key (see DB_DEFAULTS.privacy).
--- @return boolean shared
function ns.Shares(key)
  local p = ns.db and ns.db.privacy
  if not p then return true end
  local v = p[key]
  if v == nil then return true end
  return v and true or false
end

-- Does the *partner* share `key` with us? Reads the manifest they broadcast (PRIV);
-- ns.state.partnerPrivacy is a set of the keys they've hidden. Defaults to true so a
-- partner on an older build (who never sends PRIV) is assumed to share everything.
--- @param key string A privacy key (see PRIVACY_KEYS).
--- @return boolean shared
function ns.PartnerShares(key)
  local hidden = ns.state.partnerPrivacy
  if not hidden then return true end
  return not hidden[key]
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
local function onAddonLoaded(_, loaded)
  if loaded ~= addonName then return end

  BetterTogetherDB     = applyDefaults(BetterTogetherDB or {}, DB_DEFAULTS)
  BetterTogetherCharDB = applyDefaults(BetterTogetherCharDB or {}, CHARDB_DEFAULTS)
  ns.db     = BetterTogetherDB
  ns.chardb = BetterTogetherCharDB

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

  -- Pre-warm the achievement scan in the background a few seconds after login (once
  -- the login burst has settled) so the Achievements tab opens to ready data instead of
  -- kicking off the scan — and its loading delay — on the user's first click.
  if ns.AchvSync and ns.AchvSync.Ensure and C_Timer and C_Timer.After then
    C_Timer.After(4, function() ns.AchvSync.Ensure() end)
  end

  ns:Print(ns.L["loaded v"] .. ns.VERSION .. ns.L[". Type |cffffff00/bt|r for options."])
end

ns:RegisterEvent("ADDON_LOADED", onAddonLoaded)
ns:RegisterEvent("PLAYER_LOGIN", onPlayerLogin)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
SLASH_BETTERTOGETHER1 = "/bettertogether"
SLASH_BETTERTOGETHER2 = "/bt"
SlashCmdList["BETTERTOGETHER"] = function(msg)
  local L = ns.L
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  -- Split into command + argument; only the command is case-folded so character
  -- names in `arg` keep their original capitalization.
  local cmd, arg = msg:match("^(%S+)%s*(.-)$")
  cmd = (cmd or ""):lower()

  if cmd == "lock" then
    ns.db.locked = not ns.db.locked
    if ns.Dashboard then ns.Dashboard.ApplyLock() end
    ns:Print("panel " .. (ns.db.locked and "locked" or "unlocked"))

  elseif cmd == "collapse" or cmd == "expand" then
    ns.db.expanded = not ns.db.expanded
    if ns.Dashboard then ns.Dashboard.ApplyMode() end
    ns:Print("view: " .. (ns.db.expanded and "expanded" or "compact"))

  elseif cmd == "stats" then
    if ns.Dashboard then ns.Dashboard.OpenTab("statistics") end

  elseif cmd == "privacy" then
    if ns.Dashboard then ns.Dashboard.OpenSettings() end

  elseif cmd == "invite" then
    if ns.Pairing then ns.Pairing.Invite(arg) end

  elseif cmd == "accept" then
    if ns.Pairing then ns.Pairing.Accept() end

  elseif cmd == "decline" then
    if ns.Pairing then ns.Pairing.Decline() end

  elseif cmd == "unpair" then
    if ns.Pairing then ns.Pairing.Unpair() end

  elseif cmd == "partners" or cmd == "list" then
    if ns.Pairing then
      local roster, active = ns.Pairing.Roster(), ns.Pairing.PartnerName()
      if #roster == 0 then
        ns:Print("no saved partners — |cffffff00/bt invite <name>|r to add one.")
      else
        ns:Print("partners:")
        for _, full in ipairs(roster) do
          local s = ns.Pairing.ShortName(full)
          local mark = (active and ns.Pairing.ShortName(active) == s) and " |cff44ff44(active)|r" or ""
          ns:Print("  • " .. s .. mark)
        end
      end
    end

  elseif cmd == "switch" then
    if ns.Pairing then ns.Pairing.SetActive(arg) end

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

  elseif cmd == "auras" then
    -- Diagnostic: list the player's helpful auras (name = spellId). Use this with a
    -- flask/food/rune active to capture exact spellIDs for src/Core/Consumables.lua.
    ns:Print("helpful auras (name = spellId):")
    local function dump(a)
      if a and a.spellId then ns:Print("  " .. tostring(a.name) .. " = |cffffff00" .. tostring(a.spellId) .. "|r") end
    end
    if AuraUtil and AuraUtil.ForEachAura then
      AuraUtil.ForEachAura("player", "HELPFUL", nil, function(a) dump(a); return false end, true)
    elseif C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
      for i = 1, 60 do
        local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
        if not a then break end
        dump(a)
      end
    end

  elseif cmd == "toast" then
    -- Preview the partner-presence notification without needing a live state change.
    if ns.UI and ns.UI.Toast then
      local T, V = ns.UI.Toast, ns.UI.Theme and ns.UI.Theme.VERDICT_RGB
      local who = ns.state.partnerName or L["Partner"]
      T.Show({ title = string.format(L["%s is ready"], who), subtitle = L["All checks passed — good to pull."],
        icon = "Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend",
        color = V and V.ready, sound = SOUNDKIT and SOUNDKIT.READY_CHECK })
    end

  elseif cmd == "debug" then
    ns.db.debug = not ns.db.debug
    ns:Print("debug " .. (ns.db.debug and "ON" or "OFF"))

  elseif cmd == "scaleinfo" then
    if ns.UI.Scaling and ns.UI.Scaling.PrintScaleInfo then ns.UI.Scaling.PrintScaleInfo() end

  elseif cmd == "help" or cmd == "" and false then
    -- (falls through to default below)

  else
    if ns.Settings and ns.Settings.Open and cmd == "" then
      ns.Settings.Open()
    else
      ns:Print(L["commands:"])
      ns:Print("  |cffffff00/bt invite <name>|r — " .. L["pair with a partner"] .. "   |cffffff00/bt accept|r / |cffffff00/bt decline|r")
      ns:Print("  |cffffff00/bt partners|r — " .. L["list saved partners"] .. "   |cffffff00/bt switch <name>|r — " .. L["make one active"])
      ns:Print("  |cffffff00/bt unpair|r · |cffffff00/bt sync|r · |cffffff00/bt lock|r · |cffffff00/bt show|r/|cffffff00hide|r · |cffffff00/bt reset|r")
      ns:Print("  |cffffff00/bt privacy|r — " .. L["choose what to share with your partner"])
      ns:Print("  |cffffff00/bt test|r (loopback) · |cffffff00/bt selftest|r · |cffffff00/bt toast|r · |cffffff00/bt auras|r · |cffffff00/bt debug|r · |cffffff00/bt|r (" .. L["options"] .. ")")
    end
  end
end
