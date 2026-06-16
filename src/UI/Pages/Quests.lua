--[[ UI/Pages/Quests.lua
  Quests page: full quest-log comparison. Shows the quests you and your partner
  are both on (with each side's objective progress), plus the quests only one of
  you has — so you can see who's missing what. The partner's quest list arrives
  via the QLOG comm channel, requested when this tab is opened.
]]

local addonName, ns = ...
local S = ns.UI.Shared
local Theme = ns.UI.Theme
local L = ns.L

-- Partner list carries no titles (kept off the wire); resolve from the client.
local function resolveTitle(id, fallback)
  local t = fallback
  if (not t or t == "") and C_QuestLog and C_QuestLog.GetTitleForQuestID then
    t = C_QuestLog.GetTitleForQuestID(id)
  end
  return (t and t ~= "") and t or (L["Quest #"] .. id)
end

local function progStr(q)
  if q.done then return "|cff44ff44" .. L["done"] .. "|r" end
  if (q.total or 0) > 0 then return (q.cur or 0) .. "/" .. q.total end
  return L["in progress"]
end

-- Hover-preview + click-lock detail controller (S.makePinController): hovering a
-- quest previews it in the right-hand pane, clicking locks it there.
local detail = S.makePinController({
  show = function(_, q)
    if ns.Dashboard and ns.Dashboard.ShowQuestDetail then ns.Dashboard.ShowQuestDetail(q) end
  end,
})

-- Build a hoverable/clickable row: hover previews, click pins this quest's details.
-- Returns the base row table; callers attach either `value` (single column) or
-- `youText`/`partnerText` (the aligned two-column comparison).
local function questRow(id, title, status, you, partner)
  local q = { id = id, title = title, status = status, you = you, partner = partner }
  return {
    icon = Theme.I_QUEST, label = title,
    selected = detail.isLocked(id),
    onEnter = function() detail.preview(id, q) end,
    onLeave = function() detail.leave() end,
    onClick = function() detail.lock(id, q) end,
  }
end

local function getSections(snap)
  -- Checked before any cached data: a partner who turns sharing off stops sending
  -- QLOG but we may still hold their last list, so this must win over stale data.
  if not ns.db.demoMode and not ns.PartnerShares("questlog") then
    return { { title = L["Quests"],
      text = "|cff808080" .. L["Your partner has turned off sharing their quest log."] .. "|r" } }
  end

  local own, partner
  if ns.db.demoMode then
    own, partner = S.demoQLogOwn(), S.demoQLogPartner()
  else
    own = (ns.QuestSync and ns.QuestSync.Scan()) or {}
    partner = ns.state.partner and ns.state.partner.qlog or nil
  end

  if not partner then
    return { { title = L["Quests"],
      text = "|cff808080" .. L["Waiting for your partner's quest log… (a request is sent when you open this tab)."] .. "|r" } }
  end

  local ownById, partnerById = {}, {}
  for _, q in ipairs(own) do ownById[q.id] = q end
  for _, q in ipairs(partner) do partnerById[q.id] = q end

  local both, partnerOnly, youOnly = {}, {}, {}
  for _, q in ipairs(partner) do
    local mine = ownById[q.id]
    local title = resolveTitle(q.id, q.title)
    if mine then
      local row = questRow(q.id, title, "both", mine, q)
      row.youText = "|cffffffff" .. L["You "] .. progStr(mine) .. "|r"
      row.partnerText = "|cffa0a0a0" .. L["Partner "] .. progStr(q) .. "|r"
      both[#both + 1] = row
    else
      local row = questRow(q.id, title, "partnerOnly", nil, q)
      row.value = "|cffa0a0a0" .. L["Partner "] .. progStr(q) .. "|r"
      partnerOnly[#partnerOnly + 1] = row
    end
  end
  for _, q in ipairs(own) do
    if not partnerById[q.id] then
      local row = questRow(q.id, resolveTitle(q.id, q.title), "youOnly", q, nil)
      row.value = "|cffffffff" .. L["You "] .. progStr(q) .. "|r"
      youOnly[#youOnly + 1] = row
    end
  end

  local byLabel = function(a, b) return a.label < b.label end
  table.sort(both, byLabel); table.sort(partnerOnly, byLabel); table.sort(youOnly, byLabel)

  local sections = {
    { title = L["On together"] .. "  |cff707070(" .. #both .. ")|r",
      rows = #both > 0 and both or nil,
      text = #both == 0 and "|cff808080" .. L["No quests in common right now."] .. "|r" or nil },
  }
  if #partnerOnly > 0 then
    sections[#sections + 1] = { title = L["Partner is on, you're not"] .. "  |cff707070(" .. #partnerOnly .. ")|r", rows = partnerOnly }
  end
  if #youOnly > 0 then
    sections[#sections + 1] = { title = L["You're on, partner's not"] .. "  |cff707070(" .. #youOnly .. ")|r", rows = youOnly }
  end
  return sections
end

local build, refresh = S.makeRowPage(getSections)

ns.Dashboard.RegisterPage({
  key = "quests", label = L["Quests"], order = 4, detail = true,
  detailTitle = L["Quest Details"], detailHint = L["Hover or click a quest to see its objectives."],
  build = build, refresh = refresh,
  onShow = function()
    detail.unlock()
    if ns.Comm and ns.Comm.RequestQuests then ns.Comm.RequestQuests() end
  end,
})
