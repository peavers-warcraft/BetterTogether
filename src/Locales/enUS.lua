--[[ Locales/enUS.lua
  Localization table (ns.L), loaded before every consumer.

  DuoReady uses the gettext-style "English-as-key" convention: call sites read
  L["Some English text"] and the default (enUS) locale returns the key verbatim.
  This keeps the source readable and means a missing translation can never render
  a blank or raise an error — it simply falls back to the English source string.

  To translate, copy this file (e.g. to deDE.lua), add the file to the .toc under
  a matching `if GetLocale() == "deDE"` guard, and fill in values:
      L["Ready"] = "Bereit"
  Only the strings a locale overrides need listing; everything else falls back.
]]

local addonName, ns = ...

-- Identity fallback: an unset key returns itself (the English source string).
local L = setmetatable({}, { __index = function(_, k) return k end })
ns.L = L

-- enUS is the source language, so no overrides are required here. Translators add
-- their own locale files that set L["<English source>"] = "<translation>".

return L
