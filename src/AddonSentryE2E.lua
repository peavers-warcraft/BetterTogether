-- AddonSentry end-to-end validation — deliberate finding. DO NOT MERGE.
-- Calls a typo'd WoW global so the App reports one 'undefined global' finding
-- we can watch it auto-fix (GetFramrate -> GetFramerate).
local fps = GetFramerate()
return fps
