# Auto-deploy script for WoW addons (Windows)
# Derive the addon name from the .toc file so the folder name (which WoW must
# match exactly) is always correct, regardless of what the project dir is called.
$toc = Get-ChildItem -Path . -Filter *.toc | Select-Object -First 1
if (-not $toc) { Write-Host "[ERROR] No .toc file found" -ForegroundColor Red; exit 1 }
$ADDON_NAME = $toc.BaseName
$WOW_PATH = "C:\Program Files (x86)\World of Warcraft\_retail_"
$TARGET_PATH = "$WOW_PATH\Interface\AddOns\$ADDON_NAME"

Write-Host "Deploying $ADDON_NAME to $TARGET_PATH" -ForegroundColor Green

# Use robocopy for fast copying, exclude non-addon files
robocopy . $TARGET_PATH /MIR /XD .git .github .idea .claude /XF local_deploy.ps1 local_deploy.sh .gitignore .editorconfig .pkgmeta .peavers.yml DuoReady-Spec.md /NFL /NDL /NJH /NJS /nc /ns /np

Write-Host "[OK] Done!" -ForegroundColor Green
