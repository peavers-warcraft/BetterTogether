--[[ UI/Shell/EmptyState.lua
  The shared centered "nothing to show here" state (ns.UI.EmptyState). Every data page
  reads as a comparison between you and your partner, so several situations leave a page
  with nothing useful to draw — no live partner, or a partner who's turned off sharing
  that data type. Rather than each page (and the right-side detail pane) showing its own
  half-empty layout, the shell swaps the whole content area (everything right of the left
  nav, detail pane included) for this one centered prompt.

  It owns only the *surface*: a logo chip, a title, a subtitle and an optional button.
  Callers describe WHAT to say with a spec — { title, sub, button = { text, onClick } }
  (button optional) — so the copy lives at the call site while the look lives here, in
  one place to tweak. Dashboard.Refresh decides WHEN to show it (and builds the no-partner
  spec via EmptyState.NoPartnerSpec); pages contribute their own specs via desc.emptyState.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local EmptyState = {}
ns.UI.EmptyState = EmptyState

local Theme = ns.UI.Theme
local Widgets = ns.UI.Widgets
local Layout = ns.UI.Layout
local L = ns.L

local PAD, HOST_X = Layout.PAD, Layout.HOST_X
local CREAM = Theme.CREAM

-- The addon's own art, shown in the chip as a calm bit of branding for the prompt.
local LOGO = "Interface\\AddOns\\BetterTogether\\src\\Media\\Icon.tga"

-- ---------------------------------------------------------------------------
-- Build (once, in Dashboard.Init). Spans the content area right of the nav so the
-- prompt sits centered across the page host AND the detail-pane column.
-- ---------------------------------------------------------------------------
--- @param content table The panel's content inset.
function EmptyState.Build(content)
  local f = CreateFrame("Frame", nil, content)
  f:SetPoint("TOPLEFT", content, "TOPLEFT", HOST_X, -PAD)
  f:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -PAD, PAD)
  EmptyState.frame = f

  -- A centered vertical stack: chip → title → subtitle → (optional) button. Anchored
  -- a touch above the frame's middle so the whole block reads as optically centered.
  local chip = Widgets.Chip(f, 72, LOGO)
  chip:SetPoint("CENTER", f, "CENTER", 0, 78)
  EmptyState.chip = chip

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  local ff = GameFontHighlight:GetFont()
  if ff then title:SetFont(ff, Theme.FONT_TITLE) end
  title:SetTextColor(CREAM[1], CREAM[2], CREAM[3])
  title:SetPoint("TOP", chip, "BOTTOM", 0, -18)
  EmptyState.title = title

  local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if ff then sub:SetFont(ff, Theme.FONT_SUBHEADER) end
  sub:SetTextColor(Theme.SUBHEADER_COLOR[1], Theme.SUBHEADER_COLOR[2], Theme.SUBHEADER_COLOR[3])
  sub:SetJustifyH("CENTER"); sub:SetSpacing(5); sub:SetWidth(420)
  sub:SetPoint("TOP", title, "BOTTOM", 0, -12)
  EmptyState.sub = sub

  local btn = Widgets.Button(f, "", 160, 30)
  btn:SetPoint("TOP", sub, "BOTTOM", 0, -22)
  EmptyState.btn = btn

  f:Hide()
end

-- ---------------------------------------------------------------------------
-- Specs
-- ---------------------------------------------------------------------------
--- Spec for the no-partner state, with copy tailored to why there's no partner.
--- @param verdict string "offline" (bonded partner logged off) or anything else
---   (no partner bonded yet — the generic pair prompt).
--- @param name string|nil Partner short name (used by the offline message).
--- @return table spec
function EmptyState.NoPartnerSpec(verdict, name)
  local spec = {
    button = { text = L["Manage partners"],
      onClick = function() if ns.Dashboard then ns.Dashboard.Select("partners") end end },
  }
  if verdict == "offline" then
    spec.title = string.format(L["%s is offline"], name or L["Your partner"])
    spec.sub = L["You'll see their inventory, quests and more here once they come online."]
  else
    spec.title = L["No partner connected"]
    spec.sub = L["Pair with a partner to compare your inventory, quests, achievements and more."]
  end
  return spec
end

-- ---------------------------------------------------------------------------
-- Show / hide
-- ---------------------------------------------------------------------------
--- Render a spec: { title, sub, button = { text, onClick } }. The button is hidden
--- when spec.button is nil (e.g. the partner-opted-out states, which have no action).
--- @param spec table
function EmptyState.Show(spec)
  local f = EmptyState.frame
  if not f or not spec then return end
  EmptyState.title:SetText(spec.title or "")
  EmptyState.sub:SetText(spec.sub or "")
  local b = spec.button
  if b then
    EmptyState.btn.fs:SetText(b.text or "")
    EmptyState.btn:SetScript("OnClick", b.onClick)
    EmptyState.btn:Show()
  else
    EmptyState.btn:Hide()
  end
  f:Show()
end

--- @param shown boolean
function EmptyState.SetShown(shown)
  if EmptyState.frame then EmptyState.frame:SetShown(shown) end
end

return EmptyState
