--[[ UI/Shell/Header.lua
  The panel's shared header (ns.UI.Header): the partner's class portrait + the collapse
  (-) toggle. The title centre is intentionally blank — the partner name and the
  verdict dot/label that used to live here were removed (they read oddly, and the online
  state now surfaces in the page content / shared empty state instead).

  Header.Build(panel) constructs the widgets (collapseBtn is hung on the panel for the
  rest of the shell). Header.Update(snap) repaints the portrait each refresh; Header.Ping
  is a retired no-op kept so the presence layer can call it unconditionally.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Header = {}
ns.UI.Header = Header

local Theme = ns.UI.Theme

local panel

-- ---------------------------------------------------------------------------
-- Portrait + title helpers (tolerate the ButtonFrameTemplate's various layouts)
-- ---------------------------------------------------------------------------
local function getPortrait()
  return (panel.PortraitContainer and panel.PortraitContainer.portrait) or panel.portrait
end
local function setTitle(text)
  if panel.SetTitle then panel:SetTitle(text)
  elseif panel.TitleContainer and panel.TitleContainer.TitleText then panel.TitleContainer.TitleText:SetText(text)
  elseif _G[panel:GetName() .. "TitleText"] then _G[panel:GetName() .. "TitleText"]:SetText(text) end
end
local function setPortrait(cls)
  local p = getPortrait(); if not p then return end
  local atlas = (cls and cls ~= "") and ("classicon-" .. strlower(cls)) or nil
  if atlas and Theme.AtlasExists(atlas) then p:SetTexCoord(0, 1, 0, 1); p:SetAtlas(atlas)
  elseif cls and cls ~= "" and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls] then
    p:SetTexture(Theme.CLASS_CIRCLES); p:SetTexCoord(unpack(CLASS_ICON_TCOORDS[cls]))
  else p:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark"); p:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
end

--- Repaint the header from the current partner snapshot + verdict. The title bar no
--- longer carries the partner's name or sync state (it read oddly, especially with no
--- partner); only the class portrait still tracks the partner.
function Header.Update(snap, verdict)
  setPortrait(snap.cls)
end

--- Verdict-change flash, retired with the title-bar verdict dot. Kept as a no-op so the
--- presence layer can call it unconditionally.
function Header.Ping(color) end

--- Build the title-bar collapse toggle. (The partner name + verdict dot/label that used
--- to sit here were removed — the name lives nowhere now and the online state surfaces
--- in the page content / shared empty state instead.)
function Header.Build(p)
  panel = p
  setTitle("")

  local cb = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate"); cb:SetSize(24, 20)
  if panel.CloseButton then cb:SetPoint("RIGHT", panel.CloseButton, "LEFT", -4, 0)
  else cb:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -6) end
  cb:SetText("–")
  cb:SetScript("OnClick", function() ns.db.expanded = not ns.db.expanded; ns.Dashboard.ApplyMode() end)
  panel.collapseBtn = cb
end

return Header
