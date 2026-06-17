# Builds the Lua Language Server definition files from an in-game /btdump:
#   tools/luals/wow-api.lua      signatures (@param/@return) for documented APIs
#   tools/luals/wow-globals.lua  `any` stubs for EVERY global, so the thousands of
#                                FrameXML globals not in APIDocumentation (CreateFrame,
#                                font objects, GetAchievementInfo, ...) don't read as
#                                undefined. Existence-only; luacheck does strict field
#                                checking, so LuaLS's job here is signatures + editor IX.
#
#   1. In-game: /btdump then /reload
#   2. pwsh tools/gen-luals-defs.ps1
#   3. Open in VS Code (Lua extension) for live diagnostics, or: pwsh tools/lsp-check.ps1

param(
  [string]$WowRoot = "C:\Program Files (x86)\World of Warcraft\_retail_",
  [string]$SvFile
)
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not $SvFile) {
  $glob = Join-Path $WowRoot "WTF\Account\*\SavedVariables\BetterTogetherAPIDump.lua"
  $SvFile = Get-ChildItem -Path $glob -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $SvFile -or -not (Test-Path $SvFile)) {
  Write-Error "No BetterTogetherAPIDump.lua found. Run /btdump then /reload in-game first."
}
Write-Host "Reading $SvFile" -ForegroundColor Cyan
$text = Get-Content -Raw -LiteralPath $SvFile

function Get-SvString($key) {
  $mm = [regex]::Match($text, "\[`"$key`"\]\s*=\s*`"([^`"]*)`"")
  if (-not $mm.Success) { Write-Error "Could not find the '$key' field in the dump." }
  $v = $mm.Groups[1].Value
  $v = $v -replace '\\\\', "`0"; $v = $v -replace '\\n', "`n"; $v = $v -replace '\\t', "`t"; $v -replace "`0", '\'
}

$outDir = Join-Path $RepoRoot "tools\luals"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# --- 1. Signatures ---------------------------------------------------------
$emmy = Get-SvString "emmylua"
$apiOut = Join-Path $outDir "wow-api.lua"
Set-Content -LiteralPath $apiOut -Value $emmy -Encoding UTF8
$funcs = ([regex]::Matches($emmy, "(?m)^function ")).Count

# Names already defined by the signature file (documented namespaces + global funcs);
# don't redeclare these as `any` or we'd clobber their real types.
$defined = [System.Collections.Generic.HashSet[string]]::new()
foreach ($mm in [regex]::Matches($emmy, "(?m)^(\w+) = \{\}"))      { [void]$defined.Add($mm.Groups[1].Value) }
foreach ($mm in [regex]::Matches($emmy, "(?m)^function (\w+)\("))  { [void]$defined.Add($mm.Groups[1].Value) }

# --- 2. Existence stubs for every other top-level global -------------------
$globals = (Get-SvString "globals") -split "`n" | Where-Object { $_ -ne "" }
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("---@meta")
[void]$sb.AppendLine("-- AUTO-GENERATED existence stubs from /btdump. Top-level globals not covered by")
[void]$sb.AppendLine("-- APIDocumentation, declared as `any` so LuaLS knows they exist. Do not edit.")
$seen = [System.Collections.Generic.HashSet[string]]::new()
$count = 0
foreach ($id in $globals) {
  if ($id.Contains(".")) { continue }                       # top-level only
  if ($id -like "BetterTogether*" -or $id -like "SLASH_BTAPIDUMP*") { continue }
  if ($defined.Contains($id) -or -not $seen.Add($id)) { continue }
  [void]$sb.AppendLine("---@type any"); [void]$sb.AppendLine("$id = nil")
  $count++
}
$globOut = Join-Path $outDir "wow-globals.lua"
Set-Content -LiteralPath $globOut -Value $sb.ToString() -Encoding UTF8

Write-Host "Wrote $apiOut ($funcs documented functions)" -ForegroundColor Green
Write-Host "Wrote $globOut ($count existence stubs)" -ForegroundColor Green
