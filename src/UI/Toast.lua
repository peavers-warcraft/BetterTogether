--[[ UI/Toast.lua
  Toast notifications (ns.UI.Toast). The dashboard is a passive panel you have to
  watch; toasts make partner presence + readiness *proactive*. A themed card slides
  in when your partner comes online, becomes ready, or drops below ready — so you
  learn it without staring at the window. That ambient awareness is the heart of
  "better together": you feel your partner getting ready beside you.

  Self-contained: themes from Theme, reuses the shared Chip, stacks up to a few at
  once (newest on top) and queues the rest, auto-dismisses after a dwell, and pauses
  the dwell while hovered. Gated by ns.db.toasts (sound by ns.db.toastSound).
]]

local addonName, ns = ...
ns.UI = ns.UI or {}
local Theme = ns.UI.Theme
local Widgets = ns.UI.Widgets
local L = ns.L

local Toast = {}
ns.UI.Toast = Toast

local MAX_VISIBLE = 3        -- on screen at once; extras queue
local DWELL = 4.5           -- seconds a toast lingers before fading
local W, H, GAP = 322, 60, 8
-- Anchor the stack to the top-centre of the screen, growing downward. Below the
-- Blizzard error/zone-text band so the two never fight for the same pixels.
local ANCHOR = { "TOP", "TOP", 0, -210 }

local active = {}            -- visible frames, index 1 = topmost
local queue = {}             -- pending payloads when the stack is full
local pool = {}              -- recycled frames

-- Re-anchor every visible toast to its slot (newest stays on top, older slide down).
local function layout()
  for i, f in ipairs(active) do
    f:ClearAllPoints()
    f:SetPoint(ANCHOR[1], UIParent, ANCHOR[2], ANCHOR[3], ANCHOR[4] - (i - 1) * (H + GAP))
  end
end

local function indexOf(f)
  for i, g in ipairs(active) do if g == f then return i end end
end

-- Pull the toast off-screen, recycle its frame, and promote a queued payload.
local function recycle(f)
  f:Hide()
  local i = indexOf(f); if i then table.remove(active, i) end
  pool[#pool + 1] = f
  layout()
  if #queue > 0 and #active < MAX_VISIBLE then
    Toast.Show(table.remove(queue, 1))
  end
end

local function build()
  local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  f:SetSize(W, H)
  f:SetFrameStrata("DIALOG")
  f:SetBackdrop(Theme.BACKDROP_TOOLTIP)
  f:SetBackdropColor(0.05, 0.055, 0.07, 0.96)
  f:SetBackdropBorderColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.9)

  -- Coloured accent bar down the left edge — the toast's state at a glance.
  f.accent = f:CreateTexture(nil, "ARTWORK")
  f.accent:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
  f.accent:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 4, 4)
  f.accent:SetWidth(3)

  f.chip = Widgets.Chip(f, 40)
  f.chip:SetPoint("LEFT", f, "LEFT", 16, 0)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  local bf = GameFontNormal:GetFont(); if bf then f.title:SetFont(bf, Theme.FONT_BODY) end
  f.title:SetTextColor(Theme.CREAM[1], Theme.CREAM[2], Theme.CREAM[3])
  f.title:SetPoint("TOPLEFT", f.chip, "TOPRIGHT", 12, -3)
  f.title:SetWidth(W - 80); f.title:SetJustifyH("LEFT"); f.title:SetWordWrap(false)

  f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  local sf = GameFontHighlight:GetFont(); if sf then f.sub:SetFont(sf, Theme.FONT_SMALL) end
  f.sub:SetTextColor(0.62, 0.62, 0.64)
  f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
  f.sub:SetWidth(W - 80); f.sub:SetJustifyH("LEFT"); f.sub:SetWordWrap(false)

  -- Intro: fade up with a soft scale-pop. Outro: fade out, then recycle.
  local ag = f:CreateAnimationGroup()
  local a = ag:CreateAnimation("Alpha"); a:SetFromAlpha(0); a:SetToAlpha(1); a:SetDuration(0.32); a:SetSmoothing("OUT")
  local sc = ag:CreateAnimation("Scale"); sc:SetScaleFrom(0.92, 0.92); sc:SetScaleTo(1, 1)
  sc:SetDuration(0.32); sc:SetSmoothing("OUT"); sc:SetOrigin("CENTER", 0, 0)
  ag:SetScript("OnFinished", function() f:SetAlpha(1) end)
  f.introAG = ag

  local og = f:CreateAnimationGroup()
  local oa = og:CreateAnimation("Alpha"); oa:SetFromAlpha(1); oa:SetToAlpha(0); oa:SetDuration(0.4); oa:SetSmoothing("IN")
  og:SetScript("OnFinished", function() recycle(f) end)
  f.outroAG = og

  -- Hover pauses the dwell (read it in peace); click dismisses it now.
  f:EnableMouse(true)
  f:SetScript("OnEnter", function(self) if self._timer then self._timer:Cancel(); self._timer = nil end end)
  f:SetScript("OnLeave", function(self)
    if self._dismissing then return end
    self._timer = C_Timer.NewTimer(1.5, function() self._timer = nil; Toast.Dismiss(self) end)
  end)
  f:SetScript("OnMouseUp", function(self) Toast.Dismiss(self) end)
  return f
end

--- Fade a toast out now (no-op if it's already leaving).
function Toast.Dismiss(f)
  if not f or f._dismissing then return end
  f._dismissing = true
  if f._timer then f._timer:Cancel(); f._timer = nil end
  f.introAG:Stop()
  f.outroAG:Play()
end

--- Show a toast.
--- @param p table { title, subtitle?, icon?, color? {r,g,b}, sound?, dwell? }
function Toast.Show(p)
  if not p then return end
  if ns.db and ns.db.toasts == false then return end
  if #active >= MAX_VISIBLE then queue[#queue + 1] = p; return end

  local f = table.remove(pool) or build()
  f._dismissing = nil
  local col = p.color or Theme.GOLD
  f.accent:SetColorTexture(col[1], col[2], col[3], 0.95)
  f.chip.rim:SetColorTexture(col[1], col[2], col[3], 0.7)   -- ring echoes the state colour
  if p.icon then Theme.ApplyIcon(f.chip.icon, p.icon) end
  f.title:SetText(p.title or "")
  f.sub:SetText(p.subtitle or "")
  f.sub:SetShown((p.subtitle or "") ~= "")

  f:SetAlpha(0); f:Show()
  active[#active + 1] = f
  layout()
  f.outroAG:Stop(); f.introAG:Stop(); f.introAG:Play()

  if p.sound and not (ns.db and ns.db.toastSound == false) then
    pcall(PlaySound, p.sound)
  end
  f._timer = C_Timer.NewTimer(p.dwell or DWELL, function() f._timer = nil; Toast.Dismiss(f) end)
  return f
end

--- Clear every toast immediately (e.g. on unpair). Cheap; safe to call any time.
function Toast.Clear()
  wipe(queue)
  for i = #active, 1, -1 do
    local f = active[i]
    if f._timer then f._timer:Cancel(); f._timer = nil end
    f.introAG:Stop(); f.outroAG:Stop()
    f:Hide(); pool[#pool + 1] = f
    table.remove(active, i)
  end
end

return Toast
