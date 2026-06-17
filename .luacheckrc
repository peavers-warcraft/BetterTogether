-- BetterTogether luacheck config. Thin wrapper over the shared Peavers base, which
-- supplies the lua51+wow standard, the project-wide ignore/exclude policy, and stds.wow
-- (the WoW global API: generated from /papidump when present, else a curated fallback).
-- See ../wow-api/config/luacheckrc.base.lua. Run: ../wow-api/scripts/lint.sh
--
-- Paths resolve from the addon directory (luacheck's CWD). Override the shared package
-- location with WOW_API_DIR when the layout differs (e.g. in CI).

local apiDir = (os and os.getenv and os.getenv("WOW_API_DIR")) or "../wow-api"
local base = assert(loadfile(apiDir .. "/config/luacheckrc.base.lua"))(apiDir)

std             = base.std
ignore          = base.ignore
exclude_files   = base.exclude
max_line_length = false
codestyle       = false
stds.wow        = base.wow

-- Globals this addon intentionally defines or mutates, on top of base.globals
-- (PeaversChangelogs, SlashCmdList — shared across all addons).
globals = base.globals
for _, g in ipairs({
  "BetterTogether",            -- public table (src/Core/Core.lua)
  "BetterTogetherDB",          -- SavedVariables
  "BetterTogetherCharDB",      -- SavedVariablesPerCharacter
  "SLASH_BETTERTOGETHER1",
  "SLASH_BETTERTOGETHER2",
  "StaticPopupDialogs",        -- we register StaticPopupDialogs["BETTERTOGETHER_INVITE"]
}) do globals[#globals + 1] = g end
