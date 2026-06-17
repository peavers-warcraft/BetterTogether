--[[ UI/Shell/Compact.lua
  The compact readiness card (ns.UI.Compact): the single-column view the panel drops to
  when collapsed (the – button). Partner identity + ilvl, the per-check rows, and a
  combined activity/status/gear/quest blurb — the passive at-a-glance layer.

  Compact.Build(content) builds the widgets; Compact.SetShown(shown) toggles them;
  Compact.Layout(snap, r, g, b) lays them out for the current snapshot and returns the
  content height the panel should size to.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Compact = {}
ns.UI.Compact = Compact

local S = ns.UI.Shared
local Theme = ns.UI.Theme
local Row = ns.UI.Row
local Layout = ns.UI.Layout
local L = ns.L

local WIDTH_COMPACT, PAD = Layout.WIDTH_COMPACT, Layout.PAD

local content     -- the panel inset the card lays out within
local c           -- the card's widget table

local function buildCompact(parent)
  local t = {}
  t.roleIcon = parent:CreateTexture(nil, "ARTWORK"); t.roleIcon:SetSize(15, 15)
  t.idFS = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); t.idFS:SetJustifyH("LEFT")
  t.ilvlFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal"); t.ilvlFS:SetJustifyH("RIGHT")
  t.rows = {}
  for _, key in ipairs({ "durability", "flask", "food", "wpn", "rune", "bags" }) do
    t.rows[key] = Row.Create(parent, Theme.ICON[key])
  end
  t.sep = parent:CreateTexture(nil, "ARTWORK"); t.sep:SetColorTexture(1, 1, 1, 0.08); t.sep:SetHeight(1)
  t.details = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  t.details:SetJustifyH("LEFT"); t.details:SetJustifyV("TOP"); t.details:SetSpacing(6)
  local ff = GameFontHighlight:GetFont(); if ff then t.details:SetFont(ff, 14) end
  return t
end

--- Show/hide the whole card (rows hidden only when hiding; Layout re-shows them).
function Compact.SetShown(shown)
  c.roleIcon:SetShown(shown); c.idFS:SetShown(shown); c.ilvlFS:SetShown(shown)
  c.sep:SetShown(shown); c.details:SetShown(shown)
  for _, r in pairs(c.rows) do if not shown then r:SetShown(false) end end
end

--- Lay the card out for `snap` (class colour r,g,b) and return its content height.
function Compact.Layout(snap, r, g, b)
  local W = WIDTH_COMPACT
  c.roleIcon:ClearAllPoints(); c.roleIcon:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -PAD)
  local sp, role = S.specInfo(snap.spec)
  local ra = S.roleAtlas(role)
  if ra then c.roleIcon:SetAtlas(ra); c.roleIcon:Show() else c.roleIcon:Hide() end
  c.idFS:ClearAllPoints()
  if c.roleIcon:IsShown() then c.idFS:SetPoint("LEFT", c.roleIcon, "RIGHT", 5, 0)
  else c.idFS:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -PAD) end
  local parts = {}
  local cn = S.classDisplayName(snap.cls)
  if sp ~= "" or cn ~= "" then table.insert(parts, S.hex(r, g, b) .. (sp ~= "" and (sp .. " ") or "") .. cn .. "|r") end
  if (snap.lvl or 0) > 0 then table.insert(parts, Theme.C.faint .. L["Lv "] .. snap.lvl .. "|r") end
  c.idFS:SetText(table.concat(parts, "  "))
  c.ilvlFS:ClearAllPoints(); c.ilvlFS:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, -PAD)
  c.ilvlFS:SetText((snap.ilvl or 0) > 0 and (Theme.C.gold .. snap.ilvl .. "|r " .. Theme.C.muted .. L["ilvl"] .. "|r") or "")

  S.setRowValues(c.rows, snap)
  local anchor, count = c.idFS, 0
  for _, key in ipairs({ "durability", "flask", "food", "wpn", "rune", "bags" }) do
    local row = c.rows[key]
    if ns.db.show[key] then
      row:SetShown(true); row:SetWidth(W - 2 * PAD)
      row.frame:ClearAllPoints()
      row.frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == c.idFS and 0 or 0, anchor == c.idFS and -8 or -3)
      anchor = row.frame; count = count + 1
    else row:SetShown(false) end
  end

  local combined = {}
  for _, fn in ipairs({ S.cActivity, S.cStatus, S.cGear, S.cQuest }) do
    local s = fn(snap); if s ~= "" then table.insert(combined, s) end
  end
  local text = table.concat(combined, "\n")
  c.details:SetWidth(W - 2 * PAD)
  c.sep:ClearAllPoints(); c.sep:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8); c.sep:SetWidth(W - 2 * PAD)
  c.sep:SetShown(text ~= "")
  c.details:ClearAllPoints(); c.details:SetPoint("TOPLEFT", c.sep, "BOTTOMLEFT", 0, -8); c.details:SetText(text)

  local h = PAD + 16 + 8 + count * (Row.HEIGHT + 3)
  if text ~= "" then h = h + 8 + 1 + 8 + c.details:GetStringHeight() end
  return h + PAD
end

--- @param inset table The panel's content inset.
function Compact.Build(inset)
  content = inset
  c = buildCompact(inset)
end

return Compact
