--[[ UI/Pages/ReadyCheck.lua
  Ready Check page + ns.ReadyCheck handlers (called by Comm). Either partner can
  start a check; both clients evaluate their own readiness verdict and exchange
  it, with the ready-check sound. Shows You / Partner results.
]]

local addonName, ns = ...
local S = ns.UI.Shared

local SECTION_GAP = 22

-- ---------------------------------------------------------------------------
-- State + Comm handlers
-- ---------------------------------------------------------------------------
local ReadyCheck = {}
ns.ReadyCheck = ReadyCheck
ReadyCheck.state = { you = nil, partner = nil }   -- each: { ready=bool, verdict=string }

local function refreshUI() if ns.Dashboard then ns.Dashboard.Refresh() end end

function ReadyCheck.OnSent(ready, verdict)
  ReadyCheck.state.you = { ready = ready, verdict = verdict }
  ReadyCheck.state.partner = nil   -- waiting for their RCACK
  refreshUI()
end
function ReadyCheck.OnIncoming(myReady, myVerdict, theirReady, theirVerdict)
  ReadyCheck.state.you = { ready = myReady, verdict = myVerdict }
  ReadyCheck.state.partner = { ready = theirReady, verdict = theirVerdict }
  ns:Print("|cffffff00" .. (ns.state.partnerName or "Partner") .. "|r started a ready check")
  refreshUI()
end
function ReadyCheck.OnResponse(ready, verdict)
  ReadyCheck.state.partner = { ready = ready, verdict = verdict }
  refreshUI()
end

-- ---------------------------------------------------------------------------
-- Page
-- ---------------------------------------------------------------------------
local function makeResultRow(parent)
  local row = CreateFrame("Frame", nil, parent); row:SetHeight(34)
  row.dot = row:CreateTexture(nil, "ARTWORK"); row.dot:SetSize(20, 20); row.dot:SetPoint("LEFT", row, "LEFT", 2, 0)
  row.fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  row.fs:SetPoint("LEFT", row.dot, "RIGHT", 10, 0); row.fs:SetJustifyH("LEFT")
  return row
end

local function build(host)
  local f = CreateFrame("Frame", nil, host)
  f:SetSize(10, 10)   -- scroll child; sized in refresh
  local ff = GameFontHighlight:GetFont()

  f.intro = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.intro:SetJustifyH("LEFT"); f.intro:SetWidth(420); f.intro:SetSpacing(6)
  if ff then f.intro:SetFont(ff, 15) end
  f.intro:SetText("Start a ready check to confirm you're both prepared before a pull. " ..
    "Each of you is evaluated against your readiness checks (flask, food, durability, bags…).")

  f.btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.btn:SetSize(200, 30); f.btn:SetText("Ready Check")
  f.btn:SetScript("OnClick", function() if ns.Comm and ns.Comm.SendReadyCheck then ns.Comm.SendReadyCheck() end end)

  f.header = S.makeSectionHeader(f)
  f.youRow = makeResultRow(f)
  f.partnerRow = makeResultRow(f)
  return f
end

local function setResult(row, who, state)
  if not state then
    row.dot:SetTexture(S.INDICATOR.wait)
    row.fs:SetText("|cffb0b0b0" .. who .. ": waiting…|r")
    return
  end
  local v = state.verdict or (state.ready and "ready" or "red")
  row.dot:SetTexture(S.INDICATOR[v] or S.INDICATOR.wait)
  local c = S.VERDICT_RGB[v] or S.VERDICT_RGB.wait
  local word = state.ready and "Ready" or "Not ready"
  local extra = (not state.ready and v ~= "ready") and ("  |cff909090(" .. v .. ")|r") or ""
  row.fs:SetText(who .. ":  " .. S.hex(c[1], c[2], c[3]) .. word .. "|r" .. extra)
end

local function refresh(f, ctx)
  local W = ctx.width
  f:SetWidth(W)
  f.intro:ClearAllPoints(); f.intro:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -2); f.intro:SetWidth(W - 10)
  f.btn:ClearAllPoints(); f.btn:SetPoint("TOPLEFT", f.intro, "BOTTOMLEFT", 0, -16)

  f.header.label:ClearAllPoints(); f.header.label:SetPoint("TOPLEFT", f.btn, "BOTTOMLEFT", 0, -SECTION_GAP)
  S.styleHeader(f.header, "Result", W)

  local you, partner = ReadyCheck.state.you, ReadyCheck.state.partner
  if ns.db.demoMode and not you then
    you = { ready = true, verdict = "ready" }; partner = { ready = false, verdict = "red" }
  end
  setResult(f.youRow, "You", you)
  setResult(f.partnerRow, ns.state.partnerName or "Partner", partner)

  f.youRow:ClearAllPoints(); f.youRow:SetPoint("TOPLEFT", f.header.diamond, "BOTTOMLEFT", -3, -12)
  f.partnerRow:ClearAllPoints(); f.partnerRow:SetPoint("TOPLEFT", f.youRow, "BOTTOMLEFT", 0, -6)

  local h = f.intro:GetStringHeight() + 16 + 30 + SECTION_GAP + S.HEADER_H + 12 + 34 + 6 + 34 + 10
  f:SetHeight(h)
  return h
end

ns.Dashboard.RegisterPage({ key = "readycheck", label = "Ready Check", order = 3, build = build, refresh = refresh })
