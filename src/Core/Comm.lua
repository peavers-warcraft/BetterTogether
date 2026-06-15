--[[ Comm.lua
  Prefix registration, send/receive, throttle queue, message dispatch, partner
  data exchange (spec §4, §5; pairing in Pairing.lua).

  Channel strategy: bonded comms WHISPER the partner directly (works anywhere,
  no party needed). Confirmed loopback-safe on Midnight 12.0. PARTY remains a
  no-target fallback. Throttle is a token bucket (cap 10, refill 1/sec, §4.2).

  Two data message types so we stay under the ~255-byte addon-message limit and
  can use different cadences:
    SNAP  -> fast-changing readiness (durability, bags, consumables, quest)
    CARD  -> slow-changing identity/location/M+/gear card
]]

local addonName, ns = ...

local Comm = {}
ns.Comm = Comm

local MSG = {
  HELLO = "HELLO", SNAP = "SNAP", CARD = "CARD", REQ = "REQ", BYE = "BYE",
  STATS = "STATS", RCHECK = "RCHECK", RCACK = "RCACK",
  INV = "INV", INVREQ = "INVREQ",
  QLOG = "QLOG", QLOGREQ = "QLOGREQ",
}
local INV_CHUNK = 230
local SNAP_MIN_INTERVAL = 2.0
local CARD_MIN_INTERVAL = 2.0
local STATS_MIN_INTERVAL = 10.0   -- stats change slowly; sync at most every 10s
local RECONNECT_INTERVAL = 20.0   -- retry HELLO while bonded but not yet linked

Comm.selftest = false

-- ---------------------------------------------------------------------------
-- Targeting
-- ---------------------------------------------------------------------------
local function selfFullName()
  local n = UnitName("player")
  local r = GetNormalizedRealmName and GetNormalizedRealmName()
  if r and r ~= "" then return n .. "-" .. r end
  return n
end

-- Where do bonded SNAP/HELLO/CARD go? To the bonded partner over whisper.
local function partnerTarget()
  return ns.Pairing and ns.Pairing.PartnerName()
end

-- ---------------------------------------------------------------------------
-- Token-bucket outbound queue. Entries are { text=, target= }.
-- ---------------------------------------------------------------------------
local bucket = { tokens = 10, max = 10 }
local queue  = {}
local ticker

local function rawSend(entry)
  if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return false end
  local channel, target = ns.CHANNEL, entry.target
  if Comm.selftest then
    channel, target = "WHISPER", selfFullName()
  elseif target then
    channel = "WHISPER"
  end

  local result = C_ChatInfo.SendAddonMessage(ns.PREFIX, entry.text, channel, target)
  if result == nil or result == true then return true end
  if type(result) == "number" and Enum and Enum.SendAddonMessageResult then
    if result == Enum.SendAddonMessageResult.Success then return true end
    if result == Enum.SendAddonMessageResult.AddonMessageThrottle then
      ns:Debug("send throttled by client, re-queueing")
      return false
    end
    ns:Debug("send failed, result=" .. tostring(result))
    return true -- consume so we don't spin
  end
  return true
end

local function refillAndDrain()
  bucket.tokens = math.min(bucket.max, bucket.tokens + 1)
  while bucket.tokens >= 1 and #queue > 0 do
    if rawSend(queue[1]) then
      table.remove(queue, 1)
      bucket.tokens = bucket.tokens - 1
    else
      break
    end
  end
  if #queue == 0 and ticker then ticker:Cancel(); ticker = nil end
end

local function ensureTicker()
  if not ticker then ticker = C_Timer.NewTicker(1.0, refillAndDrain) end
end

local function enqueue(text, target)
  local entry = { text = text, target = target }
  if bucket.tokens >= 1 and #queue == 0 then
    if rawSend(entry) then
      bucket.tokens = bucket.tokens - 1
      return
    end
  end
  table.insert(queue, entry)
  ensureTicker()
end

-- Bonded send (to partner via whisper). No-ops if not bonded and not self-testing.
local function send(text)
  local target = partnerTarget()
  if not target and not Comm.selftest then return end
  enqueue(text, target)
end

-- Public: send a raw whisper to an arbitrary name (used by Pairing for invites).
function Comm.WhisperTo(name, text)
  enqueue(text, name)
end

-- ---------------------------------------------------------------------------
-- Snapshot / card debounce (§4.2)
-- ---------------------------------------------------------------------------
local lastSnapAt, snapPending = 0, false
local lastCardAt, cardPending = 0, false
local lastStatsAt, statsPending = 0, false
local lastSnapSig, lastCardSig, lastStatsSig = nil, nil, nil
local invBuf  -- inbound INV chunk reassembly buffer
local qlogBuf -- inbound QLOG chunk reassembly buffer

local function doSendSnapshot()
  snapPending = false
  if ns:InCombat() then return end
  ns.SelfState.Update()
  local payload = ns.Snapshot.Encode()
  send(MSG.SNAP .. "|" .. ns.PROTO .. "|" .. payload)
  lastSnapAt = GetTime()
  ns:Debug("SNAP sent (" .. #payload .. " chars)")
end

local function doSendCard()
  cardPending = false
  if ns:InCombat() then return end
  ns.SelfState.Update()
  local payload = ns.Snapshot.EncodeCard()
  send(MSG.CARD .. "|" .. ns.PROTO .. "|" .. payload)
  lastCardAt = GetTime()
  ns:Debug("CARD sent (" .. #payload .. " chars)")
end

-- force=true sends even if unchanged (handshake / explicit request).
function Comm.QueueSnapshot(force)
  ns.SelfState.Update()
  local sig = ns.SelfState.SnapSignature()
  if not force and sig == lastSnapSig then return end
  lastSnapSig = sig
  if snapPending then return end
  local elapsed = GetTime() - lastSnapAt
  if elapsed >= SNAP_MIN_INTERVAL then
    doSendSnapshot()
  else
    snapPending = true
    C_Timer.After(SNAP_MIN_INTERVAL - elapsed, doSendSnapshot)
  end
end

function Comm.QueueCard(force)
  ns.SelfState.Update()
  local sig = ns.SelfState.CardSignature()
  if not force and sig == lastCardSig then return end
  lastCardSig = sig
  if cardPending then return end
  local elapsed = GetTime() - lastCardAt
  if elapsed >= CARD_MIN_INTERVAL then
    doSendCard()
  else
    cardPending = true
    C_Timer.After(CARD_MIN_INTERVAL - elapsed, doSendCard)
  end
end

local function doSendStats()
  statsPending = false
  if not ns.Snapshot.EncodeStats then return end
  local payload = ns.Snapshot.EncodeStats()
  send(MSG.STATS .. "|" .. ns.PROTO .. "|" .. payload)
  lastStatsAt = GetTime()
  ns:Debug("STATS sent (" .. #payload .. " chars)")
end

function Comm.QueueStats(force)
  if not (ns.SharedStats and ns.Snapshot.EncodeStats) then return end
  local sig = ns.SharedStats.Signature()
  if not force and sig == lastStatsSig then return end
  lastStatsSig = sig
  if statsPending then return end
  local elapsed = GetTime() - lastStatsAt
  if elapsed >= STATS_MIN_INTERVAL then
    doSendStats()
  else
    statsPending = true
    C_Timer.After(STATS_MIN_INTERVAL - elapsed, doSendStats)
  end
end

-- ---------------------------------------------------------------------------
-- Control messages
-- ---------------------------------------------------------------------------
function Comm.SendHello()
  if ns:InCombat() then return end
  send(MSG.HELLO .. "|" .. ns.PROTO .. "|" .. (UnitName("player") or "?"))
end

function Comm.RequestSnapshot()
  send(MSG.REQ)
end

function Comm.SendBye()
  rawSend({ text = MSG.BYE, target = partnerTarget() })
end

-- Own readiness for a ready check: (ready bool, verdict string)
local function selfReadiness()
  ns.SelfState.Update()
  local verdict = ns.Snapshot.ComputeVerdict(ns.state.self, ns.db)
  return verdict == "ready", verdict
end

function Comm.SendReadyCheck()
  local ready, verdict = selfReadiness()
  send(MSG.RCHECK .. "|" .. (ready and 1 or 0) .. "|" .. verdict)
  if ns.ReadyCheck and ns.ReadyCheck.OnSent then ns.ReadyCheck.OnSent(ready, verdict) end
  ns:Print("ready check sent to partner")
end

-- Inventory: request the partner's bags / send our own (chunked).
function Comm.RequestInventory()
  send(MSG.INVREQ)
end
function Comm.SendInventory()
  if not (ns.InvSync) then return end
  if not partnerTarget() and not Comm.selftest then return end
  local payload = ns.InvSync.Encode()
  local n = math.max(1, math.ceil(#payload / INV_CHUNK))
  for i = 1, n do
    send(MSG.INV .. "|" .. i .. "/" .. n .. "|" .. payload:sub((i - 1) * INV_CHUNK + 1, i * INV_CHUNK))
  end
  ns:Debug("INV sent (" .. #payload .. " chars, " .. n .. " chunk(s))")
end

-- Quest log: request the partner's quests / send our own (chunked, like INV).
function Comm.RequestQuests()
  send(MSG.QLOGREQ)
end
function Comm.SendQuests()
  if not (ns.QuestSync) then return end
  if not partnerTarget() and not Comm.selftest then return end
  local payload = ns.QuestSync.Encode()
  local n = math.max(1, math.ceil(#payload / INV_CHUNK))
  for i = 1, n do
    send(MSG.QLOG .. "|" .. i .. "/" .. n .. "|" .. payload:sub((i - 1) * INV_CHUNK + 1, i * INV_CHUNK))
  end
  ns:Debug("QLOG sent (" .. #payload .. " chars, " .. n .. " chunk(s))")
end

-- ---------------------------------------------------------------------------
-- Partner live-link lifecycle (the persistent bond lives in Pairing/chardb)
-- ---------------------------------------------------------------------------
local function markLinked()
  ns.state.linked = true
  ns.state.partner = ns.state.partner or {}
  ns.state.partner.lastSeen = GetTime()
end

-- Drop the live link but KEEP the saved bond (used on BYE / partner offline).
local function softUnlink(reason)
  ns.state.linked = false
  ns.state.partner = nil
  ns:Debug("softUnlink: " .. tostring(reason))
  if ns.Dashboard then ns.Dashboard.Refresh() end
end
Comm.SoftUnlink = softUnlink

-- ---------------------------------------------------------------------------
-- Inbound dispatch
-- ---------------------------------------------------------------------------
-- trusted=true bypasses the bond gate (used by loopback Inject).
local function dispatch(text, senderShort, trusted)
  local mtype, rest = text:match("^([A-Z]+)|?(.*)$")
  if not mtype then mtype = text end

  -- Pairing handshake is always allowed (that's how a bond is formed).
  if mtype == "INVITE" or mtype == "ACCEPT" or mtype == "DECLINE" then
    if ns.Pairing then ns.Pairing.OnMessage(mtype, rest, senderShort) end
    return
  end

  -- Everything else must come from the bonded partner (or be trusted/self-test).
  if not (trusted or Comm.selftest) then
    if not (ns.Pairing and ns.Pairing.IsBonded(senderShort)) then
      ns:Debug("ignoring " .. mtype .. " from non-partner " .. tostring(senderShort))
      return
    end
  end

  ns:Debug("recv " .. mtype .. " from " .. tostring(senderShort))

  if mtype == MSG.HELLO then
    local wasLinked = ns.state.linked
    markLinked()
    if not wasLinked then Comm.SendHello() end   -- reply only once, no ping-pong
    Comm.QueueSnapshot(true)
    Comm.QueueCard(true)
    Comm.QueueStats(true)

  elseif mtype == MSG.SNAP then
    local _, payload = rest:match("^(%d+)|(.*)$")
    local snap = ns.Snapshot.Decode(payload)
    if snap then
      ns.state.partner = ns.state.partner or {}
      for k, v in pairs(snap) do ns.state.partner[k] = v end
      markLinked()
      if ns.Dashboard then ns.Dashboard.Refresh() end
    end

  elseif mtype == MSG.CARD then
    local _, payload = rest:match("^(%d+)|(.*)$")
    local card = ns.Snapshot.DecodeCard(payload)
    if card then
      ns.state.partner = ns.state.partner or {}
      for k, v in pairs(card) do ns.state.partner[k] = v end
      markLinked()
      if ns.Dashboard then ns.Dashboard.Refresh() end
    end

  elseif mtype == MSG.REQ then
    markLinked()
    Comm.QueueSnapshot(true)
    Comm.QueueCard(true)
    Comm.QueueStats(true)

  elseif mtype == MSG.STATS then
    local _, payload = rest:match("^(%d+)|(.*)$")
    local st = ns.Snapshot.DecodeStats(payload)
    if st and ns.SharedStats then
      markLinked()
      ns.SharedStats.MergePartner(st)
    end

  elseif mtype == MSG.RCHECK then
    markLinked()
    if PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then PlaySound(SOUNDKIT.READY_CHECK) end
    local theirReady, theirVerdict = rest:match("^(%d)|?(.*)$")
    local ready, verdict = selfReadiness()
    send(MSG.RCACK .. "|" .. (ready and 1 or 0) .. "|" .. verdict)
    if ns.ReadyCheck and ns.ReadyCheck.OnIncoming then
      ns.ReadyCheck.OnIncoming(ready, verdict, theirReady == "1", theirVerdict)
    end

  elseif mtype == MSG.RCACK then
    local r, reason = rest:match("^(%d)|?(.*)$")
    if ns.ReadyCheck and ns.ReadyCheck.OnResponse then ns.ReadyCheck.OnResponse(r == "1", reason) end

  elseif mtype == MSG.INVREQ then
    markLinked()
    if ns.InvSync then ns.InvSync.partnerWantsInv = true end
    Comm.SendInventory()

  elseif mtype == MSG.INV then
    local i, total, chunk = rest:match("^(%d+)/(%d+)|(.*)$")
    i, total = tonumber(i), tonumber(total)
    if i and total then
      markLinked()
      invBuf = invBuf or {}
      invBuf[i] = chunk or ""
      local have = 0
      for k = 1, total do if invBuf[k] ~= nil then have = have + 1 end end
      if have == total then
        local full = table.concat(invBuf, "", 1, total)
        invBuf = nil
        if ns.InvSync then ns.InvSync.Decode(full) end
        if ns.Dashboard then ns.Dashboard.Refresh() end
      end
    end

  elseif mtype == MSG.QLOGREQ then
    markLinked()
    if ns.QuestSync then ns.QuestSync.partnerWantsQuests = true end
    Comm.SendQuests()

  elseif mtype == MSG.QLOG then
    local i, total, chunk = rest:match("^(%d+)/(%d+)|(.*)$")
    i, total = tonumber(i), tonumber(total)
    if i and total then
      markLinked()
      qlogBuf = qlogBuf or {}
      qlogBuf[i] = chunk or ""
      local have = 0
      for k = 1, total do if qlogBuf[k] ~= nil then have = have + 1 end end
      if have == total then
        local full = table.concat(qlogBuf, "", 1, total)
        qlogBuf = nil
        if ns.QuestSync then ns.QuestSync.Decode(full) end
        if ns.Dashboard then ns.Dashboard.Refresh() end
      end
    end

  elseif mtype == MSG.BYE then
    softUnlink("partner sent BYE")
  end
end

local function onAddonMessage(_, prefix, text, channel, sender)
  if prefix ~= ns.PREFIX then return end
  local me = UnitName("player")
  local senderShort = sender and sender:match("^[^-]+") or sender
  if senderShort == me then
    if not Comm.selftest then return end   -- ignore our own echoes (except self-test)
  end
  dispatch(text, senderShort, false)
end

-- ---------------------------------------------------------------------------
-- Loopback / self-test (single-client debugging)
-- ---------------------------------------------------------------------------
function Comm.Inject(text, fakeSender)
  dispatch(text, fakeSender or "TestPartner", true)
end

function Comm.RunLoopbackTest()
  ns.SelfState.Update()
  Comm.Inject(MSG.HELLO .. "|" .. ns.PROTO .. "|TestPartner")
  Comm.Inject(MSG.CARD .. "|" .. ns.PROTO .. "|" .. ns.Snapshot.EncodeCard())
  local payload = ns.Snapshot.Encode()
  Comm.Inject(MSG.SNAP .. "|" .. ns.PROTO .. "|" .. payload)
  ns.state.partnerName = "TestPartner"
  ns:Print("loopback: injected HELLO + CARD + SNAP from |cffffff00TestPartner|r")
  ns:Print("loopback payload: |cff888888" .. payload:gsub("|", "||") .. "|r")
  if ns.Dashboard then ns.Dashboard.Refresh() end
end

function Comm.ToggleSelfTest()
  Comm.selftest = not Comm.selftest
  if Comm.selftest then
    ns.state.partnerName = UnitName("player")
    ns:Print("self-test |cff44ff44ON|r — whispering yourself")
    Comm.SendHello()
    Comm.QueueSnapshot(true)
    Comm.QueueCard(true)
  else
    ns:Print("self-test OFF")
    softUnlink("self-test ended")
  end
  return Comm.selftest
end

-- ---------------------------------------------------------------------------
-- Reconnect: while bonded but not linked, retry HELLO so we re-link when the
-- partner comes online (no party/roster dependency with whisper-based comms).
-- ---------------------------------------------------------------------------
local function onEnteringWorld()
  if ns.Pairing and ns.Pairing.PartnerName() then
    Comm.SendHello()
    Comm.RequestSnapshot()
  end
end

local function onLogout()
  Comm.SendBye()
end

function Comm.Init()
  C_Timer.NewTicker(RECONNECT_INTERVAL, function()
    if ns.Pairing and ns.Pairing.PartnerName() and not ns.state.linked then
      ns:Debug("reconnect: pinging partner")
      Comm.SendHello()
    end
  end)
  ns:Debug("Comm.Init")
end

ns:RegisterEvent("CHAT_MSG_ADDON",        onAddonMessage)
ns:RegisterEvent("PLAYER_ENTERING_WORLD", onEnteringWorld)
ns:RegisterEvent("PLAYER_LOGOUT",         onLogout)

return Comm
