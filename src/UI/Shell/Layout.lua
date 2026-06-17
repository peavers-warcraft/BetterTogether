--[[ UI/Shell/Layout.lua
  Shared layout constants + width math for the dashboard shell (ns.UI.Layout). The
  panel is a fixed WIDTH_EXPANDED x PANEL_H_EXPANDED window whose content scrolls; the
  width helpers carve that fixed width into the left nav, the scrollable page host, and
  the optional right-side detail/tips pane. Every shell part reads these so the numbers
  live in exactly one place.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Layout = {}
ns.UI.Layout = Layout

Layout.WIDTH_COMPACT   = 320
Layout.WIDTH_EXPANDED  = 1280
Layout.PAD             = 16
Layout.PANEL_H_EXPANDED = 640        -- FIXED expanded height; content scrolls
Layout.CONTENT_TOP     = 60
Layout.NAV_W           = 178
Layout.NAV_BTN_H       = 32
Layout.SCROLLBAR_W     = 26
Layout.DETAIL_W        = 300         -- right-side preview pane width (when a page uses it)
Layout.HOST_X          = Layout.PAD + Layout.NAV_W + 18

local WIDTH_EXPANDED, PAD = Layout.WIDTH_EXPANDED, Layout.PAD
local HOST_X, SCROLLBAR_W, DETAIL_W = Layout.HOST_X, Layout.SCROLLBAR_W, Layout.DETAIL_W

--- Width of the page host (left nav + optional detail pane carved out).
function Layout.hostWidth(detail) return WIDTH_EXPANDED - HOST_X - PAD - (detail and (DETAIL_W + 18) or 0) end
--- Width of the scrollable column inside the host (scrollbar carved out).
function Layout.scrollWidth(detail) return Layout.hostWidth(detail) - SCROLLBAR_W end
-- Settings view has no left nav, so its content starts at PAD; it DOES reserve a
-- right-side tips pane (DETAIL_W, like the dashboard pages' detail pane), so the
-- scrollable column stops short of that pane.
function Layout.settingsHostWidth() return WIDTH_EXPANDED - PAD - PAD - (DETAIL_W + 18) end
function Layout.settingsScrollWidth() return Layout.settingsHostWidth() - SCROLLBAR_W end

return Layout
