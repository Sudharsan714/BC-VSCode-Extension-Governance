# ============================================================
# Set-ExtensionFolderLock.ps1
# One-time setup script — run as Administrator on each developer machine
# AFTER Install-ApprovedExtension.ps1 has completed the initial install.
#
# What it does:
#   - Removes inherited permissions from the VS Code extensions folder
#   - Grants SYSTEM full control  (VS Code internal operations)
#   - Grants the current user Read + Execute only
#   - Blocks  code --install-extension file.vsix  sideloading
#
# After this runs, Install-ApprovedExtension.ps1 handles unlock/relock
# automatically on every future update run — no manual steps needed.
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# AUTO-DETECT VS Code extensions folder
# Priority order:
#   1. User profile folder  -- %USERPROFILE%\.vscode\extensions  (most common)
#   2. User install folder  -- %LOCALAPPDATA%\Programs\Microsoft VS Code\extensions
#   3. System install       -- C:\Program Files\Microsoft VS Code\extensions
#   4. Fallback via PATH    -- resolve from code.cmd location
# ---------------------------------------------------------------------------
function Get-VSCodeExtensionsPath {
    $candidates = @(
        "$env:USERPROFILE\.vscode\extensions",
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\extensions",
        "$env:ProgramFiles\Microsoft VS Code\extensions",
        "${env:ProgramFiles(x86)}\Microsoft VS Code\extensions"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    $codeCmd = Get-Command code -ErrorAction SilentlyContinue
    if ($codeCmd) {
        $installRoot = Split-Path (Split-Path $codeCmd.Source -Parent) -Parent
        $derived = Join-Path $installRoot "extensions"
        if (Test-Path $derived) { return $derived }
    }
    return $null
}

$extensionsPath = Get-VSCodeExtensionsPath

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  VS Code Extension Folder Lock" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# Verify VS Code extensions folder exists
if ([string]::IsNullOrWhiteSpace($extensionsPath) -or -not (Test-Path $extensionsPath)) {
    Write-Host ""
    Write-Host "  [FAIL] VS Code extensions folder could not be located." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Searched:" -ForegroundColor Yellow
    Write-Host "    $env:USERPROFILE\.vscode\extensions" -ForegroundColor Yellow
    Write-Host "    $env:LOCALAPPDATA\Programs\Microsoft VS Code\extensions" -ForegroundColor Yellow
    Write-Host "    C:\Program Files\Microsoft VS Code\extensions" -ForegroundColor Yellow
    Write-Host "    PATH-derived location via 'code' executable" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Make sure VS Code is installed and at least one extension exists." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "  Target : $extensionsPath" -ForegroundColor Gray
Write-Host "  User   : $env:USERNAME" -ForegroundColor Gray
Write-Host ""

# Check if already locked
$testFile = Join-Path $extensionsPath ".write-test-$(New-Guid)"
$alreadyLocked = $false
try {
    [System.IO.File]::WriteAllText($testFile, "test")
    Remove-Item $testFile -Force -ErrorAction SilentlyContinue
}
catch {
    $alreadyLocked = $true
}

if ($alreadyLocked) {
    Write-Host "  [OK] Folder is already write-locked. No changes needed." -ForegroundColor Green
    Write-Host ""
    exit 0
}

# Apply the lock
Write-Host "  Applying icacls permissions..." -ForegroundColor Gray

# Step 1 — Remove inherited permissions
icacls $extensionsPath /inheritance:r | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [FAIL] Could not remove inherited permissions. Run as Administrator." -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] Inherited permissions removed" -ForegroundColor Green

# Step 2 — Grant SYSTEM full control
icacls $extensionsPath /grant:r "SYSTEM:(OI)(CI)(F)" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [FAIL] Could not grant SYSTEM full control." -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] SYSTEM: Full control granted" -ForegroundColor Green

# Step 3 — Grant current user Read + Execute only (no write)
icacls $extensionsPath /grant:r "${env:USERNAME}:(OI)(CI)(RX)" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [FAIL] Could not set user permissions." -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] ${env:USERNAME}: Read + Execute only (write blocked)" -ForegroundColor Green

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Lock applied successfully" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Raw .vsix sideloading is now blocked." -ForegroundColor Gray
Write-Host "  Install-ApprovedExtension.ps1 handles unlock/relock" -ForegroundColor Gray
Write-Host "  automatically on all future update runs." -ForegroundColor Gray
Write-Host ""