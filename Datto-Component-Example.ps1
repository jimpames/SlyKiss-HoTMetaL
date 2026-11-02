# Datto RMM Component - CLI-Browser
# Paste this into a Datto RMM PowerShell component
# or run the CLI-Browser.ps1 directly

$ErrorActionPreference = "Continue"

Write-Host "=== Deploying CLI-Browser ===" -ForegroundColor Cyan

$dest = "$env:USERPROFILE\CLI-Browser"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# If the script is embedded or already present, copy it
$scriptPath = Join-Path $dest "CLI-Browser.ps1"

# For a real component you would embed the script content or download it.
# Here we assume CLI-Browser.ps1 is in the same folder or you paste it.
if (Test-Path ".\CLI-Browser.ps1") {
    Copy-Item ".\CLI-Browser.ps1" $scriptPath -Force
    Write-Host "Copied CLI-Browser.ps1 to $dest"
} else {
    Write-Host "Place CLI-Browser.ps1 next to this script or embed it." -ForegroundColor Yellow
}

Write-Host "Launching browser..." -ForegroundColor Green
& $scriptPath -StartUrl "about:blank"

Write-Host "Done."
