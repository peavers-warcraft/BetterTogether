-- AddonSentry end-to-end test probe. NOT referenced by the .toc, so it never loads in-game.
-- Safe to delete / close this PR. It intentionally calls an undefined global so AddonSentry
-- posts a Check Run annotation, proving the hosted analysis loop works on a real PR.
local function AddonSentryProbe()
    AddonSentryUndefinedGlobal()
end

return AddonSentryProbe
