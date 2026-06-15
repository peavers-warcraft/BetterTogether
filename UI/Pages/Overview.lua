--[[ UI/Pages/Overview.lua
  Overview page: live 3D model + identity + big verdict on the left, and three
  content columns (Readiness / Activity+Location / Gear+Quest) on the right.
]]

local addonName, ns = ...
local S = ns.UI.Shared
local Row = ns.UI.Row

local MODEL_W, MODEL_H = 280, 420
local SECTION_GAP, ROW_GAP, COL_GAP = 22, 6, 30

local function build(host)
  local f = CreateFrame("Frame", nil, host)
  f:SetSize(10, 10)   -- scroll child; sized in refresh

  -- model box
  local mb = CreateFrame("Frame", nil, f, "BackdropTemplate")
  mb:SetSize(MODEL_W, MODEL_H)
  mb:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  mb:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  mb:SetBackdropColor(0, 0, 0, 0.5)
  mb:SetBackdropBorderColor(S.GOLD[1] * 0.7, S.GOLD[2] * 0.7, S.GOLD[3] * 0.7, 0.9)
  f.modelBox = mb

  local bg = mb:CreateTexture(nil, "BACKGROUND")
  bg:SetPoint("TOPLEFT", mb, "TOPLEFT", 5, -5); bg:SetPoint("BOTTOMRIGHT", mb, "BOTTOMRIGHT", -5, 5)
  bg:SetColorTexture(1, 1, 1, 1); f.modelBg = bg

  local model = CreateFrame("PlayerModel", nil, mb)
  model:SetPoint("TOPLEFT", mb, "TOPLEFT", 5, -5); model:SetPoint("BOTTOMRIGHT", mb, "BOTTOMRIGHT", -5, 5)
  model:EnableMouse(true); model:EnableMouseWheel(true)
  model:SetScript("OnMouseDown", function(self, btn) if btn == "LeftButton" then self.rotating = true; self.cx = GetCursorPosition(); self.sf = self.facing or 0 end end)
  model:SetScript("OnMouseUp", function(self) self.rotating = false end)
  model:SetScript("OnUpdate", function(self)
    if self.rotating then local x = GetCursorPosition(); self.facing = (self.sf or 0) + (x - self.cx) * 0.012; self:SetFacing(self.facing) end
  end)
  model:SetScript("OnMouseWheel", function(self, d) self.zoom = math.min(1, math.max(0, (self.zoom or 0) + d * 0.1)); self:SetPortraitZoom(self.zoom) end)
  f.model = model

  local mf = mb:CreateTexture(nil, "ARTWORK"); mf:SetPoint("CENTER"); mf:SetSize(120, 120); mf:Hide()
  f.modelFallback = mf

  local exInfo = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  exInfo:SetJustifyH("CENTER"); exInfo:SetSpacing(6); exInfo:SetWidth(MODEL_W)
  local ff = GameFontHighlight:GetFont(); if ff then exInfo:SetFont(ff, 16) end
  f.exInfo = exInfo
  local exVerdict = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  exVerdict:SetJustifyH("CENTER"); exVerdict:SetWidth(MODEL_W)
  if ff then exVerdict:SetFont(ff, 22) end
  f.exVerdict = exVerdict

  f.headers = {}
  for _, k in ipairs({ "readiness", "activity", "status", "gear", "quest" }) do
    f.headers[k] = S.makeSectionHeader(f)
  end
  f.rows = {}
  for _, k in ipairs({ "durability", "flask", "food", "wpn", "rune", "bags" }) do
    f.rows[k] = Row.Create(f, S.ICON[k])
  end
  f.nowRows = {}
  for i = 1, 4 do f.nowRows[i] = Row.CreateInfo(f, S.ICON.bags) end
  f.bodies = {}
  for _, k in ipairs({ "activity", "status", "gear", "quest" }) do
    local b = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b:SetJustifyH("LEFT"); b:SetJustifyV("TOP"); b:SetSpacing(7)
    if ff then b:SetFont(ff, 15) end
    f.bodies[k] = b
  end
  return f
end

local function refresh(f, ctx)
  local snap, verdict, W = ctx.snap, ctx.verdict, ctx.width
  local r, g, b = ctx.r, ctx.g, ctx.b
  f:SetWidth(W)

  -- model
  if CreateColor then
    f.modelBg:SetGradient("VERTICAL", CreateColor(0.02, 0.02, 0.03, 0.9), CreateColor(r * 0.35, g * 0.35, b * 0.35, 0.55))
  else f.modelBg:SetColorTexture(0.04, 0.04, 0.05, 0.85) end
  local unit = S.partnerUnit()
  if unit and UnitExists(unit) then
    f.model:Show(); f.modelFallback:Hide()
    if f.model.currentUnit ~= unit then
      f.model.currentUnit = unit
      pcall(function() f.model:SetUnit(unit); f.model.facing = 0.3; f.model:SetFacing(0.3) end)
    end
  else
    f.model.currentUnit = nil; f.model:Hide()
    local mf = f.modelFallback
    local atlas = (snap.cls and snap.cls ~= "") and ("classicon-" .. strlower(snap.cls)) or nil
    if atlas and S.atlasExists(atlas) then mf:SetTexCoord(0, 1, 0, 1); mf:SetAtlas(atlas)
    elseif snap.cls and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[snap.cls] then mf:SetTexture(S.CLASS_CIRCLES); mf:SetTexCoord(unpack(CLASS_ICON_TCOORDS[snap.cls]))
    else mf:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark"); mf:SetTexCoord(.08, .92, .08, .92) end
    mf:Show()
  end

  local sp = (S.specInfo(snap.spec)); local cn = S.classDisplayName(snap.cls)
  local info = {}
  if sp ~= "" or cn ~= "" then table.insert(info, S.hex(r, g, b) .. (sp ~= "" and (sp .. " ") or "") .. cn .. "|r") end
  local l2 = {}
  if (snap.lvl or 0) > 0 then table.insert(l2, "Lv " .. snap.lvl) end
  if (snap.ilvl or 0) > 0 then table.insert(l2, "|cffffd100" .. snap.ilvl .. "|r ilvl") end
  if #l2 > 0 then table.insert(info, table.concat(l2, "  ·  ")) end
  f.exInfo:ClearAllPoints(); f.exInfo:SetPoint("TOP", f.modelBox, "BOTTOM", 0, -12); f.exInfo:SetText(table.concat(info, "\n"))
  f.exVerdict:Hide()   -- verdict already shown in the title bar

  -- Decluttered: model | Readiness | Now (gear/quest/supplies live on their tabs)
  local rcX = MODEL_W + 48
  local READY_W = 320
  local nowX = rcX + READY_W + COL_GAP + 10
  local nowW = math.max(220, W - nowX)

  -- hide unused headers/bodies
  for _, k in ipairs({ "status", "gear", "quest" }) do S.hideHeader(f.headers[k]); f.bodies[k]:Hide() end

  -- Readiness
  f.headers.readiness.label:ClearAllPoints()
  f.headers.readiness.label:SetPoint("TOPLEFT", f, "TOPLEFT", rcX, 0)
  S.styleHeader(f.headers.readiness, "Readiness", READY_W)
  S.setRowValues(f.rows, snap)
  local anchor, count = f.headers.readiness.diamond, 0
  for _, key in ipairs({ "durability", "flask", "food", "wpn", "rune", "bags" }) do
    local row = f.rows[key]
    if ns.db.show[key] then
      row:SetShown(true); row:SetWidth(READY_W)
      row.frame:ClearAllPoints()
      row.frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == f.headers.readiness.diamond and -3 or 0, anchor == f.headers.readiness.diamond and -8 or -ROW_GAP)
      anchor = row.frame; count = count + 1
    else row:SetShown(false) end
  end
  local col1H = S.HEADER_H + count * (Row.HEIGHT + ROW_GAP)

  -- Now (current activity + location) — rendered as chip info-rows like Readiness
  f.bodies.activity:Hide()
  local items = {}
  if (snap.zone or "") ~= "" then
    items[#items + 1] = { icon = S.I_LOC, label = "Location", value = snap.zone .. (snap.rest and "  |cff6cb6ff(resting)|r" or "") }
  end
  if (snap.cx or 0) > 0 or (snap.cy or 0) > 0 then
    items[#items + 1] = { icon = S.I_COORDS, label = "Coordinates", value = string.format("%.1f, %.1f", snap.cx or 0, snap.cy or 0) }
  end
  if (snap.key or "") ~= "" and (snap.klvl or 0) > 0 then
    items[#items + 1] = { icon = S.I_KEY, label = "Keystone", value = "|cffa335ee" .. S.midTruncate(snap.key, 16) .. " +" .. snap.klvl .. "|r" }
  end
  if (snap.gold or 0) > 0 then
    items[#items + 1] = { icon = S.I_GOLD, label = "Gold", value = S.fmtGold(snap.gold) }
  end

  local col2H = 0
  if #items > 0 then
    f.headers.activity.label:ClearAllPoints()
    f.headers.activity.label:SetPoint("TOPLEFT", f, "TOPLEFT", nowX, 0)
    S.styleHeader(f.headers.activity, "Now", nowW)
    local anchor2 = f.headers.activity.diamond
    for i, it in ipairs(items) do
      local r = f.nowRows[i]
      r:SetShown(true); r:SetWidth(nowW); r:SetIcon(it.icon); r:Set(it.label, it.value)
      r.frame:ClearAllPoints()
      r.frame:SetPoint("TOPLEFT", anchor2, "BOTTOMLEFT", anchor2 == f.headers.activity.diamond and -3 or 0, anchor2 == f.headers.activity.diamond and -8 or -ROW_GAP)
      anchor2 = r.frame
    end
    col2H = S.HEADER_H + #items * (Row.HEIGHT + ROW_GAP)
  else
    S.hideHeader(f.headers.activity)
  end
  for i = #items + 1, 4 do f.nowRows[i]:SetShown(false) end

  local modelColH = MODEL_H + 14 + f.exInfo:GetStringHeight() + 10
  local h = math.max(modelColH, col1H, col2H)
  f:SetHeight(h)
  return h
end

ns.Dashboard.RegisterPage({ key = "overview", label = "Overview", order = 1, build = build, refresh = refresh })
