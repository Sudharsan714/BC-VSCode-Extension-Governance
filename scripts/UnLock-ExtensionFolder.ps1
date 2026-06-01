# ============================================================
# undo-ExtensionFolderLock.ps1
# Rollback script for Set-ExtensionFolderLock.ps1
#
# What it does:
#   - Detects the VS Code extensions folder
#   - Auto-relaunches with Administrator permission if needed
#   - Re-enables inherited permissions
#   - Restores Modify permission for the current user
#   - Allows normal VS Code Marketplace / VSIX extension installation again
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-OK([string]$msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-VSCodeExtensionsPath {
    $candidates = @(
        "$env:USERPROFILE\.vscode\extensions",
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\extensions",
        "$env:ProgramFiles\Microsoft VS Code\extensions",
        "${env:ProgramFiles(x86)}\Microsoft VS Code\extensions"
    )

    foreach ($path in $candidates) {
        if (Test-Path $path) {
            return $path
        }
    }

    $codeCmd = Get-Command code -ErrorAction SilentlyContinue
    if ($codeCmd) {
        $installRoot = Split-Path (Split-Path $codeCmd.Source -Parent) -Parent
        $derived = Join-Path $installRoot "extensions"

        if (Test-Path $derived) {
            return $derived
        }
    }

    return $null
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  VS Code Extension Folder Lock Rollback" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

if (-not (Test-IsAdministrator)) {
    Write-Warn "Administrator permission is required to restore folder permissions."
    Write-Warn "Relaunching with elevation..."

    $hostExe = (Get-Process -Id $PID).Path

    if ([string]::IsNullOrWhiteSpace($hostExe) -or -not (Test-Path $hostExe)) {
        $hostExe = "powershell.exe"
    }

    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""

    try {
        Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $args
        Write-Host ""
        Write-Host "  A new Administrator PowerShell window should open." -ForegroundColor Yellow
        Write-Host "  Continue in that elevated window." -ForegroundColor Yellow
        exit 0
    }
    catch {
        Write-Fail "Could not relaunch as Administrator."
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Open PowerShell as Administrator manually and rerun:" -ForegroundColor Yellow
        Write-Host "  .\undo-ExtensionFolderLock.ps1" -ForegroundColor Yellow
        exit 1
    }
}

$extensionsPath = Get-VSCodeExtensionsPath

if ([string]::IsNullOrWhiteSpace($extensionsPath) -or -not (Test-Path $extensionsPath)) {
    Write-Host ""
    Write-Fail "VS Code extensions folder could not be located."
    Write-Host ""
    Write-Host "  Searched:" -ForegroundColor Yellow
    Write-Host "    $env:USERPROFILE\.vscode\extensions" -ForegroundColor Yellow
    Write-Host "    $env:LOCALAPPDATA\Programs\Microsoft VS Code\extensions" -ForegroundColor Yellow
    Write-Host "    C:\Program Files\Microsoft VS Code\extensions" -ForegroundColor Yellow
    Write-Host "    PATH-derived location via 'code' executable" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "  Target : $extensionsPath" -ForegroundColor Gray
Write-Host "  User   : $env:USERNAME" -ForegroundColor Gray
Write-Host ""

Write-Host "  Restoring permissions..." -ForegroundColor Gray

# Step 1 — Re-enable inheritance
icacls $extensionsPath /inheritance:e | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Could not re-enable inherited permissions."
    exit 1
}
Write-OK "Inherited permissions enabled"

# Step 2 — Restore current user Modify permission
icacls $extensionsPath /grant:r "${env:USERNAME}:(OI)(CI)(M)" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Could not restore user Modify permission."
    exit 1
}
Write-OK "${env:USERNAME}: Modify permission restored"

# Step 3 — Keep SYSTEM full control
icacls $extensionsPath /grant:r "SYSTEM:(OI)(CI)(F)" | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-OK "SYSTEM: Full control confirmed"
}
else {
    Write-Warn "Could not explicitly grant SYSTEM full control. Inheritance may already cover it."
}

# Step 4 — Optional cleanup: remove explicit Read+Execute-only rule by replacing it with Modify above.
# /grant:r already replaces the explicit permission for this user.

# Step 5 — Verify write access
$testFile = Join-Path $extensionsPath ".rollback-write-test-$(New-Guid)"
try {
    [System.IO.File]::WriteAllText($testFile, "test")
    Remove-Item $testFile -Force -ErrorAction SilentlyContinue
    Write-OK "Write access verified"
}
catch {
    Write-Warn "Permissions were updated, but write test failed."
    Write-Warn "Close VS Code and run this script again."
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Rollback completed successfully" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  VS Code Marketplace install and raw VSIX sideloading are now allowed again." -ForegroundColor Gray
Write-Host ""
