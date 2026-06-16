--[[ UI/Theme.lua
  The single source of truth for BetterTogether's look: palette, fonts, spacing, backdrop
  presets, icon paths, and the small texture helpers every widget shares. No frames
  are created here — only constants + pure helpers. Loaded before Widgets/Row/pages
  so all of them theme from one place. (ns.UI.Theme)

  Why this exists: colours, font sizes, and the circular-chip art used to be copied
  inline across Row, Dashboard, and every page (GOLD was defined twice; the chip
  fill 0.09,0.09,0.12 appeared in three files). Centralising them makes a reskin a
  one-file change and guarantees the mixed in-game art reads as one cohesive set.
]]

local addonName, ns = ...

ns.UI = ns.UI or {}
local Theme = {}
ns.UI.Theme = Theme

local L = ns.L

-- ---------------------------------------------------------------------------
-- Palette (Plumber-ish warm gold + cream over a near-black panel)
-- ---------------------------------------------------------------------------
Theme.GOLD  = { 0.83, 0.67, 0.33 }
Theme.CREAM = { 0.96, 0.90, 0.74 }

-- Named dark fills that used to be bare magic numbers at each call site.
Theme.BG_BUTTON       = { 0.12, 0.10, 0.05 }   -- themed button rest
Theme.BG_BUTTON_HOVER = { 0.20, 0.16, 0.07 }   -- themed button hover
Theme.BG_INPUT        = { 0.03, 0.03, 0.04 }    -- themed edit box
Theme.CHIP_FILL       = { 0.09, 0.09, 0.12 }    -- circular chip interior

-- Shared alphas for the recurring overlays.
Theme.RIM_ALPHA = 0.55   -- gold rim on a chip
Theme.HL_ALPHA  = 0.05   -- white hover highlight
Theme.SEL_ALPHA = 0.14   -- gold persistent-selection tint

-- Inline text-colour escapes (full |cffRRGGBB prefix; pair with "|r"). Centralised
-- so coloured inline text shares one palette instead of hand-typed hex scattered at
-- each call site (the dashboard detail panes and settings used to do this inline).
-- Values preserve the existing look — this is a single source of truth, not a reskin.
Theme.C = {
  white  = "|cffffffff",   -- emphasis / values
  gold   = "|cffffd100",   -- bright gold numerals (item level, counts)
  ready  = "|cff44ff44",   -- positive / "yes"
  danger = "|cffff5555",   -- negative / "no"
  orange = "|cffff8000",   -- warning label (no enchant, empty sockets)
  warn   = "|cffffcc33",   -- caution amber text
  info   = "|cff6cb6ff",   -- info blue (resting, hints)
  epic   = "|cffa335ee",   -- epic purple (keystones)
  faint  = "|cffb0b0b0",   -- "Lv" prefix grey
  muted  = "|cff9d9d9d",   -- de-emphasised label (ilvl)
  muted2 = "|cffaaaaaa",   -- secondary muted (loading text)
  soft   = "|cffd0d0d0",   -- soft body text
  dim    = "|cff808080",   -- faintest note grey
  accent = "|cff66ccff",   -- addon accent blue (print prefix, settings headers)
}

--- Build an inline colour escape (|cffRRGGBB) from an RGB triple (e.g. Theme.GOLD).
--- Lets per-line/quality colours derive from the same palette the rest of the UI uses.
--- @param rgb table {r,g,b} components in 0..1.
--- @return string prefix The "|cffRRGGBB" escape (pair with "|r").
function Theme.Hex(rgb)
  return string.format("|cff%02x%02x%02x", rgb[1] * 255, rgb[2] * 255, rgb[3] * 255)
end

-- ---------------------------------------------------------------------------
-- Verdict indicators (spec §8.2). Labels run through the locale table.
-- ---------------------------------------------------------------------------
Theme.INDICATOR = {
  ready = "Interface\\COMMON\\Indicator-Green", amber = "Interface\\COMMON\\Indicator-Yellow",
  red   = "Interface\\COMMON\\Indicator-Red",   wait  = "Interface\\COMMON\\Indicator-Gray",
  offline = "Interface\\COMMON\\Indicator-Gray",
}
Theme.VERDICT_RGB = {
  ready = { 0.30, 0.85, 0.40 }, amber = { 0.98, 0.78, 0.20 },
  red   = { 0.95, 0.32, 0.32 }, wait  = { 0.70, 0.70, 0.72 },
  offline = { 0.55, 0.55, 0.58 },
}
Theme.VERDICT_LABEL = {
  ready = L["READY"], amber = L["CHECK"], red = L["NOT READY"], wait = L["WAITING"],
  offline = L["OFFLINE"],
}

-- ---------------------------------------------------------------------------
-- Icon paths. Readiness-row icons live in ICON; one-off section icons are I_*.
-- ---------------------------------------------------------------------------
Theme.ICON = {
  durability = "Interface\\Icons\\Trade_BlackSmithing",
  flask      = "Interface\\Icons\\INV_Potion_97",
  food       = "Interface\\Icons\\INV_Misc_Food_15",
  wpn        = "Interface\\Icons\\INV_Stone_SharpeningStone_05",
  rune       = "Interface\\Icons\\INV_Misc_Rune_01",
  bags       = "Interface\\Icons\\INV_Misc_Bag_08",
}
Theme.I_KEY    = "Interface\\Icons\\INV_Relics_Hourglass"
Theme.I_VAULT  = "Interface\\Icons\\INV_Misc_Treasurechest_Battered"
Theme.I_LOC    = "Interface\\Icons\\INV_Misc_Map02"
Theme.I_COORDS = "Interface\\Icons\\INV_Misc_Map_01"
Theme.I_GOLD   = "Interface\\MoneyFrame\\UI-GoldIcon"
Theme.I_GEAR   = "Interface\\Icons\\Trade_Engineering"
Theme.I_SUP    = "Interface\\Icons\\INV_Potion_54"
-- Crisp atlas "?" quest marker (vector-sharp at any chip size). The old
-- Interface\GossipFrame\ActiveQuestIcon is a tiny low-res texture that looked
-- blurry/pixelated blown up in our chips, so prefer a high-res atlas and only
-- fall back to that file on clients that lack one.
Theme.I_QUEST = "Interface\\GossipFrame\\ActiveQuestIcon"
do
  local info = C_Texture and C_Texture.GetAtlasInfo
  for _, a in ipairs({ "QuestTurnin", "Quest-Important-TurnIn", "quest-recipe-turnin" }) do
    if info and info(a) then Theme.I_QUEST = a; break end
  end
end
Theme.I_BOSS    = "Interface\\Icons\\Achievement_Boss_Ragnaros"
Theme.I_DUNGEON = "Interface\\Icons\\Achievement_ChallengeMode_Gold"
Theme.I_DEATH   = "Interface\\Icons\\Ability_Rogue_FeignDeath"
Theme.I_TIME    = "Interface\\Icons\\INV_Misc_PocketWatch_01"
Theme.I_MOB     = "Interface\\Icons\\Ability_DualWield"

Theme.CLASS_CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
-- Circular alpha mask shared by every chip (rim + fill + icon).
Theme.CIRCLE_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

-- Generic textures reused by backdrops.
Theme.WHITE8X8       = "Interface\\Buttons\\WHITE8X8"
Theme.TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"

-- ---------------------------------------------------------------------------
-- Backdrop presets (safe to share — call sites never mutate them).
-- ---------------------------------------------------------------------------
-- Soft 12px tooltip border with a solid fill — buttons, inputs, the model box.
Theme.BACKDROP_TOOLTIP = {
  bgFile = Theme.WHITE8X8, edgeFile = Theme.TOOLTIP_BORDER, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
-- Crisp 1px hairline border with a solid fill — tiles, cards, mini nav buttons.
Theme.BACKDROP_HAIRLINE = {
  bgFile = Theme.WHITE8X8, edgeFile = Theme.WHITE8X8, edgeSize = 1,
  insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

-- ---------------------------------------------------------------------------
-- Type scale. Sizes the shared widgets use; one-off display numbers (the big
-- verdict, stat tiles) stay local to their page with a comment.
-- ---------------------------------------------------------------------------
Theme.FONT_TITLE     = 20   -- partner hero name
Theme.FONT_HEADER    = 17   -- section-header label
Theme.FONT_BODY      = 15   -- page body paragraphs + readiness rows
Theme.FONT_ROW       = 15   -- row label/value
Theme.FONT_NAV       = 15   -- left-nav buttons
Theme.FONT_SMALL     = 14   -- compact details, secondary body
Theme.FONT_SUBHEADER = 13   -- sub-text + detail-pane lines

-- ---------------------------------------------------------------------------
-- Spacing
-- ---------------------------------------------------------------------------
Theme.HEADER_H = 18 + 6 + 8   -- label + gap + rule, the height a section header reserves
Theme.SECTION_GAP = 24        -- default vertical gap between sections (pages may override)
Theme.ROW_GAP = 6             -- default gap between stacked rows

-- Sub-text shown beneath a section header. Centralised so every page renders it at
-- the SAME size + colour (pages used to pick their own — 12/13/14 across the UI).
Theme.SUBHEADER_SIZE  = 13
Theme.SUBHEADER_COLOR = { 0.5, 0.5, 0.5 }   -- matches the |cff808080| muted note grey
Theme.SUBHEADER_GAP   = 10                  -- padding between a header's rule and its sub-text

-- ---------------------------------------------------------------------------
-- Texture helpers
-- ---------------------------------------------------------------------------
--- Does a texture atlas by this name exist on the current client?
--- @param name string Atlas name.
--- @return boolean
function Theme.AtlasExists(name)
  return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

--- Apply art to a texture, transparently handling atlas names (crisp at any size)
--- and file paths / fileIDs alike. File icons get a slight crop to hide their baked
--- border; atlas art is shown whole. Lets the quest "?" and friends swap to sharp
--- atlas art without every call site caring which kind it is.
--- @param tex table The Texture to paint.
--- @param art string|number Atlas name, texture path, or fileID.
--- @param crop boolean|nil Pass false to skip the file-icon border crop.
function Theme.ApplyIcon(tex, art, crop)
  if type(art) == "string" and not art:find("\\") and Theme.AtlasExists(art) then
    tex:SetTexCoord(0, 1, 0, 1); tex:SetAtlas(art)
  else
    tex:SetTexture(art)
    if crop == false then tex:SetTexCoord(0, 1, 0, 1) else tex:SetTexCoord(0.1, 0.9, 0.1, 0.9) end
  end
end

--- Inline-texture escape for fontstrings. Atlas names use |A| (crisp); file paths
--- use |T|. yOff nudges the glyph down onto the text baseline.
--- @param p string Atlas name or texture path.
--- @param sz number|nil Pixel size (default 14).
--- @param yoff number|nil Vertical baseline offset (default -3).
--- @return string escape The inline-texture escape sequence, trailing space included.
function Theme.InlineIcon(p, sz, yoff)
  sz = sz or 14; yoff = yoff or -3
  if type(p) == "string" and not p:find("\\") and Theme.AtlasExists(p) then
    return "|A:" .. p .. ":" .. sz .. ":" .. sz .. ":0:" .. yoff .. "|a "
  end
  return "|T" .. p .. ":" .. sz .. ":" .. sz .. ":0:" .. yoff .. "|t "
end

return Theme
