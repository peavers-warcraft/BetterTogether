# Lints the addon's Lua against the WoW API defined in .luacheckrc.
#
#   pwsh tools/lint.ps1            # check src/ + Changelog.lua
#   pwsh tools/lint.ps1 src/UI     # check a subset
#
# luacheck is a single standalone binary (no Lua/LuaRocks/compiler needed). It is
# fetched once into tools/bin/ (git-ignored) and reused thereafter. Exit code is
# luacheck's own: 0 = clean, non-zero = warnings/errors found (handy for CI).

$ErrorActionPreference = "Stop"

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$Version    = "1.2.0"
$Exe        = Join-Path $PSScriptRoot "bin\luacheck.exe"
$DownloadUrl = "https://github.com/lunarmodules/luacheck/releases/download/v$Version/luacheck.exe"

if (-not (Test-Path $Exe)) {
  Write-Host "luacheck not found; downloading v$Version..." -ForegroundColor Yellow
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Exe) | Out-Null
  Invoke-WebRequest -Uri $DownloadUrl -OutFile $Exe
  Write-Host "Downloaded to $Exe" -ForegroundColor Green
}

# Default targets when none are passed on the command line.
$targets = if ($args.Count -gt 0) { $args } else { @("src", "Changelog.lua") }

Push-Location $RepoRoot
try {
  & $Exe @targets
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
