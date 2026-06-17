-- Luacheck config for BetterTogether (a World of Warcraft addon).
-- Run with: pwsh tools/lint.ps1   (or: tools/bin/luacheck.exe src)
--
-- WoW runs Lua 5.1, so we lint against that grammar/std and layer a "wow" std on top
-- declaring the game's global API. If luacheck reports an undefined global that is a
-- real WoW API, add it to stds.wow.read_globals below rather than silencing 113.

std = "lua51+wow"
max_line_length = false          -- this codebase favours dense, long lines
codestyle = false

exclude_files = {
  "tools/",
  ".release/",
  "**/Libs/**",
  "**/libs/**",
}

-- Warnings we accept project-wide. We deliberately KEEP 113 (undefined global) and
-- 143 (undefined field) on — those catch API typos, which is the whole point.
ignore = {
  "212",            -- unused argument (WoW event/callback signatures often ignore args)
  "213",            -- unused loop variable
  "542",            -- empty if branch (used as intentional no-op placeholders)
  "211/addonName",  -- `local addonName, ns = ...` header idiom; addonName rarely used
}

-- Globals this addon intentionally defines or mutates.
globals = {
  "BetterTogether",            -- public table (src/Core/Core.lua)
  "BetterTogetherDB",          -- SavedVariables
  "BetterTogetherCharDB",      -- SavedVariablesPerCharacter
  "SLASH_BETTERTOGETHER1",
  "SLASH_BETTERTOGETHER2",
  "SlashCmdList",              -- we assign SlashCmdList["BETTERTOGETHER"]
  "StaticPopupDialogs",        -- we register StaticPopupDialogs["BETTERTOGETHER_INVITE"]
  "PeaversChangelogs",         -- shared cross-addon changelog registry (Changelog.lua)
}

-- ---------------------------------------------------------------------------
-- The WoW global API. Two sources, in priority order:
--   1. tools/wow-globals.lua — version-accurate, generated from an in-game /btdump
--      (see tools/gen-wow-api.ps1). Used automatically when present.
--   2. The curated fallback below — hand-maintained; covers what the addon uses today
--      so linting works before anyone runs a dump. Extend as the addon reaches for
--      new calls (or just regenerate from the game).
-- ---------------------------------------------------------------------------
local curated = {
  read_globals = {
    -- Lua-ish helpers WoW exposes as bare globals (on top of the 5.1 std lib)
    "wipe", "tinsert", "tremove", "tContains", "unpack",
    "strsplit", "strjoin", "strtrim", "strmatch", "strfind", "strrep",
    "strlower", "strupper", "strconcat", "gsub", "format",
    "max", "min", "abs", "floor", "ceil", "mod", "date", "time",
    "geterrorhandler", "securecall", "issecure", "issecurevariable",
    "issecretvalue",   -- Midnight secret-values guard (src/Core/Consumables.lua)

    -- Extend std library tables with WoW additions (merged with lua51 fields)
    string = { fields = { "split", "join", "trim" } },
    table  = { fields = { "wipe", "removemulti" } },
    math   = { fields = { "huge" } },
    bit    = { fields = { "band", "bor", "bxor", "bnot", "lshift", "rshift", "arshift", "tobit", "tohex" } },

    -- Time / numbers / enums
    "GetTime", "GetTimePreciseSec", "debugprofilestop", "BreakUpLargeNumbers",
    "Enum", "C_Texture",

    -- Core frame / UI
    "CreateFrame", "UIParent", "WorldFrame", "GameTooltip", "GameTooltip_Hide",
    "UISpecialFrames", "UIFrameFadeIn", "UIFrameFadeOut", "CreateColor",
    "CreateColorFromHexString", "Mixin", "CreateFromMixins", "hooksecurefunc",
    "GetCursorPosition", "GetPhysicalScreenSize", "InCombatLockdown",
    "C_Timer", "PlaySound", "PlaySoundFile", "SOUNDKIT",

    -- Name autocomplete (src/UI/Pages/Partners.lua)
    "C_AutoComplete", "GetAutoCompleteResults", "AUTOCOMPLETE_FLAG_ALL",
    "AutoCompleteEditBox_SetAutoCompleteSource", "AutoCompleteEditBox_OnTextChanged",
    "AutoCompleteEditBox_OnChar", "AutoCompleteEditBox_OnKeyDown",
    "AutoCompleteEditBox_OnKeyUp", "AutoCompleteEditBox_OnEditFocusLost",
    "AutoCompleteEditBox_OnTabPressed", "AutoCompleteEditBox_OnEnterPressed",
    "AutoCompleteEditBox_OnEscapePressed",
    "GameFontNormal", "GameFontNormalLarge", "GameFontHighlight",
    "GameFontHighlightSmall", "GameFontDisable", "GameFontDisableSmall",
    "NumberFontNormal", "InterfaceOptions_AddCategory",
    "InterfaceOptionsFrame_OpenToCategory", "Settings", "SettingsPanel",

    -- Units / group
    "UnitName", "UnitExists", "UnitClass", "UnitLevel", "UnitGUID", "UnitIsUnit",
    "UnitFullName", "UnitInParty", "UnitInRaid", "UnitIsConnected", "UnitIsPlayer",
    "UnitHealth", "UnitHealthMax", "UnitPower", "UnitPowerMax", "UnitAffectingCombat",
    "IsInRaid", "IsInGroup", "IsInInstance", "GetNumGroupMembers", "GetNumSubgroupMembers",
    "GetRealmName", "GetNormalizedRealmName", "UnitGroupRolesAssigned",
    "GetSpecialization", "GetSpecializationInfo", "GetSpecializationInfoByID",

    -- Class / colour
    "RAID_CLASS_COLORS", "CLASS_ICON_TCOORDS", "LOCALIZED_CLASS_NAMES_MALE",
    "LOCALIZED_CLASS_NAMES_FEMALE", "GetClassInfo", "C_ClassColor",

    -- Items / inventory / container
    "GetItemInfo", "GetItemInfoInstant", "GetItemIcon", "GetItemCount",
    "GetInventoryItemLink", "GetInventoryItemDurability", "GetInventoryItemTexture",
    "GetInventorySlotInfo", "C_Item", "C_Container", "C_TooltipInfo", "C_CurrencyInfo",
    "GetMoney", "GetCoinTextureString", "GetItemStats", "GetAverageItemLevel",
    "GetWeaponEnchantInfo", "ITEM_QUALITY_COLORS", "TooltipUtil", "C_TradeSkillUI",
    "BACKPACK_CONTAINER", "NUM_BAG_SLOTS", "NUM_TOTAL_EQUIPPED_BAG_SLOTS",
    "INVSLOT_FIRST_EQUIPPED", "INVSLOT_LAST_EQUIPPED",

    -- Auras / spells
    "AuraUtil", "C_UnitAuras", "C_Spell", "GetSpellInfo", "C_SpellBook",

    -- Quests
    "C_QuestLog", "C_SuperTrack", "GetQuestLink", "GetSuperTrackedQuestID",
    "C_TaskQuest", "C_QuestInfoSystem",

    -- Achievements / stats
    "GetAchievementInfo", "GetCategoryInfo", "GetStatistic", "GetComparisonStatistic",
    "C_AchievementInfo", "GetAchievementNumCriteria", "GetAchievementCriteriaInfo",
    "GetCategoryList", "GetCategoryNumAchievements", "C_DateAndTime",

    -- Map / location
    "C_Map", "GetRealZoneText", "GetSubZoneText", "GetMinimapZoneText", "IsResting",
    "GetZoneText",

    -- Mythic+ / vault
    "C_MythicPlus", "C_ChallengeMode", "C_WeeklyRewards", "C_PlayerInfo",

    -- Comm / addon
    "C_ChatInfo", "C_AddOns", "C_CVar", "GetAddOnMetadata", "RegisterAddonMessagePrefix",
    "SendAddonMessage", "Ambiguate",

    -- Misc globals occasionally referenced
    "_G", "PlumberDB", "Plumber", "date", "GetBuildInfo", "GetServerTime",
    "BackdropTemplateMixin", "CombatLogGetCurrentEventInfo", "StaticPopup_Show",

    -- Common localized UI strings exposed as globals
    "ACCEPT", "DECLINE", "OKAY", "CANCEL", "CLOSE", "YES", "NO",
  },
}

-- Use the generated, version-accurate std if it exists; otherwise the curated one.
-- Guarded so a missing file / sandboxed loadfile silently keeps the fallback working.
local generated
do
  local f = loadfile and loadfile("tools/wow-globals.lua")
  if f then
    local ok, res = pcall(f)
    if ok and type(res) == "table" then generated = res end
  end
end
stds.wow = generated or curated

-- Dumper blind-spots: real APIs that /btdump can't enumerate, so they're force-added on
-- top of whichever std won. Either not present in _G when the dump runs
-- (CombatLogGetCurrentEventInfo), or exposed through a metatable so pairs() sees no
-- fields (TooltipUtil's mixin methods → make it lenient instead of a strict field set).
do
  local rg = stds.wow.read_globals
  rg[#rg + 1] = "CombatLogGetCurrentEventInfo"
  rg.TooltipUtil = nil            -- drop the (field-less) strict entry from the dump
  rg[#rg + 1] = "TooltipUtil"     -- re-add as a plain global: any field allowed
end
