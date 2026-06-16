--[[ Pairing.lua
  Invite-and-accept pairing by character name, persisted across sessions.

  Flow (works over WHISPER — no party required):
    Player A: /bt invite Amy          -> whispers an INVITE to Amy
    Player B: popup "Peavers wants to pair"  [Accept] [Decline]
              (or /bt accept)          -> bonds + whispers ACCEPT back
    Player A: receives ACCEPT          -> bonds
  Both save the partner's full name to BetterTogetherCharDB and auto-reconnect every
  login. Only the bonded partner's HELLO/SNAP/CARD are accepted (Comm gate).
]]

local addonName, ns = ...
local L = ns.L

local Pairing = {}
ns.Pairing = Pairing

local pendingInviteTo = nil   -- name we invited (awaiting their ACCEPT)
local pendingInviteFrom = nil -- name that invited us (for /bt accept fallback)

-- Name/identity helpers live in ns.Util (shared with Comm). Aliased locally for
-- brevity; ShortName stays exposed on the module for Core's slash commands + Dashboard.
local shortName  = ns.Util.ShortName
local fullName   = ns.Util.FullName
local myFullName = ns.Util.MyFullName
Pairing.ShortName = shortName

-- ---------------------------------------------------------------------------
-- Roster store + migration
--   chardb.pair = { active = "Amy-Realm", roster = { "Amy-Realm", "Bob-Realm" } }
--   active = the one partner whose data we send/accept right now (the bond gate).
--   roster = every partner we've ever bonded, so switching back is one click and
--            never makes you re-type a Name-Realm.
-- ---------------------------------------------------------------------------
local function ensureDB()
  ns.chardb.pair = ns.chardb.pair or {}
  local p = ns.chardb.pair
  -- Migrate the old single-slot field (pre-roster saves).
  if p.partnerName and not p.roster then
    p.roster = { p.partnerName }
    p.active = p.partnerName
    p.partnerName = nil
  end
  p.roster = p.roster or {}
  return p
end

-- Add a full Name-Realm to the roster (no duplicates, case-insensitive on short name).
local function rosterAdd(full)
  local p = ensureDB()
  for _, n in ipairs(p.roster) do
    if shortName(n) == shortName(full) then return end
  end
  p.roster[#p.roster + 1] = full
end

-- ---------------------------------------------------------------------------
-- Bond accessors
-- ---------------------------------------------------------------------------
function Pairing.PartnerName()
  return ns.chardb and ns.chardb.pair and ns.chardb.pair.active
end

-- The saved roster (array of full Name-Realm strings). Always safe to iterate.
function Pairing.Roster()
  return (ns.chardb and ns.chardb.pair and ns.chardb.pair.roster) or {}
end

--- Resolve a name to the stored full Name-Realm if it's anywhere in the roster
--- (matched by short name), else nil. Used for presence pings, which target any
--- saved partner — not just the active one IsBonded gates.
--- @param name string|nil A character name (short or full).
--- @return string|nil full The stored "Name-Realm", or nil if not a saved partner.
function Pairing.InRoster(name)
  if not name then return nil end
  local short = shortName(name)
  for _, n in ipairs(Pairing.Roster()) do
    if shortName(n) == short then return n end
  end
  return nil
end

--- Is `sender` our currently-active bonded partner (by short name)?
--- @param sender string|nil A character name (short or full).
--- @return boolean
function Pairing.IsBonded(sender)
  local p = Pairing.PartnerName()
  if not p or not sender then return false end
  return shortName(p) == shortName(sender)
end

-- ---------------------------------------------------------------------------
-- Bonding
-- ---------------------------------------------------------------------------
local function bondTo(fullPartner)
  local p = ensureDB()
  rosterAdd(fullPartner)
  p.active = fullPartner
  ns.state.partner = nil   -- drop any prior partner's runtime data
  ns.state.partnerPrivacy = nil
  ns.state.partnerName = shortName(fullPartner)
  ns.state.linked = true
  pendingInviteTo, pendingInviteFrom = nil, nil
  ns:Print(L["paired with "] .. "|cff44ff44" .. shortName(fullPartner) .. "|r " .. L["(saved — auto-reconnects each login)"])
  if ns.Comm then
    ns.Comm.SendHello()
    ns.Comm.QueueSnapshot(true)
    ns.Comm.QueueCard(true)
  end
  if ns.Dashboard then ns.Dashboard.Refresh() end
end

-- ---------------------------------------------------------------------------
-- Public commands
-- ---------------------------------------------------------------------------
--- Send a pair invite (whisper) to a character by name.
--- @param name string A bare or "Name-Realm" character name.
function Pairing.Invite(name)
  local target = fullName(name)
  if not target then
    ns:Print(L["usage: "] .. "|cffffff00/bt invite CharacterName|r")
    return
  end
  if shortName(target) == UnitName("player") then
    ns:Print(L["you can't pair with yourself (try "] .. "|cffffff00/bt selftest|r" .. L[" for that)."])
    return
  end
  pendingInviteTo = target
  ns.Comm.WhisperTo(target, "INVITE|" .. myFullName())
  ns:Print(L["invite sent to "] .. "|cffffff00" .. shortName(target) .. "|r " .. L["— waiting for them to accept…"])
end

function Pairing.Accept()
  if not pendingInviteFrom then
    ns:Print(L["no pending invite to accept."])
    return
  end
  local from = pendingInviteFrom
  ns.Comm.WhisperTo(from, "ACCEPT|" .. myFullName())
  bondTo(from)
end

function Pairing.Decline()
  if not pendingInviteFrom then return end
  ns.Comm.WhisperTo(pendingInviteFrom, "DECLINE|" .. myFullName())
  ns:Print(L["declined invite from "] .. shortName(pendingInviteFrom))
  pendingInviteFrom = nil
end

-- Remove a partner from the roster entirely (forget them). If they were the
-- active partner, also tears down the live bond.
function Pairing.RemoveFromRoster(full)
  local p = ensureDB()
  for i, n in ipairs(p.roster) do
    if shortName(n) == shortName(full) then table.remove(p.roster, i); break end
  end
  if p.active and shortName(p.active) == shortName(full) then
    if ns.Comm then ns.Comm.SendBye() end
    p.active = nil
    ns.state.linked = false
    ns.state.partner = nil
    ns.state.partnerPrivacy = nil
    ns.state.partnerName = nil
  end
  ns:Print(L["removed "] .. "|cffff8800" .. shortName(full) .. "|r " .. L["from your partners."])
  if ns.Dashboard then ns.Dashboard.Refresh() end
end

-- Unpair the *currently active* partner (and forget them).
function Pairing.Unpair()
  local active = Pairing.PartnerName()
  if not active then return end
  Pairing.RemoveFromRoster(active)
end

-- ---------------------------------------------------------------------------
-- Switch which roster partner is active (the wife <-> old-friend flip).
--   `full` is a Name-Realm already in the roster. After this returns, the bond
--   gate (IsBonded) must accept `full` and reject everyone else, and the
--   dashboard must show fresh data for `full` (not the previous partner's).
--
-- DESIGN DECISION (yours): what should switching *do* to the old partner?
--   - Do we SendBye() to the person we're switching away from? They stay in our
--     roster, so a Bye says "I stopped sharing for now" — honest, but they get a
--     "partner left" blip every time you toggle. Or we switch silently and only
--     Bye on a real RemoveFromRoster.
--   - We MUST clear ns.state.partner so the old partner's snapshot/achievements
--     don't linger on the dashboard under the new partner's name.
--   - We then HELLO + request a fresh snapshot from `full` (see bondTo for the
--     Comm calls), so their data starts flowing.
--   - Guard: ignore if `full` isn't in the roster, or is already active.
-- ---------------------------------------------------------------------------
function Pairing.SetActive(full)
  local p = ensureDB()
  if not full then return end
  -- Must be a known roster member; resolve to the stored full Name-Realm.
  local resolved
  for _, n in ipairs(p.roster) do
    if shortName(n) == shortName(full) then resolved = n; break end
  end
  if not resolved then
    ns:Print("|cffff8800" .. shortName(full) .. "|r " .. L["isn't in your partners list."])
    return
  end
  if p.active and shortName(p.active) == shortName(resolved) then return end  -- already active

  -- Silent switch: no Bye to the previous partner (they stay in the roster, so
  -- toggling back and forth shouldn't blip them with "partner left"). A Bye is
  -- only sent on a real RemoveFromRoster.
  p.active = resolved
  ns.state.partner = nil          -- drop the old partner's snapshot/achievements
  ns.state.partnerPrivacy = nil
  ns.state.partnerName = shortName(resolved)
  ns.state.linked = true
  ns:Print(L["now sharing with "] .. "|cff44ff44" .. shortName(resolved) .. "|r")
  if ns.Comm then
    ns.Comm.SendHello()           -- announce to the new active partner
    ns.Comm.QueueSnapshot(true)   -- push our current state to them
    ns.Comm.QueueCard(true)
    ns.Comm.RequestSnapshot()     -- pull theirs
  end
  if ns.Dashboard then ns.Dashboard.Refresh() end
end

-- ---------------------------------------------------------------------------
-- Accept/Decline confirmation popup
-- ---------------------------------------------------------------------------
StaticPopupDialogs["BETTERTOGETHER_INVITE"] = {
  text = "|cff66ccffBetterTogether|r\n" .. L["%s wants to pair readiness dashboards with you."],
  button1 = ACCEPT or "Accept",
  button2 = DECLINE or "Decline",
  OnAccept = function() Pairing.Accept() end,
  OnCancel = function() Pairing.Decline() end,
  timeout = 60,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- ---------------------------------------------------------------------------
-- Inbound INVITE / ACCEPT / DECLINE (routed here by Comm before the bond gate)
-- ---------------------------------------------------------------------------
function Pairing.OnMessage(mtype, rest, sender)
  if mtype == "INVITE" then
    local from = rest:match("^(.+)$") or sender
    pendingInviteFrom = from
    ns:Print("|cffffff00" .. shortName(from) .. "|r " .. L["wants to pair. Accept with "] .. "|cffffff00/bt accept|r" .. L[" or use the popup."])
    StaticPopup_Show("BETTERTOGETHER_INVITE", shortName(from))

  elseif mtype == "ACCEPT" then
    local from = rest:match("^(.+)$") or sender
    -- Bond if we have a pending invite out. We accept leniently from anyone we
    -- have an outstanding invite to (the handshake itself proves intent).
    if pendingInviteTo then bondTo(from) end

  elseif mtype == "DECLINE" then
    local from = rest:match("^(.+)$") or sender
    if pendingInviteTo and shortName(pendingInviteTo) == shortName(from) then
      ns:Print("|cffff8800" .. shortName(from) .. "|r " .. L["declined your pair invite."])
      pendingInviteTo = nil
    end
  end
end

-- ---------------------------------------------------------------------------
-- Resume a saved bond on login.
-- ---------------------------------------------------------------------------
function Pairing.Resume()
  ensureDB()   -- migrate old single-slot saves into the roster on first login
  local p = Pairing.PartnerName()
  if not p then return end
  ns.state.partnerName = shortName(p)
  ns:Debug("resuming saved bond with " .. p)
  if ns.Comm then
    ns.Comm.SendHello()
    ns.Comm.RequestSnapshot()
  end
end

return Pairing
