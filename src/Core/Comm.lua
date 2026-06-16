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

-- Hot-path global, localized for the throttle/debounce timers below.
local GetTime = GetTime

local MSG = {
  HELLO = "HELLO", SNAP = "SNAP", CARD = "CARD", REQ = "REQ", BYE = "BYE",
  STATS = "STATS", PRIV = "PRIV",   -- PRIV = privacy manifest (what we won't share)
  PING = "PING", PONG = "PONG",   -- presence handshake for non-active roster members
  INV = "INV", INVREQ = "INVREQ",
  INVITEM = "INVITEM", INVITEMREQ = "INVITEMREQ",
  QLOG = "QLOG", QLOGREQ = "QLOGREQ",
  ACHV = "ACHV", ACHVREQ = "ACHVREQ", ACHVDIG = "ACHVDIG", ACHVDIGREQ = "ACHVDIGREQ",
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
    channel, target = "WHISPER", ns.Util.MyFullName()
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

-- Drain 1 token every 0.25s (~4 msg/s) rather than 1/s: bulk feeds (achievements,
-- inventory, quests) are many chunks, and 1/s made them crawl. rawSend re-queues on
-- the client's real throttle, so a higher drain rate can't drop messages — it just
-- backs off automatically if we overshoot.
local function ensureTicker()
  if not ticker then ticker = C_Timer.NewTicker(0.25, refillAndDrain) end
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
--- @param name string Target character ("Name-Realm").
--- @param text string Message body (already prefixed with its MSG type).
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
-- Inbound chunk reassembly. Each chunked message type accumulates its parts in
-- buffers[key] until all `total` of them arrive, then fires onComplete(fullPayload)
-- and refreshes the dashboard. ACHV passes a per-era key so two eras streaming at
-- once never collide. Replaces the four hand-rolled invBuf/qlogBuf/... loops.
local buffers = {}
local function reassemble(key, i, total, chunk, onComplete)
  local buf = buffers[key] or {}
  buffers[key] = buf
  buf[i] = chunk or ""
  local have = 0
  for k = 1, total do if buf[k] ~= nil then have = have + 1 end end
  if have == total then
    buffers[key] = nil
    onComplete(table.concat(buf, "", 1, total))
    if ns.Dashboard then ns.Dashboard.Refresh() end
  end
end

-- Proactive data pushes only make sense to a live partner. Skipping them while
-- unlinked is what stops us whispering SNAP/CARD into the void after the partner
-- logs off (handshake/REQ responses set linked before calling these, so those
-- still go out).
local function haveLiveLink() return ns.state.linked or Comm.selftest end

local function doSendSnapshot()
  snapPending = false
  if ns:InCombat() or not haveLiveLink() then return end
  ns.SelfState.Update()
  local payload = ns.Snapshot.Encode()
  send(MSG.SNAP .. "|" .. ns.PROTO .. "|" .. payload)
  lastSnapAt = GetTime()
  ns:Debug("SNAP sent (" .. #payload .. " chars)")
end

local function doSendCard()
  cardPending = false
  if ns:InCombat() or not haveLiveLink() then return end
  ns.SelfState.Update()
  local payload = ns.Snapshot.EncodeCard()
  send(MSG.CARD .. "|" .. ns.PROTO .. "|" .. payload)
  lastCardAt = GetTime()
  ns:Debug("CARD sent (" .. #payload .. " chars)")
end

-- force=true sends even if unchanged (handshake / explicit request).
--- @param force boolean|nil Send even when the snapshot signature is unchanged.
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
  if not ns.Snapshot.EncodeStats or not haveLiveLink() or not ns.Shares("stats") then return end
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

-- Broadcast our privacy manifest so the partner can label hidden fields instead of
-- waiting on data that will never come. Sent on handshake/REQ and whenever the user
-- changes a toggle (see the Privacy page).
function Comm.SendPrivacy()
  if not ns.Snapshot.EncodePrivacy then return end
  send(MSG.PRIV .. "|" .. ns.PROTO .. "|" .. ns.Snapshot.EncodePrivacy())
end

function Comm.RequestSnapshot()
  send(MSG.REQ)
end

function Comm.SendBye()
  rawSend({ text = MSG.BYE, target = partnerTarget() })
end

-- Send `payload` as INV_CHUNK-sized parts, each framed as
--   <msgType>|[<prefix>|]<i>/<n>|<chunk>
-- `prefix` (optional) is inserted before the chunk counter — ACHV uses it for the
-- era token. `label` only tags the debug line. Mirrors reassemble() on the receiver.
local function sendChunked(msgType, payload, label, prefix)
  local n = math.max(1, math.ceil(#payload / INV_CHUNK))
  local pre = prefix and (prefix .. "|") or ""
  for i = 1, n do
    send(msgType .. "|" .. pre .. i .. "/" .. n .. "|" .. payload:sub((i - 1) * INV_CHUNK + 1, i * INV_CHUNK))
  end
  ns:Debug((label or msgType) .. " sent (" .. #payload .. " chars, " .. n .. " chunk(s))")
end

-- Inventory: request the partner's bags / send our own (chunked).
function Comm.RequestInventory()
  send(MSG.INVREQ)
end
function Comm.SendInventory()
  if not (ns.InvSync) then return end
  if not partnerTarget() and not Comm.selftest then return end
  if not ns.Shares("inventory") then return end
  sendChunked(MSG.INV, ns.InvSync.Encode(), "INV")
end

-- On-demand item detail: the bulk INV feed is itemID-only, so the hover detail
-- asks the partner for one item's full string (bonus IDs) by id. A single item
-- string is well under the chunk size, so no chunking is needed.
function Comm.RequestItemDetail(id)
  send(MSG.INVITEMREQ .. "|" .. id)
end
function Comm.SendItemDetail(id)
  if not ns.InvSync then return end
  if not ns.Shares("inventory") then return end
  local str = ns.InvSync.ResolveItemString(id)
  if str then send(MSG.INVITEM .. "|" .. id .. "|" .. str) end
end

-- Quest log: request the partner's quests / send our own (chunked, like INV).
function Comm.RequestQuests()
  send(MSG.QLOGREQ)
end
function Comm.SendQuests()
  if not (ns.QuestSync) then return end
  if not partnerTarget() and not Comm.selftest then return end
  if not ns.Shares("questlog") then return end
  sendChunked(MSG.QLOG, ns.QuestSync.Encode(), "QLOG")
end

-- Achievements: a tiny per-era digest (counts + earliest date), then one era's
-- full list on demand — bucketed so we only ever pull the era currently on screen
-- (avoids dumping thousands of entries up front). Both chunked like QLOG.
function Comm.RequestAchvDigest()
  send(MSG.ACHVDIGREQ)
end
function Comm.SendAchvDigest()
  if not ns.AchvSync then return end
  if not partnerTarget() and not Comm.selftest then return end
  if not ns.Shares("achievements") then return end
  -- Wait for the (async) achievement scan so we never block the frame encoding it.
  ns.AchvSync.Ensure(function()
    sendChunked(MSG.ACHVDIG, ns.AchvSync.EncodeDigest(), "ACHVDIG")
  end)
end
function Comm.RequestAchvEra(era)
  send(MSG.ACHVREQ .. "|" .. era)
end
function Comm.SendAchvEra(era)
  if not ns.AchvSync then return end
  if not partnerTarget() and not Comm.selftest then return end
  if not ns.Shares("achievements") then return end
  era = tonumber(era); if not era then return end
  ns.AchvSync.Ensure(function()
    sendChunked(MSG.ACHV, ns.AchvSync.EncodeEra(era), "ACHV era " .. era, era)
  end)
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
  ns.state.partnerPrivacy = nil
  ns:Debug("softUnlink: " .. tostring(reason))
  if ns.Dashboard then ns.Dashboard.Refresh() end
end
Comm.SoftUnlink = softUnlink

-- ---------------------------------------------------------------------------
-- Roster presence (who's reachable among the *saved* partners)
--   The active partner's online state is ns.state.linked, kept fresh by the
--   HELLO/SNAP handshake. Saved (non-active) partners have no live link, so we
--   PING them (a tiny handshake that bypasses the bond gate, like INVITE) and
--   stamp the time we last heard a PONG back. The Partners page reads IsOnline to
--   decide whether "Set active" is clickable — you can't switch to someone who
--   isn't there to sync with.
-- ---------------------------------------------------------------------------
local PRESENCE_FRESH = 35   -- seconds a PONG keeps a partner "online" in the UI
local presence = {}         -- shortName():lower() -> GetTime() of last PONG

-- Record a fresh sighting. Returns true only when the partner *transitioned*
-- offline -> online, so callers refresh the UI on the edge instead of on every
-- PONG (a small roster pinging in lockstep would otherwise restack refreshes).
local function markSeen(name)
  local short = ns.Util.ShortName(name)
  if not short then return false end
  local key = short:lower()
  local was = presence[key]
  presence[key] = GetTime()
  return was == nil or (GetTime() - was) > PRESENCE_FRESH
end

--- Is a roster member currently reachable? The active partner uses the live link;
--- everyone else uses their most recent PONG.
--- @param name string A character name (short or full).
--- @return boolean
function Comm.IsOnline(name)
  local short = ns.Util.ShortName(name)
  if not short then return false end
  if ns.Pairing and ns.Pairing.IsBonded(short) then return ns.state.linked == true end
  local t = presence[short:lower()]
  return t ~= nil and (GetTime() - t) <= PRESENCE_FRESH
end

--- Ping every saved roster member (except ourselves) to refresh their presence.
--- Cheap (one tiny whisper each); the Partners page calls this while it's visible.
function Comm.PingRoster()
  if not (ns.Pairing and ns.Pairing.Roster) then return end
  for _, full in ipairs(ns.Pairing.Roster()) do
    if not ns.Util.IsSelf(full) then Comm.WhisperTo(full, MSG.PING) end
  end
end

-- ---------------------------------------------------------------------------
-- Inbound dispatch
-- ---------------------------------------------------------------------------
-- Strip and validate the leading wire-protocol version token (the `<version>|`
-- prefix on SNAP/CARD/STATS bodies). Returns the remaining payload, or nil if
-- the partner speaks an incompatible protocol — decoding a foreign format could
-- corrupt ns.state.partner, so we skip it and leave a debug breadcrumb.
local function stripProto(rest)
  local ver, payload = rest:match("^(%d+)|(.*)$")
  if tonumber(ver) ~= ns.PROTO then
    ns:Debug("ignoring message: proto " .. tostring(ver) .. " ~= " .. ns.PROTO)
    return nil
  end
  return payload
end

-- trusted=true bypasses the bond gate (used by loopback Inject).
local function dispatch(text, senderShort, trusted)
  local mtype, rest = text:match("^([A-Z]+)|?(.*)$")
  if not mtype then mtype = text end

  -- Pairing handshake is always allowed (that's how a bond is formed).
  if mtype == "INVITE" or mtype == "ACCEPT" or mtype == "DECLINE" then
    if ns.Pairing then ns.Pairing.OnMessage(mtype, rest, senderShort) end
    return
  end

  -- Presence handshake — handled regardless of the bond gate so we can detect
  -- roster members who aren't our *active* partner. We only answer/record for
  -- people actually in our roster (pairing is mutual), never random probers, and
  -- reply to a PING with PONG so the other side stamps us as online too.
  if mtype == MSG.PING or mtype == MSG.PONG then
    local full = ns.Pairing and ns.Pairing.InRoster(senderShort)
    if full then
      local appeared = markSeen(senderShort)
      if mtype == MSG.PING then Comm.WhisperTo(full, MSG.PONG) end
      if appeared and ns.Dashboard then ns.Dashboard.Refresh() end
    end
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
    Comm.SendPrivacy()

  elseif mtype == MSG.SNAP then
    local payload = stripProto(rest)
    local snap = payload and ns.Snapshot.Decode(payload)
    if snap then
      ns.state.partner = ns.state.partner or {}
      for k, v in pairs(snap) do ns.state.partner[k] = v end
      markLinked()
      if ns.Dashboard then ns.Dashboard.Refresh() end
    end

  elseif mtype == MSG.CARD then
    local payload = stripProto(rest)
    local card = payload and ns.Snapshot.DecodeCard(payload)
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
    Comm.SendPrivacy()

  elseif mtype == MSG.PRIV then
    markLinked()
    ns.state.partnerPrivacy = ns.Snapshot.DecodePrivacy(stripProto(rest))
    if ns.Dashboard then ns.Dashboard.Refresh() end

  elseif mtype == MSG.STATS then
    local payload = stripProto(rest)
    local st = payload and ns.Snapshot.DecodeStats(payload)
    if st and ns.SharedStats then
      markLinked()
      ns.SharedStats.MergePartner(st)
    end

  elseif mtype == MSG.INVREQ then
    markLinked()
    if ns.InvSync then ns.InvSync.partnerWantsInv = true end
    Comm.SendInventory()

  elseif mtype == MSG.INV then
    local i, total, chunk = rest:match("^(%d+)/(%d+)|(.*)$")
    i, total = tonumber(i), tonumber(total)
    if i and total then
      markLinked()
      reassemble(MSG.INV, i, total, chunk, function(full)
        if ns.InvSync then
          ns.InvSync.ClearDetailCache()   -- fresh feed: drop stale on-demand strings
          ns.InvSync.Decode(full)
        end
      end)
    end

  elseif mtype == MSG.INVITEMREQ then
    markLinked()
    Comm.SendItemDetail(rest)

  elseif mtype == MSG.INVITEM then
    local id, str = rest:match("^(%d+)|(.*)$")
    if id and ns.InvSync then ns.InvSync.StoreItemDetail(id, str) end

  elseif mtype == MSG.QLOGREQ then
    markLinked()
    if ns.QuestSync then ns.QuestSync.partnerWantsQuests = true end
    Comm.SendQuests()

  elseif mtype == MSG.QLOG then
    local i, total, chunk = rest:match("^(%d+)/(%d+)|(.*)$")
    i, total = tonumber(i), tonumber(total)
    if i and total then
      markLinked()
      reassemble(MSG.QLOG, i, total, chunk, function(full)
        if ns.QuestSync then ns.QuestSync.Decode(full) end
      end)
    end

  elseif mtype == MSG.ACHVDIGREQ then
    markLinked()
    Comm.SendAchvDigest()

  elseif mtype == MSG.ACHVDIG then
    local i, total, chunk = rest:match("^(%d+)/(%d+)|(.*)$")
    i, total = tonumber(i), tonumber(total)
    if i and total then
      markLinked()
      reassemble(MSG.ACHVDIG, i, total, chunk, function(full)
        if ns.AchvSync then ns.AchvSync.DecodeDigest(full) end
      end)
    end

  elseif mtype == MSG.ACHVREQ then
    markLinked()
    Comm.SendAchvEra(rest)

  elseif mtype == MSG.ACHV then
    local era, i, total, chunk = rest:match("^(%d+)|(%d+)/(%d+)|(.*)$")
    i, total = tonumber(i), tonumber(total)
    if era and i and total then
      markLinked()
      reassemble(MSG.ACHV .. ":" .. era, i, total, chunk, function(full)
        if ns.AchvSync then ns.AchvSync.DecodeEra(tonumber(era), full) end
      end)
    end

  elseif mtype == MSG.BYE then
    softUnlink("partner sent BYE")
  end
end

local function onAddonMessage(_, prefix, text, channel, sender)
  if prefix ~= ns.PREFIX then return end
  local senderShort = ns.Util.ShortName(sender)
  -- Ignore our own echoes (except during self-test, which whispers ourselves).
  if ns.Util.IsSelf(sender) and not Comm.selftest then return end
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
  Comm.Inject(MSG.PRIV .. "|" .. ns.PROTO .. "|" .. ns.Snapshot.EncodePrivacy())
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
    if not (ns.Pairing and ns.Pairing.PartnerName()) then return end
    if ns.state.linked then
      -- Linked: watch for the partner going quiet. A logout BYE can be dropped, so
      -- silence is our backstop signal. A short gap just earns a nudge — an online
      -- but idle partner answers and stays linked — while silence past OFFLINE_AFTER
      -- means they've logged off, so we drop the live link (the dashboard flips to
      -- "offline" and we stop streaming data at them). Reconnect resumes below.
      local since = GetTime() - ((ns.state.partner and ns.state.partner.lastSeen) or 0)
      if since > ns.OFFLINE_AFTER then
        softUnlink("partner silent past offline cutoff")
      elseif since > RECONNECT_INTERVAL then
        ns:Debug("partner quiet, nudging")
        Comm.SendHello()
      end
    else
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
