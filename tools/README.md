# tools/ — local static analysis

Two layers of confidence without launching the game:

| Layer | Checks | Tool | Run |
|---|---|---|---|
| **Existence** | syntax errors, undefined globals, typos in `C_*`/`Enum` fields | luacheck | `pwsh tools/lint.ps1` |
| **Signatures** | argument/return types of documented APIs | Lua Language Server | `pwsh tools/lsp-check.ps1` (or live in VS Code) |

Both are pinned to the **real client API**, dumped from in-game so they match the exact
build (Midnight 12.x) rather than a hand-maintained guess.

Binaries (`tools/bin/`) and generated API files (`tools/wow-globals.lua`, `tools/luals/`)
are git-ignored and fetched/generated on demand. Nothing here ships in the addon
(`local_deploy.ps1` excludes `tools/`, `.luacheckrc`, `.luarc.json`).

## Everyday use

```pwsh
pwsh tools/lint.ps1            # fast; run after every Lua edit
pwsh tools/lint.ps1 src/UI     # a subset
```

luacheck works immediately via the curated WoW list in `.luacheckrc`. Refresh it from
the live client whenever you want exact coverage (see below).

## Refreshing the API from the game

1. At the character-select **AddOns** screen, enable **"BetterTogether API Dump"**
   (installed alongside the addon). Ideally disable other addons so their globals don't
   leak into the dump.
2. In-game: `/btdump`, then `/reload` (WoW only flushes SavedVariables on reload/logout).
3. Back here:
   ```pwsh
   pwsh tools/gen-wow-api.ps1     # -> tools/wow-globals.lua  (luacheck std)
   pwsh tools/gen-luals-defs.ps1  # -> tools/luals/wow-api.lua (LuaLS defs)
   ```
   `.luacheckrc` auto-prefers `tools/wow-globals.lua` when present (deleting it falls
   back to the curated list). The dumper source lives in `tools/apidump/`.

## Limitations

- luacheck validates **existence**, not call correctness. It's the everyday gate.
- LuaLS adds **signatures**, but Blizzard's `APIDocumentation` only covers ~6k `C_*`/system
  functions — not the thousands of FrameXML globals (`CreateFrame`, font objects,
  `GetAchievementInfo`, …). `gen-luals-defs.ps1` works around this by also emitting
  `tools/luals/wow-globals.lua` (`any` stubs for every global from the dump) so those don't
  read as undefined. Two diagnostics are disabled in `.luarc.json` because the docs mark
  optional args as required (`missing-parameter`, `redundant-parameter` → false positives),
  and `undefined-field` is left to luacheck. Result: LuaLS is clean at **Warning** level and
  most useful **live in VS Code** (hovers, autocomplete, signature help). Cross-file `ns`
  field typing is still limited.
- `CombatLogGetCurrentEventInfo` isn't in `_G` at dump time, so it's whitelisted by hand in
  both `.luacheckrc` (overrides) and `.luarc.json` (`diagnostics.globals`).
