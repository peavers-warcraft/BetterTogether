# Headless Lua Language Server diagnostics (signature/type checking against the WoW API
# defs in tools/luals/). Downloads lua-language-server on first run, like tools/lint.ps1.
#
#   pwsh tools/lsp-check.ps1            # check src/ at Warning level
#   pwsh tools/lsp-check.ps1 src/UI Hint
#
# Requires tools/luals/wow-api.lua first (pwsh tools/gen-luals-defs.ps1 after an in-game
# /btdump) — without it LuaLS treats every WoW global as undefined. LuaLS is happiest
# live in an editor; this CLI form is for spot checks / CI and can be noisy on untyped code.

param(
  # LuaLS --check makes the checked path the workspace ROOT, so we point it at the repo
  # root (where .luarc.json + the relative tools/luals library resolve) and rely on
  # workspace.ignoreDir to limit scope. Override only if you know what you're doing.
  [string]$Target = ".",
  [string]$Level = "Warning",   # Error | Warning | Information | Hint
  [string]$Version              # pin a LuaLS version; default = latest release
)
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $PSScriptRoot "bin\lua-language-server"
$exe = Join-Path $dir "bin\lua-language-server.exe"

if (-not (Test-Path $exe)) {
  if (-not $Version) {
    $rel = Invoke-RestMethod "https://api.github.com/repos/LuaLS/lua-language-server/releases/latest" -Headers @{ "User-Agent" = "bt-lint" }
    $Version = $rel.tag_name
    $url = ($rel.assets | Where-Object { $_.name -match "win32-x64\.zip$" } | Select-Object -First 1).browser_download_url
  } else {
    $url = "https://github.com/LuaLS/lua-language-server/releases/download/$Version/lua-language-server-$Version-win32-x64.zip"
  }
  if (-not $url) { Write-Error "Could not resolve a win32-x64 LuaLS download URL." }
  Write-Host "Downloading lua-language-server $Version..." -ForegroundColor Yellow
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $zip = Join-Path $env:TEMP "luals.zip"
  Invoke-WebRequest -Uri $url -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $dir -Force
  Remove-Item $zip
  Write-Host "Installed to $dir" -ForegroundColor Green
}

if (-not (Test-Path (Join-Path $RepoRoot "tools\luals\wow-api.lua"))) {
  Write-Host "WARNING: tools/luals/wow-api.lua missing — run /btdump + tools/gen-luals-defs.ps1 first, or expect WoW APIs to read as undefined." -ForegroundColor Yellow
}

$log = Join-Path $dir "log"
$checkPath = Join-Path $RepoRoot $Target
# This LuaLS build prints diagnostics to stdout (exit 1 when any are found). Capture the
# full report to a file and show a grouped summary so the console isn't flooded.
$report = Join-Path $PSScriptRoot "luals-report.txt"
# LuaLS prints diagnostics to stdout wrapped in ANSI colour codes; strip them so the
# report is greppable, then summarise by diagnostic code.
$raw = & $exe --check $checkPath --checklevel=$Level --logpath=$log --configpath=(Join-Path $RepoRoot ".luarc.json") 2>&1
$clean = $raw | ForEach-Object { [regex]::Replace([string]$_, "\x1B\[[0-9;]*m", "") }
$clean | Set-Content -LiteralPath $report

$summary = ($clean | Select-String 'Diagnosis complete' | Select-Object -Last 1).Line
$diag = $clean | Select-String -Pattern '\[(Error|Warning|Information|Hint)\]\s+.*\((\S+)\)\s*$'
if (-not $diag) { Write-Host "No diagnostics at level $Level. $summary" -ForegroundColor Green; exit 0 }

Write-Host ("{0}  (full report: {1})" -f ($summary ? $summary.Trim() : "$($diag.Count) diagnostics"), $report) -ForegroundColor Yellow
Write-Host "`n-- by code --"
$diag | ForEach-Object { $_.Matches[0].Groups[2].Value } | Group-Object | Sort-Object Count -Descending |
  ForEach-Object { "{0,5}  {1}" -f $_.Count, $_.Name }
exit 1
