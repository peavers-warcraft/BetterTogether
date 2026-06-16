--[[ UI/Pages/Partners.lua
  Partner roster tab: manage who you share readiness with.

  Layout (single column, ~560 wide):
    • Active partner  — a hero card with live connection status + class/level.
    • Saved partners  — the inactive roster; one click to make any of them active.
    • Add a partner   — invite box (whispers an invite; no party required).

  One partner is "active" at a time (the bond gate). Backed by ns.Pairing.
]]

local addonName, ns = ...
local S = ns.UI.Shared
local Theme = ns.UI.Theme
local Widgets = ns.UI.Widgets
local L = ns.L

local COL_W   = 560          -- max content column width
local CARD_H  = 72
local ROW_H, ROW_GAP = 38, 6
local SECTION_GAP = 30
local HEAD_PAD = 10          -- top padding between a section header's rule and the text below it

-- Captured once (matches the working pattern in Overview.lua). Pass explicit ""
-- flags: FontString:SetFont treats flags as optional, but EditBox:SetFont
-- requires the 3rd arg (else "bad argument #3 to 'SetFont'").
local FONT = GameFontHighlight:GetFont()
local function setFont(obj, size) if FONT then obj:SetFont(FONT, size, "") end end

-- Wire Blizzard's player-name autocomplete onto an EditBox — the same dropdown
-- the whisper / Add-Friend fields use, so typing "Am" suggests "Amy-Spirestone"
-- with the realm correctly normalized. Routed through C_AutoComplete + the
-- AutoCompleteEditBox_* handlers (Blizzard keeps these current), so it survives
-- the 12.0.5 deprecation of the old global GetAutoCompleteResults. Returns true
-- if wired; no-ops gracefully on clients without the API.
local function enableNameAutocomplete(box)
  local source = (C_AutoComplete and C_AutoComplete.GetAutoCompleteResults) or GetAutoCompleteResults
  if not (source and AutoCompleteEditBox_SetAutoCompleteSource) then return false end

  -- include every character-name source (friends, guild, group, recent whispers,
  -- your own alts); exclude Bnet handles since we whisper a character name.
  local includeAll = AUTOCOMPLETE_FLAG_ALL or 0xffffffff
  local excludeBnet = (Enum and Enum.AutoCompleteEntryFlag and Enum.AutoCompleteEntryFlag.Bnet) or 0x8
  AutoCompleteEditBox_SetAutoCompleteSource(box, source, includeAll, excludeBnet)
  box.autoCompleteContext = "all"
  box.addHighlightedText = true   -- inline ghost-completion of the top match

  box:HookScript("OnTextChanged", function(self, userInput) AutoCompleteEditBox_OnTextChanged(self, userInput) end)
  box:HookScript("OnChar", function(self) AutoCompleteEditBox_OnChar(self) end)
  box:HookScript("OnKeyDown", function(self, key) AutoCompleteEditBox_OnKeyDown(self, key) end)
  box:HookScript("OnKeyUp", function(self, key) AutoCompleteEditBox_OnKeyUp(self, key) end)
  box:HookScript("OnEditFocusLost", function(self) AutoCompleteEditBox_OnEditFocusLost(self) end)
  box:SetScript("OnTabPressed", function(self) AutoCompleteEditBox_OnTabPressed(self) end)
  return true
end

-- ---------------------------------------------------------------------------
-- Active-partner hero card
-- ---------------------------------------------------------------------------
local function makeHero(parent)
  local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  card:SetHeight(CARD_H)
  -- Border only — the `grad` texture below provides the fill, so we don't get a
  -- solid-white backdrop bg sitting on top of it.
  card:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
  card:SetBackdropBorderColor(Theme.GOLD[1] * 0.7, Theme.GOLD[2] * 0.7, Theme.GOLD[3] * 0.7, 0.85)

  local grad = card:CreateTexture(nil, "BACKGROUND")
  grad:SetPoint("TOPLEFT", 4, -4); grad:SetPoint("BOTTOMRIGHT", -4, 4)
  grad:SetColorTexture(1, 1, 1, 1)
  card.grad = grad

  local accent = card:CreateTexture(nil, "ARTWORK")
  accent:SetWidth(4); accent:SetPoint("TOPLEFT", 6, -8); accent:SetPoint("BOTTOMLEFT", 6, 8)
  card.accent = accent

  -- class icon (shown when we know the active partner's class)
  local icon = card:CreateTexture(nil, "ARTWORK")
  icon:SetSize(40, 40); icon:SetPoint("LEFT", card, "LEFT", 18, 0)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  card.icon = icon

  local name = card:CreateFontString(nil, "OVERLAY")
  name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -1)
  setFont(name, 20); name:SetJustifyH("LEFT")
  card.name = name

  local status = card:CreateFontString(nil, "OVERLAY")
  status:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -5)
  setFont(status, 13); status:SetJustifyH("LEFT")
  card.status = status

  local meta = card:CreateFontString(nil, "OVERLAY")
  meta:SetPoint("RIGHT", card, "RIGHT", -16, 8)
  setFont(meta, 13); meta:SetJustifyH("RIGHT")
  meta:SetTextColor(0.86, 0.82, 0.70)
  card.meta = meta

  local unpair = Widgets.Button(card, L["Unpair"], 76, 22)
  unpair:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -14, 10)
  card.unpair = unpair

  return card
end

local function refreshHero(card, active, short)
  card:SetWidth(math.min(card._W or COL_W, COL_W))
  local p = ns.state.partner
  local linked = ns.state.linked

  if not active then
    -- No active partner.
    card.grad:SetColorTexture(0.05, 0.05, 0.06, 0.6)
    card.accent:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    card.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    card.icon:SetDesaturated(true)
    card.name:SetText("|cff9a9a9a" .. L["No active partner"] .. "|r")
    card.status:SetText("|cff808080" .. L["Pick one below, or invite someone to get started."] .. "|r")
    card.meta:SetText("")
    card.unpair:Hide()
    return
  end

  card.unpair:Show()
  card.unpair:SetScript("OnClick", function() if ns.Pairing then ns.Pairing.Unpair() end end)

  local cls = p and p.cls
  local r, g, b = S.classColor(cls)

  -- card tint: green when connected, neutral-warm when waiting
  if linked then
    if CreateColor then
      card.grad:SetGradient("VERTICAL", CreateColor(0.04, 0.07, 0.04, 0.85), CreateColor(0.10, 0.20, 0.10, 0.6))
    else card.grad:SetColorTexture(0.08, 0.16, 0.08, 0.7) end
    card.accent:SetColorTexture(0.27, 1, 0.27, 0.9)
  else
    if CreateColor then
      card.grad:SetGradient("VERTICAL", CreateColor(0.06, 0.06, 0.04, 0.85), CreateColor(0.20, 0.16, 0.06, 0.55))
    else card.grad:SetColorTexture(0.16, 0.13, 0.06, 0.7) end
    card.accent:SetColorTexture(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.9)
  end

  -- class icon
  card.icon:SetDesaturated(false)
  local atlas = cls and ("classicon-" .. strlower(cls))
  if atlas and Theme.AtlasExists(atlas) then
    card.icon:SetAtlas(atlas)
  elseif cls and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls] then
    card.icon:SetTexture(Theme.CLASS_CIRCLES); card.icon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[cls]))
  else
    card.icon:SetTexture("Interface\\Icons\\Achievement_Reputation_08"); card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  end

  card.name:SetText(S.hex(r, g, b) .. short(active) .. "|r")

  -- status line
  if linked then
    local ago = (p and p.lastSeen) and (GetTime() - p.lastSeen) or nil
    local when = (ago and ago > 2) and ("  ·  " .. L["synced "] .. S.fmtTime(ago) .. L[" ago"]) or ("  ·  " .. L["syncing live"])
    card.status:SetText("|cff44ff44● " .. L["Connected"] .. "|r|cff7a7a7a" .. when .. "|r")
  else
    card.status:SetText("|cffe0a020○ " .. L["Waiting for sync…"] .. "|r |cff7a7a7a" .. L["(they may be offline)"] .. "|r")
  end

  -- meta (spec/class · level · ilvl) when we have a snapshot
  if p then
    local bits = {}
    local sp, cn = S.specInfo(p.spec), S.classDisplayName(cls)
    local line1 = ((sp ~= "" and sp .. " ") or "") .. (cn or "")
    if line1 ~= "" then bits[#bits + 1] = line1 end
    local l2 = {}
    if (p.lvl or 0) > 0 then l2[#l2 + 1] = "Lv " .. p.lvl end
    if (p.ilvl or 0) > 0 then l2[#l2 + 1] = "|cffffd100" .. p.ilvl .. "|r ilvl" end
    if #l2 > 0 then bits[#bits + 1] = table.concat(l2, "  ·  ") end
    card.meta:SetText(table.concat(bits, "\n"))
  else
    card.meta:SetText("")
  end
end

-- ---------------------------------------------------------------------------
-- Saved (inactive) roster rows — pooled
-- ---------------------------------------------------------------------------
local function makeRow(parent)
  local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
  row:SetHeight(ROW_H)
  row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
    insets = { left = 2, right = 2, top = 2, bottom = 2 } })
  row:SetBackdropColor(1, 1, 1, 0.03)
  row:SetBackdropBorderColor(0.35, 0.35, 0.35, 0.35)

  local hl = row:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(row)
  hl:SetColorTexture(1, 1, 1, 0.05); hl:Hide()
  row:SetScript("OnEnter", function() hl:Show() end)
  row:SetScript("OnLeave", function() hl:Hide() end)

  local dot = row:CreateFontString(nil, "OVERLAY")
  dot:SetPoint("LEFT", row, "LEFT", 14, 0); setFont(dot, 13)
  dot:SetText("|cff666666○|r")
  row.dot = dot

  local name = row:CreateFontString(nil, "OVERLAY")
  name:SetPoint("LEFT", dot, "RIGHT", 8, 0); setFont(name, 15)
  name:SetTextColor(0.90, 0.86, 0.74)
  row.nameFS = name

  local remove = Widgets.Button(row, L["Remove"], 74, 24)
  remove:SetPoint("RIGHT", row, "RIGHT", -10, 0)
  row.remove = remove

  local setActive = Widgets.Button(row, L["Set active"], 92, 24)
  setActive:SetPoint("RIGHT", remove, "LEFT", -8, 0)
  row.setActive = setActive

  return row
end

-- ---------------------------------------------------------------------------
-- Page
-- ---------------------------------------------------------------------------
local function build(host)
  local f = CreateFrame("Frame", nil, host)
  f:SetSize(10, 10)

  f.hActive = Widgets.SectionHeader(f)
  f.hero = makeHero(f)

  f.hSaved = Widgets.SectionHeader(f)
  f.savedEmpty = Widgets.SubText(f)
  f.savedEmpty:SetText(L["No other saved partners. Invite someone below to keep them on hand."])

  f.hAdd = Widgets.SectionHeader(f)   -- "Add a partner" description rides on the header's sub-text

  local box = Widgets.Input(f, 190, 26)
  local acOn = enableNameAutocomplete(box)
  local function doInvite()
    local n = box:GetText()
    if n and n:gsub("%s", "") ~= "" and ns.Pairing then ns.Pairing.Invite(n) end
    box:SetText(""); box:ClearFocus()
  end
  -- Enter/Escape first give the autocomplete dropdown a chance to consume the key
  -- (commit a highlighted pick / close the list); otherwise fall through to us.
  box:SetScript("OnEnterPressed", function(self)
    if acOn and AutoCompleteEditBox_OnEnterPressed(self) then return end
    doInvite()
  end)
  box:SetScript("OnEscapePressed", function(self)
    if acOn and AutoCompleteEditBox_OnEscapePressed(self) then return end
    self:SetText(""); self:ClearFocus()
  end)
  f.inviteBox = box

  local inviteBtn = Widgets.Button(f, L["Invite"], 84, 26)
  inviteBtn:SetScript("OnClick", doInvite)
  f.inviteBtn = inviteBtn

  f.rows = {}
  return f
end

local function refresh(f, ctx)
  local W = math.min(ctx.width, COL_W)
  f:SetWidth(ctx.width)

  local short = (ns.Pairing and ns.Pairing.ShortName) or function(s) return s end
  local roster = (ns.Pairing and ns.Pairing.Roster()) or {}
  local active = ns.Pairing and ns.Pairing.PartnerName()

  -- header helper: place a section header at y, return the y below its rule (and
  -- its optional sub-text). Pass `subtext` to render a description under the rule.
  local function placeHeader(h, title, y, subtext)
    h.label:ClearAllPoints()
    h.label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, y)
    Widgets.StyleHeader(h, title, W, subtext)
    return y - 30 - Widgets.SubHeight(h)
  end

  -- 1) Active partner ------------------------------------------------------
  local y = placeHeader(f.hActive, L["Active partner"], 0)
  f.hero._W = W
  f.hero:ClearAllPoints()
  f.hero:SetPoint("TOPLEFT", f, "TOPLEFT", 0, y - 4)
  refreshHero(f.hero, active, short)
  y = y - 4 - CARD_H - SECTION_GAP

  -- 2) Saved partners (everyone except the active one) ---------------------
  y = placeHeader(f.hSaved, L["Saved partners"], y)
  y = y - HEAD_PAD

  local shown = 0
  for _, full in ipairs(roster) do
    if not (active and short(active) == short(full)) then
      shown = shown + 1
      local row = f.rows[shown]
      if not row then row = makeRow(f); f.rows[shown] = row end
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", f, "TOPLEFT", 0, y)
      row:SetWidth(W)
      row:Show()
      row.nameFS:SetText(short(full))
      row.setActive:SetScript("OnClick", function() if ns.Pairing then ns.Pairing.SetActive(full) end end)
      row.remove:SetScript("OnClick", function() if ns.Pairing then ns.Pairing.RemoveFromRoster(full) end end)
      y = y - (ROW_H + ROW_GAP)
    end
  end
  for i = shown + 1, #f.rows do f.rows[i]:Hide() end

  if shown == 0 then
    f.savedEmpty:ClearAllPoints()
    f.savedEmpty:SetPoint("TOPLEFT", f, "TOPLEFT", 0, y)
    f.savedEmpty:Show()
    y = y - 28
  else
    f.savedEmpty:Hide()
  end
  y = y - SECTION_GAP

  -- 3) Add a partner -------------------------------------------------------
  y = placeHeader(f.hAdd, L["Add a partner"], y,
    L["Start typing a name — pick a suggestion (Tab) to fill the realm automatically. They'll get an invite popup to accept."])
  y = y - HEAD_PAD
  f.inviteBox:ClearAllPoints()
  f.inviteBox:SetPoint("TOPLEFT", f, "TOPLEFT", 0, y)
  f.inviteBtn:ClearAllPoints()
  f.inviteBtn:SetPoint("LEFT", f.inviteBox, "RIGHT", 10, 0)
  y = y - 40

  local h = -y + 10
  f:SetHeight(h)
  return h
end

ns.Dashboard.RegisterPage({ key = "partners", label = L["Partners"], order = 8, separator = true, build = build, refresh = refresh })
