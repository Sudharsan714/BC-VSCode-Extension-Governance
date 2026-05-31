
[CmdletBinding()]
param(
    [string]$ApprovedListPath = (Join-Path $PSScriptRoot "approved-extensions.json"),
    [Parameter(Mandatory)] [string]$Organization,
    [Parameter(Mandatory)] [string]$Project,
    [string]$Feed = "approved-vscode-extensions",
    [switch]$SkipAutoResolve
)
 
Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"
 
function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK([string]$msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "    [FAIL] $msg" -ForegroundColor Red }
 
function Get-MarketplaceLatestVersion {
    param([string]$ExtensionId)
    $body = @{
        filters = @(@{ criteria = @(@{ filterType = 7; value = $ExtensionId }) })
        flags = 512
    } | ConvertTo-Json -Depth 6 -Compress
    try {
        $response = Invoke-RestMethod `
            -Uri         "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery" `
            -Method      POST `
            -Body        $body `
            -ContentType "application/json" `
            -Headers     @{ Accept = "application/json;api-version=3.0-preview.1" } `
            -TimeoutSec  30
        $version = $response.results[0].extensions[0].versions[0].version
        if ([string]::IsNullOrWhiteSpace($version)) { return $null }
        return $version
    }
    catch {
        Write-Warn "Marketplace API call failed for '$ExtensionId': $_"
        return $null
    }
}
 
function Get-VsixUrl {
    param([string]$ExtensionId, [string]$Version)
    $dotIndex  = $ExtensionId.IndexOf('.')
    $publisher = $ExtensionId.Substring(0, $dotIndex)
    $extName   = $ExtensionId.Substring($dotIndex + 1)
    return "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/$publisher/vsextensions/$extName/$Version/vspackage"
}
 
function Get-SafeName {
    param([string]$Name)
    # Azure Artifacts Universal Package names must be lowercase alphanumeric
    # with only dash, dot or underscore as separators.
    # Convert dots to dashes and lowercase the whole string.
    return $Name.ToLower().Replace(".", "-")
}
 
function Get-SafeDescription {
    param([string]$Description, [string]$Fallback)
    # Remove any character outside the printable ASCII range (32-126).
    # This prevents artifacttool exit code 20 caused by em-dashes, smart quotes etc.
    $safe = ""
    foreach ($ch in $Description.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -ge 32 -and $code -le 126) {
            $safe += $ch
        }
    }
    $safe = $safe.Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) { return $Fallback }
    return $safe
}
 
# --- Load approved list ---
Write-Step "Loading approved extensions list"
if (-not (Test-Path $ApprovedListPath)) {
    Write-Fail "Approved list not found at: $ApprovedListPath"
    exit 1
}
 
$data    = Get-Content $ApprovedListPath -Raw | ConvertFrom-Json
$allExts = $data.extensions | Where-Object { $_.PSObject.Properties.Name -contains "name" }
 
$toAutoResolve = @($allExts | Where-Object { $_.needsVersionReview -eq $true })
$confirmed     = @($allExts | Where-Object { $_.needsVersionReview -ne $true })
 
Write-OK "Total extensions in list   : $($allExts.Count)"
Write-OK "Version confirmed in JSON  : $($confirmed.Count)"
Write-OK "Version to auto-resolve    : $($toAutoResolve.Count)"
 
# --- Resolve versions ---
$resolvedExts = [System.Collections.Generic.List[object]]::new()
foreach ($ext in $confirmed) { $resolvedExts.Add($ext) }
 
if ($toAutoResolve.Count -gt 0) {
    if ($SkipAutoResolve) {
        Write-Warn "-SkipAutoResolve set. $($toAutoResolve.Count) extension(s) will be skipped."
    } else {
        Write-Step "Auto-resolving latest versions from VS Marketplace"
        foreach ($ext in $toAutoResolve) {
            Write-Host "    Querying: $($ext.name)" -ForegroundColor Gray
            $latest = Get-MarketplaceLatestVersion -ExtensionId $ext.name
            if ($null -eq $latest) {
                Write-Warn "Could not resolve version for '$($ext.name)' - skipping."
                continue
            }
            $patched         = $ext | Select-Object *
            $patched.version = $latest
            $patched.vsixUrl = Get-VsixUrl -ExtensionId $ext.name -Version $latest
            Write-OK "$($ext.name)  ->  $latest"
            $resolvedExts.Add($patched)
        }
    }
}
 
if ($resolvedExts.Count -eq 0) {
    Write-Warn "Nothing to publish."
    exit 0
}
 
Write-Host ""
Write-OK "Extensions ready to publish: $($resolvedExts.Count)"
 
# --- Pre-flight ---
Write-Step "Pre-flight checks"
 
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Fail "Azure CLI not found. Install from https://aka.ms/installazurecliwindows"
    exit 1
}
Write-OK "Azure CLI found"
 
Write-Host "    Ensuring azure-devops CLI extension is installed..." -ForegroundColor Gray
az extension add    --name azure-devops --only-show-errors 2>$null
az extension update --name azure-devops --only-show-errors 2>$null
Write-OK "azure-devops CLI extension ready"
 
az devops configure --defaults organization=$Organization
 
$runningInPipeline = $env:TF_BUILD -eq "True"
if ($runningInPipeline) {
    if (-not $env:AZURE_DEVOPS_EXT_PAT) {
        Write-Fail "AZURE_DEVOPS_EXT_PAT is not set."
        exit 1
    }
    Write-OK "Running in Azure DevOps pipeline - using System.AccessToken for auth"
} else {
    $loginState = az account show --query "user.name" -o tsv 2>$null
    if (-not $loginState) {
        Write-Host "    Not logged in. Launching az login..." -ForegroundColor Yellow
        az login --allow-no-subscriptions | Out-Null
    }
    Write-OK "Logged in as: $(az account show --query 'user.name' -o tsv)"
}
 
# --- Publish loop ---
$results = @()
 
foreach ($ext in $resolvedExts) {
    $name     = $ext.name
    $version  = $ext.version
    $url      = $ext.vsixUrl
    $safeName = Get-SafeName -Name $name
    $safeDesc = Get-SafeDescription -Description $ext.description -Fallback $safeName
 
    Write-Step "Processing: $name  v$version"
 
    $tempDir  = Join-Path $env:TEMP "vsix-bulk-$(Get-Random)"
    $vsixFile = Join-Path $tempDir "$safeName-$version.vsix"
    New-Item -ItemType Directory -Path $tempDir | Out-Null
 
    try {
        Write-Host "    Downloading from VS Marketplace..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $url -OutFile $vsixFile -UseBasicParsing
        $sizeMB = [math]::Round((Get-Item $vsixFile).Length / 1MB, 2)
        Write-OK "Downloaded ($sizeMB MB)"
 
        # Validate safeDesc is not empty before passing to az
        if ([string]::IsNullOrWhiteSpace($safeDesc)) {
            $safeDesc = $safeName
        }
 
        Write-Host "    Publishing as: $safeName  desc: $safeDesc" -ForegroundColor Gray
 
        $ErrorActionPreference = "Continue"
        $publishOutput = az artifacts universal publish `
            --organization $Organization `
            --project      $Project `
            --scope        project `
            --feed         $Feed `
            --name         $safeName `
            --version      $version `
            --path         $tempDir `
            --description  $safeDesc 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = "Continue"
 
        $publishStr = ($publishOutput | Out-String).Trim()
        Write-Host "    [DEBUG] az exit code: $exitCode" -ForegroundColor Gray
        if ($publishStr) {
            Write-Host "    [DEBUG] az output: $publishStr" -ForegroundColor Gray
        }
 
        if ($exitCode -eq 0) {
            Write-OK "Published to feed as: $safeName"
            $results += [PSCustomObject]@{ Name=$name; FeedName=$safeName; Version=$version; Status="Published" }
        } elseif ($publishStr -match "already exists" -or $publishStr -match "conflict" -or $publishStr -match "409") {
            Write-Warn "Already in feed - skipping (v$version)"
            $results += [PSCustomObject]@{ Name=$name; FeedName=$safeName; Version=$version; Status="Skipped (already exists)" }
        } else {
            Write-Fail "Publish failed (exit $exitCode): $publishStr"
            $results += [PSCustomObject]@{ Name=$name; FeedName=$safeName; Version=$version; Status="Failed" }
        }
    }
    catch {
        Write-Fail "Exception: $_"
        $results += [PSCustomObject]@{ Name=$name; FeedName=$safeName; Version=$version; Status="Failed" }
    }
    finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
 
# --- Summary ---
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  Bulk Publish Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
$results | Format-Table -AutoSize
 
$failCount = @($results | Where-Object { $_.Status -eq "Failed" }).Count
if ($failCount -gt 0) {
    Write-Host ""
    Write-Host "  [WARN] $failCount extension(s) failed - see summary above." -ForegroundColor Yellow
    Write-Host "  Re-run the pipeline to retry." -ForegroundColor Yellow
}
exit 0