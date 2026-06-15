--[[ Pairing.lua
  Invite-and-accept pairing by character name, persisted across sessions.

  Flow (works over WHISPER — no party required):
    Player A: /dr invite Amy          -> whispers an INVITE to Amy
    Player B: popup "Peavers wants to pair"  [Accept] [Decline]
              (or /dr accept)          -> bonds + whispers ACCEPT back
    Player A: receives ACCEPT          -> bonds
  Both save the partner's full name to DuoReadyCharDB and auto-reconnect every
  login. Only the bonded partner's HELLO/SNAP/CARD are accepted (Comm gate).
]]

local addonName, ns = ...

local Pairing = {}
ns.Pairing = Pairing

local pendingInviteTo = nil   -- name we invited (awaiting their ACCEPT)
local pendingInviteFrom = nil -- name that invited us (for /dr accept fallback)

local function shortName(n) return n and n:match("^[^-]+") or n end
Pairing.ShortName = shortName

-- Build a full "Name-Realm" target. If the user typed a bare name, attach our
-- own normalized realm (works for same-realm and connected-realm partners).
local function fullName(name)
  if not name or name == "" then return nil end
  if name:find("-") then return name end
  local realm = GetNormalizedRealmName and GetNormalizedRealmName()
  if realm and realm ~= "" then return name .. "-" .. realm end
  return name
end

local function myFullName()
  local n = UnitName("player")
  local r = GetNormalizedRealmName and GetNormalizedRealmName()
  if r and r ~= "" then return n .. "-" .. r end
  return n
end

-- ---------------------------------------------------------------------------
-- Bond accessors
-- ---------------------------------------------------------------------------
function Pairing.PartnerName()
  return ns.chardb and ns.chardb.pair and ns.chardb.pair.partnerName
end

function Pairing.IsBonded(sender)
  local p = Pairing.PartnerName()
  if not p or not sender then return false end
  return shortName(p) == shortName(sender)
end

-- ---------------------------------------------------------------------------
-- Bonding
-- ---------------------------------------------------------------------------
local function bondTo(fullPartner)
  ns.chardb.pair = ns.chardb.pair or {}
  ns.chardb.pair.partnerName = fullPartner
  ns.state.partnerName = shortName(fullPartner)
  ns.state.linked = true
  pendingInviteTo, pendingInviteFrom = nil, nil
  ns:Print("paired with |cff44ff44" .. shortName(fullPartner) .. "|r (saved — auto-reconnects each login)")
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
function Pairing.Invite(name)
  local target = fullName(name)
  if not target then
    ns:Print("usage: |cffffff00/dr invite CharacterName|r")
    return
  end
  if shortName(target) == UnitName("player") then
    ns:Print("you can't pair with yourself (try |cffffff00/dr selftest|r for that).")
    return
  end
  pendingInviteTo = target
  ns.Comm.WhisperTo(target, "INVITE|" .. myFullName())
  ns:Print("invite sent to |cffffff00" .. shortName(target) .. "|r — waiting for them to accept…")
end

function Pairing.Accept()
  if not pendingInviteFrom then
    ns:Print("no pending invite to accept.")
    return
  end
  local from = pendingInviteFrom
  ns.Comm.WhisperTo(from, "ACCEPT|" .. myFullName())
  bondTo(from)
end

function Pairing.Decline()
  if not pendingInviteFrom then return end
  ns.Comm.WhisperTo(pendingInviteFrom, "DECLINE|" .. myFullName())
  ns:Print("declined invite from " .. shortName(pendingInviteFrom))
  pendingInviteFrom = nil
end

function Pairing.Unpair()
  if Pairing.PartnerName() and ns.Comm then ns.Comm.SendBye() end
  ns.chardb.pair = nil
  ns.state.linked = false
  ns.state.partner = nil
  ns.state.partnerName = nil
  pendingInviteTo, pendingInviteFrom = nil, nil
  ns:Print("unpaired. Run |cffffff00/dr invite <name>|r to pair again.")
  if ns.Dashboard then ns.Dashboard.Refresh() end
end

-- ---------------------------------------------------------------------------
-- Accept/Decline confirmation popup
-- ---------------------------------------------------------------------------
StaticPopupDialogs["DUOREADY_INVITE"] = {
  text = "|cff66ccffDuoReady|r\n%s wants to pair readiness dashboards with you.",
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
    ns:Print("|cffffff00" .. shortName(from) .. "|r wants to pair. Accept with |cffffff00/dr accept|r or use the popup.")
    StaticPopup_Show("DUOREADY_INVITE", shortName(from))

  elseif mtype == "ACCEPT" then
    local from = rest:match("^(.+)$") or sender
    -- Bond if this is who we invited (or, leniently, anyone if we have a pending invite).
    if pendingInviteTo and Pairing.IsBonded and shortName(pendingInviteTo) == shortName(from) then
      bondTo(from)
    elseif pendingInviteTo then
      bondTo(from)
    end

  elseif mtype == "DECLINE" then
    local from = rest:match("^(.+)$") or sender
    if pendingInviteTo and shortName(pendingInviteTo) == shortName(from) then
      ns:Print("|cffff8800" .. shortName(from) .. "|r declined your pair invite.")
      pendingInviteTo = nil
    end
  end
end

-- ---------------------------------------------------------------------------
-- Resume a saved bond on login.
-- ---------------------------------------------------------------------------
function Pairing.Resume()
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
