--[[ Core/Util.lua
  Small, dependency-free helpers shared across modules. Currently the player-name /
  identity helpers that Comm and Pairing each used to reimplement. Loaded right
  after Core (and the locale table) so everything below can reach ns.Util.
]]

local addonName, ns = ...

local Util = {}
ns.Util = Util

-- Localize frequently-used globals for speed + clarity.
local UnitName = UnitName
local GetNormalizedRealmName = GetNormalizedRealmName

--- Strip the realm from a "Name-Realm" string, returning just the character name.
--- @param full string|nil A full or bare character name.
--- @return string|nil name The short name (passes nil straight through).
function Util.ShortName(full)
  return full and full:match("^[^-]+") or full
end

--- Normalize a (possibly bare) character name to a "Name-Realm" target. A bare name
--- gets our own normalized realm attached (covers same- and connected-realm
--- partners); a name that already carries a realm is returned unchanged.
--- @param name string|nil The name to normalize.
--- @return string|nil full The "Name-Realm" target (nil if `name` was nil/empty).
function Util.FullName(name)
  if not name or name == "" then return nil end
  if name:find("-") then return name end
  local realm = GetNormalizedRealmName and GetNormalizedRealmName()
  if realm and realm ~= "" then return name .. "-" .. realm end
  return name
end

--- This player's own "Name-Realm" target.
--- @return string full The player's full name (bare name if the realm is unavailable).
function Util.MyFullName()
  -- UnitName("player") is always present once the player is in world (the only time this
  -- is called), so FullName never hits its nil path here — hence the string return holds.
  ---@diagnostic disable-next-line: return-type-mismatch
  return Util.FullName(UnitName("player"))
end

--- Is `name` (short or full) this player?
--- @param name string|nil A character name to test.
--- @return boolean isSelf
function Util.IsSelf(name)
  return name ~= nil and Util.ShortName(name) == UnitName("player")
end

--- The bonded partner's short display name for weaving into user-facing strings, or
--- the supplied generic fallback when no partner is bonded. Keyed off the saved active
--- bond (not the transient ns.state.partnerName, which holds the "not paired" placeholder
--- when unlinked), so it stays right in offline/unpaired states. The result is a plain
--- string, so call sites feed it straight into string.format(L["… %s …"], …) and keep
--- translations working — pass the fallback that fits the surrounding grammar
--- ("your partner" mid-sentence, "Partner" as a standalone label).
--- @param fallback string|nil Word to use when no partner is bonded (defaults to "partner").
--- @return string
function Util.PartnerName(fallback)
  local bonded = ns.Pairing and ns.Pairing.PartnerName()
  return (bonded and Util.ShortName(bonded)) or fallback or "partner"
end

--- Truncate `s` to at most `n` characters, appending an ellipsis when shortened.
--- Byte-length based, which is fine for the short labels we put on the wire and
--- keeps every truncation in the addon (SNAP qname, CARD key/zone, quest titles)
--- consistent instead of re-implementing the same sub+ellipsis per call site.
--- @param s string|nil The text (nil becomes "").
--- @param n number Max length before truncation.
--- @return string
function Util.Truncate(s, n)
  s = s or ""
  if #s > n then return s:sub(1, n - 1) .. "…" end
  return s
end

return Util
