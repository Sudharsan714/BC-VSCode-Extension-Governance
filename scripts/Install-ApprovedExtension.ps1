[CmdletBinding(DefaultParameterSetName = "Single")]
param(
    [Parameter(ParameterSetName = "Single")]
    [string]$ExtensionName,

    [Parameter(ParameterSetName = "Single")]
    [string]$Version = "latest",

    [Parameter(ParameterSetName = "File")]
    [string]$ExtensionsFile,

    [Parameter(ParameterSetName = "All")]
    [switch]$InstallAllApproved,

    [Parameter(ParameterSetName = "BCPack")]
    [switch]$InstallBusinessCentralPack,

    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter(Mandatory)]
    [string]$Project,

    [string]$Feed = "approved-vscode-extensions",

    <# [string]$ProjectId, #>

    [switch]$AutoInstallAzureCli,

    [switch]$KeepDownloadedFiles,

    [switch]$WhatIfOnly,

    [switch]$ForceReinstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK([string]$msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "    [FAIL] $msg" -ForegroundColor Red }

function Get-PlainTextFromSecureString([securestring]$SecureString) {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function ConvertTo-SafePackageName {
    param([Parameter(Mandatory)][string]$Name)
    return $Name.ToLowerInvariant().Replace(".", "-")
}

function Invoke-AzCliSafe {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & az @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        Write-Fail "Azure CLI command failed."
        Write-Host "    az $($Arguments -join ' ')" -ForegroundColor Gray
        Write-Host "    $output" -ForegroundColor Gray
        exit 1
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Install-AzureCliWithWinget {
    if (-not $AutoInstallAzureCli) {
        Write-Fail "Azure CLI is required because this feed stores extensions as Azure Artifacts Universal Packages (UPack)."
        Write-Fail "Install once with: winget install --id Microsoft.AzureCLI -e"
        Write-Fail "Or rerun this script with: -AutoInstallAzureCli"
        exit 1
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Fail "winget is not available. Install Azure CLI manually from Microsoft documentation."
        exit 1
    }

    Write-Warn "Azure CLI not found. Installing Azure CLI using winget..."
    winget install --id Microsoft.AzureCLI -e --accept-package-agreements --accept-source-agreements

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Azure CLI installation failed. Install manually: winget install --id Microsoft.AzureCLI -e"
        exit 1
    }

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Fail "Azure CLI installed, but 'az' is not available in this PowerShell session."
        Write-Fail "Close PowerShell, reopen it, and rerun the script."
        exit 1
    }
}

function Ensure-AzDevOpsExtension {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Install-AzureCliWithWinget
    }

    $check = Invoke-AzCliSafe -Arguments @("extension", "show", "--name", "azure-devops", "--only-show-errors") -AllowFailure

    if ($check.ExitCode -ne 0) {
        Write-Warn "Azure DevOps CLI extension is missing. Installing it now..."
        $add = Invoke-AzCliSafe -Arguments @("extension", "add", "--name", "azure-devops", "--only-show-errors") -AllowFailure

        if ($add.ExitCode -ne 0) {
            Write-Fail "Failed to install Azure DevOps CLI extension."
            Write-Fail "Run manually: az extension add --name azure-devops"
            Write-Host "    $($add.Output)" -ForegroundColor Gray
            exit 1
        }
    }

    Write-OK "Azure CLI + azure-devops extension ready"
}

function Get-AdoProjectId {
    param(
        [Parameter(Mandatory)][string]$OrgName,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    <# if (-not [string]::IsNullOrWhiteSpace($ProjectId)) {
        return $ProjectId
    } #>

    $encodedProjectForOrgApi = [Uri]::EscapeDataString($ProjectName)
    $projectUrl = "https://dev.azure.com/$OrgName/_apis/projects/$encodedProjectForOrgApi`?api-version=7.1"
    Write-Host "    GET $projectUrl" -ForegroundColor Gray

    try {
        $projectObj = Invoke-RestMethod -Uri $projectUrl -Headers $Headers -Method GET -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($projectObj.id)) {
            return [string]$projectObj.id
        }
    }
    catch {
        Write-Warn "Could not resolve project id from project name '$ProjectName'. Azure CLI download will use project name."
        Write-Warn "Error: $($_.Exception.Message)"
    }

    return $ProjectName
}

function Get-LatestVersionFromPackage {
    param([Parameter(Mandatory)]$Package)

    if (-not $Package.versions) {
        return $null
    }

    $versions = @($Package.versions | Where-Object { -not [string]::IsNullOrWhiteSpace($_.version) })

    if ($versions.Count -eq 0) {
        return $null
    }

    try {
        $sorted = $versions | Sort-Object { [version]$_.version } -Descending
        return [string]$sorted[0].version
    }
    catch {
        return [string]$versions[0].version
    }
}

function Get-FeedPackage {
    param(
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][string]$EncodedProject,
        [Parameter(Mandatory)][string]$OrgName,
        [Parameter(Mandatory)][string]$FeedId,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $queryUrl = "https://feeds.dev.azure.com/$OrgName/$EncodedProject/_apis/packaging/feeds/$FeedId/packages" +
                "?packageNameQuery=$([Uri]::EscapeDataString($PackageName))&includeAllVersions=true&api-version=7.1"

    Write-Host "    GET $queryUrl" -ForegroundColor Gray

    $resp = Invoke-RestMethod -Uri $queryUrl -Headers $Headers -Method GET -ErrorAction Stop
    $pkg = $resp.value | Where-Object { $_.name -eq $PackageName } | Select-Object -First 1

    return $pkg
}

function Get-AllApprovedPackagesFromFeed {
    param(
        [Parameter(Mandatory)][string]$EncodedProject,
        [Parameter(Mandatory)][string]$OrgName,
        [Parameter(Mandatory)][string]$FeedId,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    Write-Step "Discovering all approved packages from feed"

    $all = @()
    $continuationToken = $null

    do {
        $url = "https://feeds.dev.azure.com/$OrgName/$EncodedProject/_apis/packaging/feeds/$FeedId/packages" +
               "?protocolType=UPack&includeAllVersions=true&`$top=200&api-version=7.1"

        if ($continuationToken) {
            $url += "&continuationToken=$([Uri]::EscapeDataString($continuationToken))"
        }

        Write-Host "    GET $url" -ForegroundColor Gray

        $response = Invoke-WebRequest -Uri $url -Headers $Headers -Method GET -UseBasicParsing -ErrorAction Stop
        $json = $response.Content | ConvertFrom-Json

        if ($json.value) {
            $all += @($json.value)
        }

        $continuationToken = $null
        if ($response.Headers.ContainsKey("x-ms-continuationtoken")) {
            $continuationToken = $response.Headers["x-ms-continuationtoken"]
        }
    }
    while ($continuationToken)

    $packages = $all | Sort-Object name
    Write-OK "Packages found in feed: $($packages.Count)"
    return $packages
}


function Get-VsixExtensionMetadata {
    param([Parameter(Mandatory)][string]$VsixPath)

    $extractPath = Join-Path $env:TEMP "vsix-meta-$(Get-Random)"
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

    try {
        # VSIX files are ZIP archives, but PowerShell Expand-Archive only accepts .zip paths.
        # Use .NET ZipFile directly so .vsix metadata can be extracted without renaming.
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::ExtractToDirectory($VsixPath, $extractPath)

        $packageJson = Get-ChildItem -Path $extractPath -Filter "package.json" -Recurse -File |
                       Where-Object { $_.FullName -match "[\\/]extension[\\/]package\.json$" -or $_.Name -eq "package.json" } |
                       Select-Object -First 1

        if (-not $packageJson) {
            return $null
        }

        $pkg = Get-Content -Path $packageJson.FullName -Raw | ConvertFrom-Json

        if ([string]::IsNullOrWhiteSpace($pkg.publisher) -or [string]::IsNullOrWhiteSpace($pkg.name)) {
            return $null
        }

        return [pscustomobject]@{
            Id      = "$($pkg.publisher).$($pkg.name)".ToLowerInvariant()
            Version = [string]$pkg.version
        }
    }
    catch {
        Write-Warn "Could not read VSIX metadata from '$VsixPath'. Error: $($_.Exception.Message)"
        return $null
    }
    finally {
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-InstalledVsCodeExtensions {
    $installed = @{}

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $lines = & code --list-extensions --show-versions 2>$null
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    foreach ($line in $lines) {
        if ($line -match "^(.+)@(.+)$") {
            $installed[$Matches[1].ToLowerInvariant()] = $Matches[2]
        }
    }

    return $installed
}

function Test-VersionGreaterOrEqual {
    param(
        [Parameter(Mandatory)][string]$InstalledVersion,
        [Parameter(Mandatory)][string]$TargetVersion
    )

    try {
        return ([version]$InstalledVersion -ge [version]$TargetVersion)
    }
    catch {
        return ($InstalledVersion -eq $TargetVersion)
    }
}

function Test-ShouldSkipInstalledExtension {
    param(
        [Parameter(Mandatory)][string]$VsixPath,
        [Parameter(Mandatory)][string]$TargetVersion
    )

    if ($ForceReinstall) {
        Write-Warn "ForceReinstall enabled. Existing installation check skipped."
        return $false
    }

    Write-Step "Checking existing VS Code installation"

    $metadata = Get-VsixExtensionMetadata -VsixPath $VsixPath
    if (-not $metadata) {
        Write-Warn "Could not read VSIX extension id. Proceeding with install."
        return $false
    }

    $installed = Get-InstalledVsCodeExtensions

    if ($installed.ContainsKey($metadata.Id)) {
        $installedVersion = [string]$installed[$metadata.Id]

        if (Test-VersionGreaterOrEqual -InstalledVersion $installedVersion -TargetVersion $TargetVersion) {
            Write-OK "Already installed: $($metadata.Id) v$installedVersion. Target feed version is v$TargetVersion. Skipping."
            return $true
        }

        Write-Warn "Older version installed: $($metadata.Id) v$installedVersion. Target feed version is v$TargetVersion. Updating."
        return $false
    }

    Write-OK "Extension not installed yet: $($metadata.Id)"
    return $false
}

function Install-OneApprovedExtension {
    param(
        [Parameter(Mandatory)][string]$RequestedName,
        [string]$RequestedVersion = "latest"
    )

    $safeName = ConvertTo-SafePackageName -Name $RequestedName

    Write-Step "Locating package and version in feed"
    Write-Host "    Requested name : $RequestedName" -ForegroundColor Gray
    Write-Host "    Feed safe name : $safeName" -ForegroundColor Gray

    $pkg = Get-FeedPackage `
        -PackageName $safeName `
        -EncodedProject $script:encodedProject `
        -OrgName $script:orgName `
        -FeedId $script:feedId `
        -Headers $script:headers

    if (-not $pkg) {
        Write-Fail "Package '$safeName' not found in feed '$script:feedName'."
        Write-Fail "Check package name. Marketplace ID should be converted to lowercase and dots replaced with dashes."
        return $false
    }

    $versionToInstall = $RequestedVersion
    if ([string]::IsNullOrWhiteSpace($versionToInstall)) {
        $versionToInstall = "latest"
    }

    if ($versionToInstall.ToLowerInvariant() -eq "latest") {
        $latest = Get-LatestVersionFromPackage -Package $pkg
        if ([string]::IsNullOrWhiteSpace($latest)) {
            Write-Fail "Could not resolve latest version for '$safeName'."
            return $false
        }
        $versionToInstall = $latest
        Write-OK "Latest version resolved: $versionToInstall"
    }

    $versionObj = $pkg.versions | Where-Object { $_.version -eq $versionToInstall } | Select-Object -First 1
    if (-not $versionObj) {
        Write-Fail "Version '$versionToInstall' was not found for '$safeName'."
        Write-Host "    Available versions:" -ForegroundColor Gray
        $pkg.versions | Select-Object -ExpandProperty version | ForEach-Object {
            Write-Host "      - $_" -ForegroundColor Gray
        }
        return $false
    }

    $protocolType = [string]$pkg.protocolType
    Write-OK "Package found  : $($pkg.name)"
    Write-OK "Version found  : $($versionObj.version)"
    Write-OK "Protocol type  : $protocolType"

    if ($protocolType.ToLowerInvariant() -ne "upack") {
        Write-Fail "Expected UPack package, but detected '$protocolType'."
        return $false
    }

    if ($WhatIfOnly) {
        Write-Warn "WhatIfOnly: Would download and install '$safeName' v$versionToInstall"
        return $true
    }

    Ensure-AzDevOpsExtension

    $tempDir = Join-Path $env:TEMP "vsix-install-$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        Write-Step "Downloading $safeName v$versionToInstall from Azure Artifacts"

        $env:AZURE_DEVOPS_EXT_PAT = $script:pat
        $env:AZURE_DEVOPS_EXT_ARTIFACTTOOL_PATVAR = $script:pat

        Invoke-AzCliSafe -Arguments @(
            "devops", "configure",
            "--defaults",
            "organization=$script:orgUrl",
            "project=$script:projectForAz",
            "--only-show-errors"
        ) | Out-Null

        Write-Host "    az artifacts universal download --organization `"$script:orgUrl`" --project `"$script:projectForAz`" --scope project --feed `"$script:Feed`" --name `"$safeName`" --version `"$versionToInstall`" --path `"$tempDir`"" -ForegroundColor Gray

        $download = Invoke-AzCliSafe -Arguments @(
            "artifacts", "universal", "download",
            "--organization", $script:orgUrl,
            "--project", $script:projectForAz,
            "--scope", "project",
            "--feed", $script:Feed,
            "--name", $safeName,
            "--version", $versionToInstall,
            "--path", $tempDir,
            "--only-show-errors"
        ) -AllowFailure

        if ($download.ExitCode -ne 0) {
            Write-Fail "Azure CLI failed to download the Universal Package."
            Write-Host "    $($download.Output)" -ForegroundColor Gray
            return $false
        }

        Write-OK "Downloaded to $tempDir"

        Write-Step "Locating VSIX file"
        $vsixFile = Get-ChildItem -Path $tempDir -Filter "*.vsix" -Recurse -File | Select-Object -First 1

        if (-not $vsixFile) {
            Write-Fail "Downloaded package does not contain a .vsix file."
            Write-Host "    Downloaded contents:" -ForegroundColor Gray
            Get-ChildItem -Path $tempDir -Recurse | ForEach-Object {
                Write-Host "      $($_.FullName)" -ForegroundColor Gray
            }
            return $false
        }

        Write-OK "VSIX located: $($vsixFile.FullName)"

        if (Test-ShouldSkipInstalledExtension -VsixPath $vsixFile.FullName -TargetVersion $versionToInstall) {
            return $true
        }

        Write-Step "Installing extension into VS Code"
        Write-Host "    Running: code --install-extension `"$($vsixFile.FullName)`" --force" -ForegroundColor Gray

        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $installOut = & code --install-extension $vsixFile.FullName --force 2>&1
            $installExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldPreference
        }

        Write-Host "    $installOut" -ForegroundColor Gray

        if ($installExit -ne 0) {
            $installText = ($installOut | Out-String)

            if ($installText -match "built-in extension with version '([^']+)' and cannot be downgraded to version '([^']+)'") {
                $builtInVersion = $Matches[1]
                $targetVersion  = $Matches[2]
                Write-Warn "Built-in extension detected. Installed built-in version is v$builtInVersion; feed target is v$targetVersion."
                Write-OK "Skipping downgrade for built-in extension. No action required."
                return $true
            }

            if ($installText -match "built-in extension" -and $installText -match "cannot be downgraded") {
                Write-Warn "Built-in extension downgrade blocked by VS Code."
                Write-OK "Skipping built-in extension. No action required."
                return $true
            }

            Write-Fail "VS Code returned exit code $installExit. Output: $installOut"
            return $false
        }

        Write-OK "Installed successfully: $safeName v$versionToInstall"
        return $true
    }
    finally {
        if ($KeepDownloadedFiles) {
            Write-Warn "Keeping downloaded files at: $tempDir"
        }
        else {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# FOLDER-LOCK AWARENESS
# Detects whether the VS Code extensions folder is write-locked (icacls).
# If locked  -- temporarily unlocks before install, re-locks after.
# If unlocked -- proceeds normally; does NOT apply a new lock automatically.
# The initial lock is applied once per machine via Set-ExtensionFolderLock.ps1.
# ---------------------------------------------------------------------------

# AUTO-DETECT VS Code extensions folder
# Priority order:
#   1. User profile folder  -- %USERPROFILE%\.vscode\extensions  (most common)
#   2. User install folder  -- %LOCALAPPDATA%\Programs\Microsoft VS Code\extensions
#   3. System install       -- C:\Program Files\Microsoft VS Code\extensions
#   4. Fallback via PATH    -- resolve from code.cmd location
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

$detectedPath              = Get-VSCodeExtensionsPath
$script:extensionsPath     = if ($detectedPath) { $detectedPath } else { "$env:USERPROFILE\.vscode\extensions" }
$script:wasLocked          = $false

function Test-FolderWriteLocked {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        return $false
    }

    $testFile = Join-Path $Path ".write-test-$(New-Guid)"
    try {
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        return $false   # write succeeded -- NOT locked
    }
    catch {
        return $true    # write failed -- IS locked
    }
}

function Unlock-ExtensionsFolder {
    Write-Host "`n==> Extensions folder is write-locked (icacls)" -ForegroundColor Cyan
    Write-Host "    Temporarily unlocking for approved install..." -ForegroundColor Gray
    icacls $script:extensionsPath /grant:r "${env:USERNAME}:(OI)(CI)(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    [FAIL] Could not unlock extensions folder. Try running as Administrator." -ForegroundColor Red
        exit 1
    }
    Write-Host "    [OK] Temporarily unlocked" -ForegroundColor Green
}

function Lock-ExtensionsFolder {
    Write-Host "`n==> Re-locking extensions folder..." -ForegroundColor Cyan
    icacls $script:extensionsPath /inheritance:r                          | Out-Null
    icacls $script:extensionsPath /grant:r "SYSTEM:(OI)(CI)(F)"          | Out-Null
    icacls $script:extensionsPath /grant:r "${env:USERNAME}:(OI)(CI)(RX)" | Out-Null
    Write-Host "    [OK] Extensions folder re-locked" -ForegroundColor Green
}

# Check lock state before anything else runs
if (Test-FolderWriteLocked -Path $script:extensionsPath) {
    Unlock-ExtensionsFolder
    $script:wasLocked = $true
}
else {
    Write-Host "`n==> Extensions folder is writable -- no unlock needed" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# PRE-FLIGHT
# ---------------------------------------------------------------------------
Write-Step "Pre-flight checks"

$codeCmd = Get-Command code -ErrorAction SilentlyContinue
if (-not $codeCmd) {
    Write-Fail "VS Code ('code') not found in PATH."
    Write-Fail "Open VS Code > Command Palette > 'Shell Command: Install code command in PATH', then retry."
    exit 1
}

$codeVersion = (& code --version 2>$null | Select-Object -First 1)
Write-OK "VS Code found: $codeVersion"

# ---------------------------------------------------------------------------
# AUTHENTICATION
# ---------------------------------------------------------------------------
Write-Step "Authentication"

$runningInPipeline = $env:TF_BUILD -eq "True"

if ($runningInPipeline) {
    $pat = $env:AZURE_DEVOPS_EXT_PAT
    if ([string]::IsNullOrWhiteSpace($pat)) { $pat = $env:SYSTEM_ACCESSTOKEN }

    if ([string]::IsNullOrWhiteSpace($pat)) {
        Write-Fail "Running in pipeline but neither AZURE_DEVOPS_EXT_PAT nor SYSTEM_ACCESSTOKEN is set."
        exit 1
    }

    Write-OK "Running in pipeline - using token from environment"
}
else {
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_DEVOPS_EXT_PAT)) {
        $pat = $env:AZURE_DEVOPS_EXT_PAT
        Write-OK "Using token from AZURE_DEVOPS_EXT_PAT environment variable"
    }
    else {
        $orgDisplay = $Organization.TrimEnd("/")
        Write-Host "    Enter your Azure DevOps PAT with Packaging > Read permission." -ForegroundColor Gray
        Write-Host "    Create one at: $orgDisplay/_usersSettings/tokens" -ForegroundColor Gray
        $patSecure = Read-Host "    PAT" -AsSecureString
        $pat = Get-PlainTextFromSecureString $patSecure
    }
}

$script:orgUrl  = $Organization.TrimEnd("/")
$script:orgName = $script:orgUrl.Split("/")[-1]
$script:Feed    = $Feed

$b64Token = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$script:headers = @{
    Authorization = "Basic $b64Token"
    Accept        = "application/json"
}

$script:pat = $pat

# ---------------------------------------------------------------------------
# RESOLVE PROJECT
# ---------------------------------------------------------------------------
Write-Step "Resolving Azure DevOps project"
$script:projectForAz = Get-AdoProjectId -OrgName $script:orgName -ProjectName $Project -Headers $script:headers
Write-OK "Project value for download: $script:projectForAz"

# ---------------------------------------------------------------------------
# VERIFY FEED
# ---------------------------------------------------------------------------
Write-Step "Verifying feed"

$script:encodedProject = [Uri]::EscapeDataString($Project)
$feedApiUrl = "https://feeds.dev.azure.com/$script:orgName/$script:encodedProject/_apis/packaging/feeds/$Feed`?api-version=7.1"

Write-Host "    GET $feedApiUrl" -ForegroundColor Gray

try {
    $feedObj = Invoke-RestMethod -Uri $feedApiUrl -Headers $script:headers -Method GET -ErrorAction Stop
}
catch {
    Write-Fail "Cannot reach feed '$Feed'. Check PAT, organization, project and feed name."
    Write-Fail "HTTP error: $($_.Exception.Message)"
    exit 1
}

$script:feedId = $feedObj.id
$script:feedName = $feedObj.name

if ([string]::IsNullOrWhiteSpace($script:feedId)) {
    Write-Fail "Feed response did not contain an id."
    exit 1
}

Write-OK "Feed verified  : $script:feedName"
Write-OK "Feed id        : $script:feedId"

# ---------------------------------------------------------------------------
# BUILD INSTALL LIST
# ---------------------------------------------------------------------------
$installList = @()

switch ($PSCmdlet.ParameterSetName) {
    "Single" {
        if ([string]::IsNullOrWhiteSpace($ExtensionName)) {
            Write-Fail "ExtensionName is required for single install."
            exit 1
        }

        $installList += [pscustomobject]@{
            name    = $ExtensionName
            version = $Version
        }
    }

    "File" {
        if (-not (Test-Path $ExtensionsFile)) {
            Write-Fail "ExtensionsFile not found: $ExtensionsFile"
            exit 1
        }

        Write-Step "Loading bulk install file"
        $raw = Get-Content -Path $ExtensionsFile -Raw
        $json = $raw | ConvertFrom-Json

        foreach ($item in $json) {
            if ([string]::IsNullOrWhiteSpace($item.name)) {
                Write-Warn "Skipping item without name."
                continue
            }

            $itemVersion = "latest"
            if ($item.PSObject.Properties.Name -contains "version" -and -not [string]::IsNullOrWhiteSpace($item.version)) {
                $itemVersion = [string]$item.version
            }

            $installList += [pscustomobject]@{
                name    = [string]$item.name
                version = $itemVersion
            }
        }
    }

    "All" {
        $packages = Get-AllApprovedPackagesFromFeed `
            -EncodedProject $script:encodedProject `
            -OrgName $script:orgName `
            -FeedId $script:feedId `
            -Headers $script:headers

        foreach ($pkg in $packages) {
            $installList += [pscustomobject]@{
                name    = [string]$pkg.name
                version = "latest"
            }
        }
    }

    "BCPack" {
        $bcPack = @(
            "ms-dynamics-smb-al",
            "waldo-crs-al-language-extension",
            "andrzejzwierzchowski-al-code-outline",
            "davidfeldhoff-al-codeactions",
            "bartpermentier-al-toolbox",
            "rasmus-al-var-helper",
            "wbrakowski-al-navigator",
            "martonsagi-al-object-designer",
            "stefanmaron-businesscentral-lintercop",
            "365businessdevelopment-bdev-al-xml-doc",
            "usernamehw-errorlens",
            "vjeko-vjeko-al-objid",
            "jamespearson-al-test-runner",
            "rvanbekkum-xliff-sync",
            "nabsolutions-nab-al-tools",
            "eamodio-gitlens",
            "donjayamanne-githistory",
            "ms-vscode-powershell",
            "ms-azuretools-vscode-docker",
            "humao-rest-client",
            "gruntfuggly-todo-tree",
            "wayou-vscode-todo-highlight",
            "nwallace-createguid",
            "ryu1kn-partial-diff",
            "chunsen-bracket-select",
            "vscode-icons-team-vscode-icons",
            "nikitakunevich-snippet-creator",
            "github-copilot",
            "github-copilot-chat"
        )

        foreach ($name in $bcPack) {
            $installList += [pscustomobject]@{
                name    = $name
                version = "latest"
            }
        }
    }
}

if ($installList.Count -eq 0) {
    Write-Fail "No extensions selected for installation."
    exit 1
}

Write-Step "Install plan"
Write-OK "Extensions selected: $($installList.Count)"
$installList | ForEach-Object {
    Write-Host ("    - {0}  ({1})" -f $_.name, $_.version) -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# INSTALL
# ---------------------------------------------------------------------------
$successCount = 0
$failed = @()

foreach ($item in $installList) {
    $ok = Install-OneApprovedExtension -RequestedName $item.name -RequestedVersion $item.version

    if ($ok) {
        $successCount++
    }
    else {
        $failed += $item.name
    }
}

# ---------------------------------------------------------------------------
# FINAL SUMMARY
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Install Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Requested : $($installList.Count)" -ForegroundColor Cyan
Write-Host "  Success   : $successCount" -ForegroundColor Green
Write-Host "  Failed    : $($failed.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { "Green" } else { "Red" })

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed extensions:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# RE-LOCK (only if this script unlocked the folder -- preserves original state)
# ---------------------------------------------------------------------------
if ($script:wasLocked) {
    Lock-ExtensionsFolder
}
