# VS Code Extension Controller — Azure Artifacts Feed

> **Author:** Sudharsan M &nbsp;|&nbsp; **Portfolio Project** &nbsp;|&nbsp;
> **Feed:** `approved-vscode-extensions` &nbsp;|&nbsp;
> **Extensions:** 29 approved (Business Central / AL focus) &nbsp;|&nbsp;
> **Status:** ![Production-Ready](https://img.shields.io/badge/status-production--ready-brightgreen)

A private, auditable distribution channel for approved VS Code extensions,
built on **Azure Artifacts Universal Packages** and fully automated with
Azure DevOps pipelines. Designed for **Microsoft Dynamics 365 Business
Central** development teams.

---

## Why This Approach?

After the GitHub breach caused by a malicious VS Code extension (Nx Console),
storing approved VSIX files in Azure Artifacts gives you a layered defence:

- ✅ Only vetted, security-reviewed extensions reach developer machines
- ✅ Versioned and immutable — rollback to any previous version is trivial
- ✅ Feed permissions enforce who can publish vs. download
- ✅ Full audit trail: every publish is logged with extension, version, and timestamp
- ✅ Weekly automated drift detection — the feed never silently falls behind
- ✅ Works for `.vsix` files (the `extensions.allowed` policy does **NOT** block sideloading via `code --install-extension`)
- ✅ No Azure subscription required — runs entirely on the **free** 5-user Azure DevOps plan

---

## Architecture & Flow

```
VS Marketplace  (public source of all .vsix files)
       │
       │  download .vsix on pipeline run
       ▼
Azure DevOps Pipelines
  ├── seed-extensions.yml   ──►  Bulk-publish all 29 approved extensions
  └── audit-extensions.yml  ──►  Weekly drift report + auto-trigger seed
       │
       │  az artifacts universal publish
       ▼
Azure Artifacts Feed: approved-vscode-extensions
  (Universal Packages — one package per extension, versioned)
       │
       │  Install-ApprovedExtension.ps1
       ▼
Developer Workstation  (VS Code)
  code --install-extension <name>.vsix --force
```

### Automatic Update Loop

The system is self-maintaining. No manual intervention needed for updates:

```
Audit pipeline runs  (Monday 08:00 UTC, cron: 0 8 * * 1)
       │
       ├── Compares all 29 feed versions against VS Marketplace latest
       ├── Publishes markdown audit report as pipeline artifact
       │
       └── If updates_available > 0
              └──► Auto-triggers Seed pipeline
                     └──► Seed fetches latest .vsix files & updates feed
```

---

## Repository Structure

```
VSCode-Extension-Governance/
├── pipelines/
│   ├── seed-extensions.yml       # Bulk seed all 29 extensions into the feed
│   └── audit-extensions.yml      # Weekly audit: feed vs Marketplace + auto-trigger
└── scripts/
    ├── approved-extensions.json          # Single source of truth — approved list
    ├── Publish-ApprovedExtensions.ps1    # Called by the Seed pipeline
    └── Install-ApprovedExtension.ps1     # Developer install script
```

---

## One-Time Setup

### 1. Enable OAuth Token Access

Go to **Azure DevOps → Project Settings → Pipelines → Settings**
and enable **"Allow scripts to access the OAuth token"**.

### 2. Create the Azure Artifacts Feed

1. Go to **Artifacts → Create Feed**
2. Name: **`approved-vscode-extensions`**
3. Visibility: **Project**
4. Upstream sources: **unchecked**
5. After creation → **Feed Settings → Permissions** → add:
   - `[Project Name] Build Service ([Your Org])` → **Contributor**

### 3. Import the Seed Pipeline

1. **Pipelines → New Pipeline → Azure Repos Git** → select your repo
2. Choose **Existing Azure Pipelines YAML file**
3. Branch: `main`, Path: `/pipelines/seed-extensions.yml`
4. Click **Continue → Save** *(do not run yet)*
5. Rename to: **`Seed Extensions`**

### 4. Import the Audit Pipeline

Repeat Step 3 for `/pipelines/audit-extensions.yml`.
Rename to: **`Audit Extensions`**.

After saving, open the YAML and set `seedPipelineId` to the numeric ID
of your Seed pipeline (visible in its URL as `?definitionId=N`):

```yaml
variables:
  feedName:       "approved-vscode-extensions"
  seedPipelineId: "REPLACE_WITH_YOUR_SEED_PIPELINE_ID"   # ← replace with your actual Seed pipeline ID
```

### 5. Run the Initial Seed

**Pipelines → Seed Extensions → Run pipeline**

| Parameter | Value |
|---|---|
| Azure Artifacts Feed Name | `approved-vscode-extensions` (leave default) |
| Skip auto-resolving | Leave **unchecked** |

First run takes approximately **20–25 minutes** (downloads ~1.2 GB total).
All 29 extensions will show `Published` in the summary table.

> **Re-running:** If a version already exists in the feed, you will see
> `Skipped (already exists)` — this is correct and safe.

### 6. Verify with the Audit Pipeline

**Pipelines → Audit Extensions → Run pipeline**

Expected output when all 29 extensions are seeded and up-to-date:

```
============================================
  Audit complete
  Up to date    : 29
  Updates avail : 0
  Missing       : 0
  Market errors : 0
============================================
```

---

## Day-to-Day Workflows

### Seed all approved extensions (bulk update)

Trigger the **Seed Extensions** pipeline manually to refresh all extensions
to their latest Marketplace versions. Already-current versions are skipped
automatically.

```powershell
# Or run locally (pipeline agent must have Azure CLI installed)
.\scripts\Publish-ApprovedExtensions.ps1 `
    -Organization "https://dev.azure.com/[your-org]" `
    -Project      "[your-project]"
```

### Run an on-demand audit

Trigger **Audit Extensions** manually at any time.
The audit will detect any version drift and auto-trigger the Seed pipeline
if updates are found. A full markdown report is published as a pipeline
artifact (`extension-audit-report/audit-report.md`).

---

## Developer Install (run on each machine)

### Install all 29 approved extensions (recommended for new machines)

```powershell
.\scripts\Install-ApprovedExtension.ps1 `
    -InstallAllApproved `
    -Organization      "https://dev.azure.com/[your-org]" `
    -Project           "[your-project]" `
    -AutoInstallAzureCli
```

The script prompts for your PAT ([Packaging → Read] scope) if not already
set in `$env:AZURE_DEVOPS_EXT_PAT`. Expected output:

```
==> Install Summary
============================================
  Requested : 29
  Success   : 29
  Failed    : 0
============================================
Done.
```

### Install the BC/AL pack only

```powershell
.\scripts\Install-ApprovedExtension.ps1 `
    -InstallBusinessCentralPack `
    -Organization "https://dev.azure.com/[your-org]" `
    -Project      "[your-project]"
```

### Install a single extension

> **Important:** Use the **feed package name** (lowercase, dots → dashes),
> not the original Marketplace ID.  
> Example: `github-copilot` not `GitHub.copilot`.

```powershell
.\scripts\Install-ApprovedExtension.ps1 `
    -ExtensionName "ms-dynamics-smb-al" `
    -Version       "latest" `
    -Organization  "https://dev.azure.com/[your-org]" `
    -Project       "[your-project]"
```

### Bulk install from a custom JSON file

```json
[
  { "name": "ms-dynamics-smb-al",   "version": "latest" },
  { "name": "eamodio-gitlens",       "version": "latest" },
  { "name": "github-copilot",        "version": "latest" }
]
```

```powershell
.\scripts\Install-ApprovedExtension.ps1 `
    -ExtensionsFile ".\my-extensions.json" `
    -Organization   "https://dev.azure.com/[your-org]" `
    -Project        "[your-project]"
```

### Dry run (WhatIf)

```powershell
.\scripts\Install-ApprovedExtension.ps1 `
    -InstallAllApproved `
    -Organization "https://dev.azure.com/[your-org]" `
    -Project      "[your-project]" `
    -WhatIfOnly
```

---

## Adding a New Extension

1. **Security Review** — verify publisher reputation, download count, and
   source code on VS Marketplace. Obtain written approval.

2. **Edit `scripts/approved-extensions.json`** — add an entry in the
   appropriate group:

```json
{
  "name":              "publisher.extension-name",
  "version":           "0.0.0",
  "description":       "Short ASCII-only description",
  "approvedBy":        "security-team",
  "approvalDate":      "2026-06-01",
  "publisher":         "Publisher Display Name",
  "needsVersionReview": true,
  "vsixUrl":           "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/PUBLISHER/vsextensions/EXTENSION_NAME/REPLACE_VERSION/vspackage"
}
```

3. **Commit and push:**

```bash
git add scripts/approved-extensions.json
git commit -m "feat: add publisher.extension-name to approved list"
git push origin main
```

4. **Run Seed pipeline** — only the new extension is published;
   all 29 existing ones show `Skipped (already exists)`.

> **Naming:** The `name` field must be the exact `publisher.extensionId`
> from the VS Marketplace URL.  
> Example: `https://marketplace.visualstudio.com/items?itemName=ms-python.python`
> → name is `ms-python.python`.

---

## Approved Extensions (29 Total)

All extensions are focused on **Microsoft Dynamics 365 Business Central**
and general DevOps productivity.

| Group | Marketplace ID | Feed Package Name |
|---|---|---|
| **Core AL** | `ms-dynamics-smb.al` | `ms-dynamics-smb-al` |
| **Core AL** | `waldo.crs-al-language-extension` | `waldo-crs-al-language-extension` |
| **Core AL** | `andrzejzwierzchowski.al-code-outline` | `andrzejzwierzchowski-al-code-outline` |
| **Core AL** | `davidfeldhoff.al-codeactions` | `davidfeldhoff-al-codeactions` |
| **Core AL** | `bartpermentier.al-toolbox` | `bartpermentier-al-toolbox` |
| **Core AL** | `rasmus.al-var-helper` | `rasmus-al-var-helper` |
| **Core AL** | `wbrakowski.al-navigator` | `wbrakowski-al-navigator` |
| **Core AL** | `martonsagi.al-object-designer` | `martonsagi-al-object-designer` |
| **Code Quality** | `StefanMaron.businesscentral-lintercop` | `stefanmaron-businesscentral-lintercop` |
| **Code Quality** | `365businessdevelopment.bdev-al-xml-doc` | `365businessdevelopment-bdev-al-xml-doc` |
| **Code Quality** | `usernamehw.errorlens` | `usernamehw-errorlens` |
| **Object ID Mgmt** | `vjeko.vjeko-al-objid` | `vjeko-vjeko-al-objid` |
| **Testing** | `jamespearson.al-test-runner` | `jamespearson-al-test-runner` |
| **Translations** | `rvanbekkum.xliff-sync` | `rvanbekkum-xliff-sync` |
| **Translations** | `nabsolutions.nab-al-tools` | `nabsolutions-nab-al-tools` |
| **Git & DevOps** | `eamodio.gitlens` | `eamodio-gitlens` |
| **Git & DevOps** | `donjayamanne.githistory` | `donjayamanne-githistory` |
| **Git & DevOps** | `ms-vscode.powershell` | `ms-vscode-powershell` |
| **Docker & API** | `ms-azuretools.vscode-docker` | `ms-azuretools-vscode-docker` |
| **Docker & API** | `humao.rest-client` | `humao-rest-client` |
| **Productivity** | `Gruntfuggly.todo-tree` | `gruntfuggly-todo-tree` |
| **Productivity** | `wayou.vscode-todo-highlight` | `wayou-vscode-todo-highlight` |
| **Productivity** | `nwallace.createguid` | `nwallace-createguid` |
| **Productivity** | `ryu1kn.partial-diff` | `ryu1kn-partial-diff` |
| **Productivity** | `chunsen.bracket-select` | `chunsen-bracket-select` |
| **Productivity** | `vscode-icons-team.vscode-icons` | `vscode-icons-team-vscode-icons` |
| **Productivity** | `nikitakunevich.snippet-creator` | `nikitakunevich-snippet-creator` |
| **AI Dev** | `GitHub.copilot` | `github-copilot` |
| **AI Dev** | `GitHub.copilot-chat` | `github-copilot-chat` |

> **Safe Name Rule:** Feed package names are derived automatically:
> `extensionId.ToLower().Replace(".", "-")`  
> Always use the **feed package name** with the install script, never the Marketplace ID.

---

## Script Parameter Reference

### `Install-ApprovedExtension.ps1`

| Parameter | Description |
|---|---|
| `-InstallAllApproved` | Install all packages found in the feed *(recommended for new machines)* |
| `-InstallBusinessCentralPack` | Install BC/AL-specific extension subset only |
| `-ExtensionName` | Feed package name for single install (lowercase, dots as dashes) |
| `-Version` | Specific version number or `latest` (default: `latest`) |
| `-ExtensionsFile` | Path to JSON file for custom bulk install |
| `-Organization` | Azure DevOps org URL: `https://dev.azure.com/[your-org]` |
| `-Project` | Project name |
| `-Feed` | Feed name (default: `approved-vscode-extensions`) |
| `-AutoInstallAzureCli` | Auto-installs Azure CLI via `winget` if not present |
| `-ForceReinstall` | Reinstall even if already at the target version |
| `-WhatIfOnly` | Dry run — shows what would happen without installing |
| `-KeepDownloadedFiles` | Keeps VSIX in temp folder after install (for debugging) |

### `Publish-ApprovedExtensions.ps1`

| Parameter | Description |
|---|---|
| `-Organization` | Azure DevOps org URL *(Mandatory)* |
| `-Project` | Project name *(Mandatory)* |
| `-Feed` | Feed name (default: `approved-vscode-extensions`) |
| `-ApprovedListPath` | Path to `approved-extensions.json` (default: same folder as script) |
| `-SkipAutoResolve` | Skip Marketplace version lookup — only use if Marketplace is unreachable |

---

## Troubleshooting

| Error | Cause & Fix |
|---|---|
| `has been deleted, and cannot be republished` | Package deleted from feed. Fix: delete entire feed, recreate with same name, re-run Seed. |
| `401 Unauthorized` | OAuth token access disabled. Fix: Project Settings → Pipelines → Settings → enable. |
| `403 Forbidden` | Build Service missing Contributor role. Fix: Artifacts → Feed Settings → Permissions. |
| `PAT authentication failed` | PAT expired or wrong scope. Fix: create new PAT with **Packaging → Read**. |
| `code command not found` | VS Code not in PATH. Fix: VS Code → Ctrl+Shift+P → *Shell Command: Install 'code' command in PATH*. |
| `Resource not found (404)` | Extension version removed from Marketplace. Fix: re-run Seed — it auto-fetches latest. |
| `Incompatible: built-in extension` | VS Code has a newer built-in version. Script logs `[WARN] Skipping` — no action needed. |
| Script blocked: `not digitally signed` | PowerShell execution policy. Fix: `Unblock-File -Path ".\Install-ApprovedExtension.ps1"` |

### Re-seeding a clean feed

> ⚠️ Azure Artifacts **permanently** blocks republishing the same
> `package name + version` after deletion, even from the Recycle Bin.
> The only solution is to delete and recreate the entire feed.

1. **Artifacts → `approved-vscode-extensions` → Feed Settings → Delete Feed**
2. Create a new feed with the **exact same name**
3. Add Build Service as Contributor
4. Run the Seed pipeline

---

## Pair with `extensions.allowed` (Recommended)

For maximum control, combine this feed with VS Code's built-in allow-list
policy (VS Code ≥ 1.96). Deploy via Group Policy, Intune, or `settings.json`:

```json
{
  "extensions.allowed": {
    "ms-dynamics-smb.al":  true,
    "eamodio.gitlens":     true,
    "GitHub.copilot":      true
  },
  "extensions.autoUpdate": false
}
```

This creates a **three-layer defence**:

| Layer | Controls |
|---|---|
| **Azure Artifacts feed** | *What* extensions are available to download |
| `extensions.allowed` policy | *What* VS Code will load and run |
| `icacls` / WDAC | Blocks raw `.vsix` sideloading from untrusted paths |

---

## Rotating a Compromised Extension

1. **Do not delete** the malicious version from the feed — preserve evidence.
2. Remove the entry from `approved-extensions.json` and commit.
3. Publish a clean replacement version via the Seed pipeline.
4. Notify developers to re-run `Install-ApprovedExtension.ps1 -ForceReinstall`.
5. Update `extensions.allowed` to block the compromised version if needed.

---

*VS Code Extension Controller — Portfolio Project by [**Sudharsan M**](https://linkedin.com/in/sudharsan-m)*  
*Feed: `approved-vscode-extensions` &nbsp;|&nbsp; 29 approved extensions &nbsp;|&nbsp; Version 1.0*
