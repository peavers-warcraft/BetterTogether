--[[ UI/Pages/Quests.lua
  Quests page: full quest-log comparison. Shows the quests you and your partner
  are both on (with each side's objective progress), plus the quests only one of
  you has — so you can see who's missing what. The partner's quest list arrives
  via the QLOG comm channel, requested when this tab is opened.
]]

local addonName, ns = ...
local S = ns.UI.Shared
local Theme = ns.UI.Theme
local DP = ns.UI.DetailPane
local L = ns.L

ns.Pages = ns.Pages or {}
local M = {}
ns.Pages.Quests = M

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

-- Quest detail renderer: draws a quest's status + objectives into the shared detail
-- pane (ns.UI.DetailPane), reusing its chip/name/body widgets. `q` =
-- { id, title, status, you, partner } where you/partner are { done, cur, total } (or
-- nil if that side isn't on it).
local shownQuest

local function renderQuestDetail()
  local q = shownQuest
  if not q then return end
  DP.StopSpinner()
  DP.text:SetJustifyH("LEFT")
  DP.hint:Hide()
  Theme.ApplyIcon(DP.chip.icon, Theme.I_QUEST)
  DP.chip:Show()
  DP.name:SetText(q.title or (L["Quest #"] .. (q.id or 0)))
  DP.name:SetTextColor(Theme.CREAM[1], Theme.CREAM[2], Theme.CREAM[3])

  local function prog(side)
    if not side then return Theme.C.dim .. L["not on this quest"] .. "|r" end
    if side.done then return Theme.C.ready .. L["Complete"] .. "|r" end
    if (side.total or 0) > 0 then return Theme.C.white .. (side.cur or 0) .. " / " .. side.total .. "|r" end
    return Theme.C.white .. L["In progress"] .. "|r"
  end

  local parts = {}
  local statusText = ({
    both        = Theme.C.ready .. L["You're both on this quest."] .. "|r",
    partnerOnly = Theme.C.warn .. string.format(L["Only %s is on this quest."], ns.Util.PartnerName(L["your partner"])) .. "|r",
    youOnly     = Theme.C.info .. L["Only you are on this quest."] .. "|r",
  })[q.status]
  if statusText then parts[#parts + 1] = statusText end
  parts[#parts + 1] = Theme.C.muted .. L["Quest ID"] .. "|r  " .. (q.id or 0)
  parts[#parts + 1] = " "

  -- Your side: real per-objective text when we're actually on the quest; else the
  -- synced aggregate.
  parts[#parts + 1] = Theme.C.gold .. L["Your progress"] .. "|r"
  local objs = C_QuestLog and C_QuestLog.GetQuestObjectives
    and C_QuestLog.GetQuestObjectives(q.id) or nil
  if objs and #objs > 0 then
    for _, o in ipairs(objs) do
      parts[#parts + 1] = (o.finished and Theme.C.ready or Theme.C.soft) .. (o.text or "") .. "|r"
    end
  else
    parts[#parts + 1] = prog(q.you)
  end
  parts[#parts + 1] = " "
  parts[#parts + 1] = Theme.C.gold .. string.format(L["%s's progress"], ns.Util.PartnerName(L["Partner"])) .. "|r"
  parts[#parts + 1] = prog(q.partner)

  DP.qchip:Hide(); DP.qlabel:Hide()
  DP.text:ClearAllPoints()
  DP.text:SetPoint("TOPLEFT", DP.body, "TOPLEFT", 2, -60)
  DP.text:SetText(table.concat(parts, "\n"))
  DP.text:Show()

  DP.body:SetHeight(60 + (DP.text:GetStringHeight() or 0) + 14)
  if DP.scroll then DP.scroll:UpdateScrollChildRect() end
end

local function showQuestDetail(q)
  shownQuest = q
  DP.Render(renderQuestDetail)
end

-- Hover-preview + click-lock detail controller (S.makePinController): hovering a
-- quest previews it in the right-hand pane, clicking locks it there.
local detail = S.makePinController({
  show = function(_, q) showQuestDetail(q) end,
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
  if not ns.PartnerShares("questlog") then
    return { fullPage = { text = "|cff808080" .. string.format(L["%s has turned off sharing their quest log."], ns.Util.PartnerName(L["Your partner"])) .. "|r" } }
  end

  -- Not paired yet: nothing to compare — a calm prompt rather than a spinner that
  -- would otherwise spin forever waiting on a partner who'll never arrive.
  if ns.state.partner == nil then
    return { fullPage = { text = "|cff808080" .. L["Pair with your partner to compare quests."] .. "|r" } }
  end

  local own = (ns.QuestSync and ns.QuestSync.Scan()) or {}
  local partner = ns.state.partner.qlog

  if not partner then
    return { fullPage = { spinner = true,
      text = "|cffd0d0d0" .. string.format(L["Waiting for %s's quest log…"], ns.Util.PartnerName(L["your partner"])) .. "|r\n|cff808080" .. L["A request is sent when you open this tab."] .. "|r" } }
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
      row.partnerText = "|cffa0a0a0" .. ns.Util.PartnerName(L["Partner"]) .. " " .. progStr(q) .. "|r"
      both[#both + 1] = row
    else
      local row = questRow(q.id, title, "partnerOnly", nil, q)
      row.value = "|cffa0a0a0" .. ns.Util.PartnerName(L["Partner"]) .. " " .. progStr(q) .. "|r"
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
    sections[#sections + 1] = { title = string.format(L["%s is on, you're not"], ns.Util.PartnerName(L["Partner"])) .. "  |cff707070(" .. #partnerOnly .. ")|r", rows = partnerOnly }
  end
  if #youOnly > 0 then
    sections[#sections + 1] = { title = string.format(L["You're on, %s isn't"], ns.Util.PartnerName(L["Partner"])) .. "  |cff707070(" .. #youOnly .. ")|r", rows = youOnly }
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
