--[[ QuestSync.lua
  Scans the player's quest log into a compact list and (de)serializes it for the
  chunked QLOG comm message — mirrors InvSync. Only the partner's request turns on
  resending.

  Titles are NOT sent: the receiver resolves them via GetTitleForQuestID (keeps the
  payload compact and sidesteps delimiter hazards from arbitrary quest names).
  Wire entry: "<id>:<done>:<cur>/<total>" — all numeric, so "," is a safe joiner.
]]

local addonName, ns = ...

local QuestSync = {}
ns.QuestSync = QuestSync

QuestSync.partnerWantsQuests = false
local MAX_QUESTS = 200

-- Aggregate the player's quest log into { {id=, done=, cur=, total=, title=}, ... }
function QuestSync.Scan()
  local list = {}
  if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) then return list end
  local n = C_QuestLog.GetNumQuestLogEntries()
  for i = 1, n do
    local info = C_QuestLog.GetInfo(i)
    if info and not info.isHeader and not info.isHidden and (info.questID or 0) > 0 then
      local id = info.questID
      local done = (C_QuestLog.IsComplete and C_QuestLog.IsComplete(id)) and 1 or 0
      local cur, total = 0, 0
      local objs = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(id)
      if objs then
        for _, o in ipairs(objs) do
          local req = o.numRequired or 0
          total = total + req
          cur = cur + math.min(o.numFulfilled or 0, req)
        end
      end
      list[#list + 1] = { id = id, done = done, cur = cur, total = total, title = info.title }
    end
  end
  return list
end

function QuestSync.Encode()
  local list = QuestSync.Scan()
  local parts = {}
  for i = 1, math.min(#list, MAX_QUESTS) do
    local q = list[i]
    parts[i] = q.id .. ":" .. q.done .. ":" .. q.cur .. "/" .. q.total
  end
  return table.concat(parts, ",")
end

function QuestSync.Decode(str)
  local list = {}
  for entry in (str or ""):gmatch("[^,]+") do
    local id, done, cur, total = entry:match("^(%d+):(%d):(%d+)/(%d+)$")
    if id then
      list[#list + 1] = { id = tonumber(id), done = done == "1",
        cur = tonumber(cur), total = tonumber(total) }
    end
  end
  ns.state.partner = ns.state.partner or {}
  ns.state.partner.qlog = list
end

-- Resend (debounced) when our quest log changes AND the partner is viewing.
local RESEND_DELAY = 3   -- seconds to coalesce a burst of quest-log updates into one send
local pending = false
local function onQuestLogUpdate()
  if not QuestSync.partnerWantsQuests or pending then return end
  pending = true
  C_Timer.After(RESEND_DELAY, function()
    pending = false
    if ns.Comm and ns.Comm.SendQuests then ns.Comm.SendQuests() end
  end)
end
ns:RegisterEvent("QUEST_LOG_UPDATE", onQuestLogUpdate)

return QuestSync
