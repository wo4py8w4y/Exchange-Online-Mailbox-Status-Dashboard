# MailboxDashboard Script Refactoring & Optimization Plan

**Date**: 2026-09-07  
**Objective**: Restructure collector scripts for modularity, efficiency, and maintainability  
**Status**: Planning phase (awaiting approval)

---

## 1. Current State Analysis

### Existing Scripts (by scope and lines of code)

| Script | Lines | Primary Purpose | Issues |
|--------|-------|-----------------|--------|
| `Update-MailboxDashboard.ps1` | 657 | Monolithic legacy orchestrator | Mixed concerns (auth + collection + JSON generation); hardcoded paths; multiple auth modes scattered |
| `HistoryCollector.ps1` | 471 | Core mailbox data collection | Good but dependent on parent; no standalone path resolution |
| `Register-EntraApp.ps1` | 419 | Entra app registration setup | One-time setup; not reusable in main flow |
| `Get-ExchangeOnlineAccessToken.ps1` | 362 | Token acquisition | Good utility but not integrated with main orchestrator |
| `MergeJSON.ps1` | 210 | Merge threaded job outputs | Relative paths fragile; no error recovery |
| `Extract-HotData.ps1` | 126 | Generate hot data snapshot | Minimal; works well but isolated |
| `Start-HistoryCollectorThreaded.ps1` | 65 | Threaded execution wrapper | Very lightweight; mostly delegation |

### Current Data Flow

```
Exchange Online
    ↓
[Choose Auth] ← Certificate OR Interactive
    ↓
Update-MailboxDashboard.ps1 (deprecated flow)
OR
Start-HistoryCollectorThreaded.ps1 → HistoryCollector.ps1
    ↓
Temp/ThreadJobs/*.json (intermediate outputs)
    ↓
MergeJSON.ps1
    ↓
history.json
    ↓
Extract-HotData.ps1
    ↓
data.json
    ↓
Web UI (dashboard.js)
```

### Key Problems Identified

1. **Path Confusion**
   - Mixed absolute & relative paths
   - Some scripts assume specific working directory
   - Config paths inconsistent across scripts

2. **Authentication Fragmentation**
   - Certificate auth in Update-MailboxDashboard.ps1
   - Interactive auth via graph.auth.lite (newer integration)
   - Token helper script separate from main flow
   - No centralized auth decision point

3. **Redundant Utilities**
   - `Resolve-AbsolutePath` implemented in 3+ files
   - JSON I/O logic duplicated
   - Permission conversion logic repeated

4. **No Validation**
   - No JSON schema validation
   - No data repair/culling logic
   - Invalid records silently pass through

5. **No Test Mode**
   - Cannot test dashboard without live Exchange connection
   - No synthetic data generation
   - Manual test data creation required

6. **Configuration Scattered**
   - dashboardConfig.json used differently by different scripts
   - Some hardcoded defaults override config
   - Auth mode discovery unclear

---

## 2. Proposed Architecture

### 2.1 New Script Structure

#### **Core Modules**

**`MailboxDashboard.Config.psm1`** (New)
- Unified configuration loader
- Path resolution (relative → absolute)
- Auth mode detection
- Validation of required settings

**`MailboxDashboard.Common.psm1`** (New)
- Shared utilities:
  - `Resolve-MailboxPath` — path resolution for config paths
  - `Read-MailboxJSON` / `Write-MailboxJSON` — consistent JSON I/O
  - `Write-FailureDiagnostic` — failure-only logging (script, line number, local variables, error record)
  - `Write-ExportAudit` — one line per JSON write: record count, destination file, source of the data
  - `Write-Stage` / `Write-Item` — colour-coded console progress (current operation, current mailbox/file)
  - `Convert-ExoSize` — centralized size conversion (fixes storage bug)
  - `Test-MailboxJSON` — schema validation
  - `Repair-MailboxJSON` — data cleanup and fixing

#### **Authentication Module**

**`Invoke-MailboxDashboardAuth.ps1`** (New - replaces Get-ExchangeOnlineAccessToken.ps1 integration)
- Interactive auth menu:
  ```
  ╔════════════════════════════════════╗
  ║  MailboxDashboard Authentication   ║
  ╠════════════════════════════════════╣
  ║  1) Certificate (AppOnly)          ║
  ║  2) Interactive (OAuth/PKCE)       ║
  ║  3) Delegated (User token)         ║
  ║  4) Use configured default         ║
  ║  Q) Quit                           ║
  ╚════════════════════════════════════╝
  ```
- Integrates graph.auth.lite for interactive
- Supports environment variable overrides
- Stores token securely in session

#### **Collection Scripts (Refactored)**

**`Collect-ExchangeOnlineMailboxes.ps1`** (Refactor of HistoryCollector.ps1)
- Single responsibility: query Exchange Online and append to history.json
- Inputs:
  - Config file
  - Mailbox CSV
  - Optional timestamp override
  - Optional batch size
- Outputs:
  - Appends to history.json
  - Returns collection metadata

**`Merge-CollectionResults.ps1`** (Refactor of MergeJSON.ps1)
- Single responsibility: merge threaded job outputs
- Inputs:
  - Temp directory with thread job JSONs
  - Target history.json location
- Outputs:
  - Merged history.json
  - Merge report (success/failure counts)

**`Generate-MailboxSnapshot.ps1`** (Refactor of Extract-HotData.ps1)
- Single responsibility: extract latest snapshot from history
- Inputs:
  - history.json
  - Optional filters (mailbox, date range)
- Outputs:
  - data.json (latest snapshot)
  - Metadata (snapshot timestamp, record count)

#### **Orchestrators**

**`Invoke-MailboxDashboardCollection.ps1`** (New - replaces Update-MailboxDashboard.ps1)
- Main entry point
- Prompts for auth mode (if not configured)
- Connects to Exchange Online
- Orchestrates collection → merge (if threaded) → snapshot generation
- Validates output JSON
- Options:
  - `-SingleThread` — Direct collection (no thread jobs)
  - `-Threaded` — Use thread jobs (faster for large mailbox sets)
  - `-SkipValidation` — Skip JSON validation (not recommended)
  - `-TestData` — Use synthetic data instead of Exchange Online

**`Initialize-MailboxDashboard.ps1`** (New)
- First-time setup script
- Creates folder structure
- Registers Entra app (calls Register-EntraApp.ps1)
- Creates mailbox CSV template
- Initializes configuration
- Validates permissions

#### **Validation & Testing**

**`Test-MailboxDashboardJSON.ps1`** (New)
- Validates JSON schema
- Pre-validation: Check CSV before collection
- Post-validation: Check generated JSON files
- Options:
  - `-Repair` — Attempt to fix invalid records
  - `-Cull` — Remove invalid records
  - `-Strict` — Fail on any error (no repair)
- Outputs:
  - Validation report
  - Fixed JSON file (if repair enabled)
  - Error log

**`New-MailboxDashboardTestData.ps1`** (New)
- Generates synthetic mailbox data
- Creates demo-data.json and demo-history.json
- Customizable:
  - Number of mailboxes
  - Date range
  - Data variance
- Used for dashboard UI testing without Exchange connection

#### **Deployment & Setup**

**`Deploy-MailboxDashboard.ps1`** (Enhance existing)
- Updated to work with new script structure
- Uses unified config
- Validates all scripts parse
- Copies to deployment location

**`Register-EntraApp.ps1`** (Keep, minor updates)
- Now called by Initialize-MailboxDashboard.ps1
- Updated to work with new config structure

### 2.2 Unified Configuration Structure

**File**: `Collector/Config/dashboardConfig.json`

```json
{
  "Version": "2.0",
  "Organization": "tenant-id-or-domain",
  "AppID": "public-client-app-id",
  "ClientSecret": "app-secret-for-cert-auth",
  "Thumbprint": "certificate-thumbprint",
  "UserPrincipalName": "admin@tenant.onmicrosoft.com",
  
  "Authentication": {
    "Mode": "Certificate|Interactive|Delegated|Auto",
    "Description": "If 'Auto', menu is shown at runtime. Otherwise, use specified mode."
  },
  
  "Paths": {
    "MailboxesCsv": "../Mailboxes/mailboxes.csv",
    "HistoryJson": "../Web/history.json",
    "DataJson": "../Web/data.json",
    "DemoDataJson": "../Web/demo-data.json",
    "DemoHistoryJson": "../Web/demo-history.json",
    "TempDirectory": "./Temp",
    "ThreadJobsDirectory": "./Temp/ThreadJobs",
    "LogDirectory": "./Logs"
  },
  
  "Collection": {
    "BatchSize": 50,
    "MaxHistorySamples": 365,
    "UseThreading": true,
    "ThreadCount": 10
  },
  
  "Thresholds": {
    "CriticalPercent": 94.0,
    "WarningPercent": 85.0
  },
  
  "Validation": {
    "PreValidateCSV": true,
    "PostValidateJSON": true,
    "AutoRepairErrors": false,
    "CullInvalidRecords": true
  },
  
  "Logging": {
    "Enabled": true,
    "LogFile": "./Logs/failures.log",
    "ExportAuditFile": "./Logs/exports.log",
    "IncludeVariables": true
  },

  "Console": {
    "ShowProgress": true,
    "UseColour": true,
    "ShowPerItem": true
  }
}
```

### 2.3 Data Flow (Optimized)

```
┌─────────────────────────────────────────────────────────────┐
│ User Executes: Invoke-MailboxDashboardCollection.ps1       │
└────────────────────┬────────────────────────────────────────┘
                     ↓
         ┌───────────────────────┐
         │ Load dashboardConfig  │
         └────────────┬──────────┘
                      ↓
         ┌───────────────────────┐
         │ Select Auth Mode      │ ← Interactive menu (if Auto)
         │ (Certificate/         │
         │  Interactive/         │
         │  Delegated)           │
         └────────────┬──────────┘
                      ↓
         ┌───────────────────────┐
         │ Validate Mailbox CSV  │ ← Test-MailboxDashboardJSON
         └────────────┬──────────┘
                      ↓
         ┌───────────────────────┐
         │ Connect to Exchange   │
         │ Online (via selected  │
         │ auth mode)            │
         └────────────┬──────────┘
                      ↓
         ╔═══════════════════════╗
         ║ Collection Method?    ║
         ╚═══┬═════════════════╤═╝
             │                 │
        ┌────▼────────────┐   ┌▼──────────────────┐
        │ Single-Threaded │   │ Multi-Threaded    │
        │ (smaller sets)  │   │ (large mailbox    │
        └────┬────────────┘   │  sets, faster)    │
             │                └┬──────────────────┘
             │                 │
             ▼                 ▼
    ┌────────────────────────────────────┐
    │ Collect-ExchangeOnlineMailboxes    │
    │ Appends to history.json            │
    │ Outputs collection metadata        │
    └────────┬───────────────────────────┘
             │
        [If Threaded]
             │
             ▼
    ┌────────────────────────────────────┐
    │ Merge-CollectionResults.ps1        │
    │ Combines Temp/ThreadJobs/*.json    │
    └────────┬───────────────────────────┘
             │
             ▼
    ┌────────────────────────────────────┐
    │ Test-MailboxDashboardJSON          │
    │ Validates history.json schema      │
    │ (Repairs if configured)            │
    └────────┬───────────────────────────┘
             │
             ▼
    ┌────────────────────────────────────┐
    │ Generate-MailboxSnapshot.ps1       │
    │ Extracts latest snapshot           │
    │ Outputs data.json                  │
    └────────┬───────────────────────────┘
             │
             ▼
    ┌────────────────────────────────────┐
    │ Test-MailboxDashboardJSON          │
    │ Validates data.json schema         │
    │ (Final check)                      │
    └────────┬───────────────────────────┘
             │
             ▼
    ┌────────────────────────────────────┐
    │ Success! Dashboard ready           │
    │ Output: Web/data.json              │
    │         Web/history.json           │
    │         Collection report          │
    └────────────────────────────────────┘
```

---

## 3. Implementation Roadmap

### Phase 1: Foundation (Weeks 1-2)
- [ ] Create `MailboxDashboard.Config.psm1` — unified config loading
- [ ] Create `MailboxDashboard.Common.psm1` — shared utilities
- [ ] Update `dashboardConfig.json` with new schema
- [ ] Create `Invoke-MailboxDashboardAuth.ps1` — auth menu
- [ ] **Validation**: All modules parse without errors

### Phase 2: Collection Refactoring (Weeks 3-4)
- [ ] Refactor → `Collect-ExchangeOnlineMailboxes.ps1`
- [ ] Refactor → `Merge-CollectionResults.ps1`
- [ ] Refactor → `Generate-MailboxSnapshot.ps1`
- [ ] Create `Test-MailboxDashboardJSON.ps1` — validator
- [ ] **Validation**: Each script standalone-runnable; relative paths work

### Phase 3: Orchestration (Week 5)
- [ ] Create `Invoke-MailboxDashboardCollection.ps1` — main orchestrator
- [ ] Create `Initialize-MailboxDashboard.ps1` — setup wizard
- [ ] Enhance `Deploy-MailboxDashboard.ps1`
- [ ] **Validation**: Full end-to-end flow with test data

### Phase 4: Testing & Documentation (Week 6)
- [ ] Create `New-MailboxDashboardTestData.ps1` — synthetic data generator
- [ ] Write operational guide (deployment + troubleshooting)
- [ ] Write migration guide for existing users
- [ ] Test with real tenant (if available)
- [ ] **Validation**: All error cases handled; comprehensive logging

### Phase 5: Cleanup (Week 7)
- [ ] Rename old scripts to `.legacy.ps1`
- [ ] Move new scripts to `Collector/`
- [ ] Remove obsolete code
- [ ] Final validation on clean clone

---

## 4. Authentication Menu Design

### Authentication Modes Supported

1. **Certificate (AppOnly)**
   - Required: Organization, AppID, ClientSecret
   - No user interaction needed
   - Suitable for: Scheduled tasks, CI/CD

2. **Interactive (OAuth/PKCE)**
   - Required: Organization, AppID
   - Uses graph.auth.lite library
   - Opens WAM browser window (needs user attention)
   - Suitable for: Manual collection runs

3. **Delegated (Implicit)**
   - Required: Organization, UserPrincipalName
   - Uses existing user token from Connect-MgGraph
   - Suitable for: Already-authenticated admin sessions

### Configuration Options

- **Mode = "Certificate"** — Auto-use cert auth (no menu)
- **Mode = "Interactive"** — Auto-use interactive auth (no menu)
- **Mode = "Delegated"** — Auto-use delegated auth (no menu)
- **Mode = "Auto"** — Show interactive menu at runtime

### Menu Behavior

```powershell
if ($config.Authentication.Mode -eq "Auto") {
    Show-MailboxDashboardAuthMenu
    $selectedMode = Read-Host "Select authentication mode (1-4, or Q to quit)"
    # Process selection
} else {
    # Use configured mode directly
}
```

---

## 5. JSON Validation & Repair Strategy

### Pre-Collection Validation (CSV)
- Required columns: `PrimarySMTPAddress` or `Mailbox`
- No duplicate mailboxes
- Valid email format (if validating SMTP)

### Post-Collection Validation (JSON)

#### Schema Checks
- **history.json**: Must have `MailboxHistory[]` array with `ExchangeGuid` and `Samples[]`
- **data.json**: Must have `Mailboxes[]` array with latest snapshot

#### Data Integrity Checks
- ExchangeGuid not null
- Quota > 0
- Usage <= Quota
- LastLogon valid datetime (or null)
- PermissionCount >= 0

#### Repair Options
- **Cull Mode** — Remove invalid records, log warnings
- **Repair Mode** — Attempt to fix (e.g., calculate missing quota from usage)
- **Strict Mode** — Fail immediately on any error

#### Example Repair Logic
```powershell
# If Usage > Quota, set Usage = Quota
if ($mailbox.Usage -gt $mailbox.Quota) {
    $mailbox.Usage = $mailbox.Quota
    $repairLog.Add("Clamped usage for $($mailbox.PrimarySmtpAddress) to quota")
}

# If Quota = 0, skip record
if ($mailbox.Quota -eq 0) {
    $culledCount++
    continue
}
```

---

## 6. Test Data Generation

### `New-MailboxDashboardTestData.ps1` Output

Creates realistic but synthetic mailbox data:

```json
{
  "GeneratedUtc": "2026-09-07T12:00:00Z",
  "MailboxHistory": [
    {
      "ExchangeGuid": "00000000-0000-0000-0000-000000000001",
      "PrimarySmtpAddress": "test.user.001@contoso.com",
      "Samples": [
        {
          "Timestamp": "2026-09-06T12:00:00Z",
          "MailboxSize": 1073741824,
          "Quota": 10737418240,
          "PermissionCount": 2,
          "ArchiveSize": 536870912,
          "ItemCount": 50000,
          "LastLogon": "2026-09-06T10:30:00Z"
        }
      ]
    }
  ]
}
```

### Customization Options
- `-MailboxCount 100` — Generate 100 synthetic mailboxes
- `-DateRange (30 days)` — Include 30 days of historical samples
- `-Variance 0.2` — 20% random variance in generated metrics
- `-OutputPath "./Web/demo-data.json"` — Where to save

---

## 7. Validation & Error Handling

### Script Parsing Validation
All scripts must pass PowerShell parser:
```powershell
Get-ChildItem .\Collector\*.ps1 | ForEach-Object {
    $null = [System.Management.Automation.Language.Parser]::ParseInput(
        (Get-Content $_.FullName -Raw),
        [ref]$null,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        Write-Error "Parse error in $($_.Name): $parseErrors"
    }
}
```

### Config Validation
- All required keys present
- All paths (relative) resolvable
- Auth mode recognized
- Thresholds in valid range (0-100%)

### Relative Path Handling
All paths in config are relative to script directory:
```powershell
# In config:
"MailboxesCsv": "../Mailboxes/mailboxes.csv"

# Resolved at runtime:
$resolvedPath = Join-Path -Path $scriptDir -ChildPath $configPath
$resolvedPath = Resolve-Path -LiteralPath $resolvedPath
```

### Error Recovery
- Graceful handling of missing files
- Clear error messages with remediation steps
- Atomic operations where possible (transaction-like behavior for JSON updates)
- Backups before destructive operations

### Logging (Failure-Only)

No verbose/info/debug levels. Nothing is written while a run succeeds. When a
terminating or caught error occurs, one diagnostic block is emitted to the console
and appended to `Logs/failures.log`:

- Script file name and the **line number** that threw
- The failing command/statement text
- The **current local variables** in that scope (name = value, secrets redacted)
- The full error record: message, exception type, and stack trace

Implemented once in `MailboxDashboard.Common.psm1` and called from `catch` blocks:

```powershell
try {
    # ... work ...
}
catch {
    Write-FailureDiagnostic -ErrorRecord $_ -Scope (Get-Variable -Scope 1)
    throw
}
```

Example output:

```
[FAILURE] 2026-09-07 14:22:31Z
Script : Collect-ExchangeOnlineMailboxes.ps1
Line   : 214
Command: Get-EXOMailboxStatistics -Identity $mailbox.PrimarySmtpAddress
Error  : The operation couldn't be performed because object 'x@y.com' couldn't be found.
Type   : Microsoft.Exchange.Configuration.Tasks.ManagementObjectNotFoundException
Variables:
  $mailbox           = @{PrimarySmtpAddress=x@y.com; ExchangeGuid=0000...}
  $batchIndex        = 3
  $historyJsonPath   = C:\REPO\MailboxDashboard\Web\history.json
  $ClientSecret      = ***REDACTED***
StackTrace:
  at <ScriptBlock>, Collect-ExchangeOnlineMailboxes.ps1: line 214
```

Redaction applies to any variable whose name matches `secret|password|token|thumbprint|clientsecret`.

### Export Audit (JSON writes)

Every JSON export is recorded — this is the one thing logged on a successful run.
`Write-MailboxJSON` calls `Write-ExportAudit` after each successful write, emitting a
single line to the console and appending it to `Logs/exports.log`:

- **how many records** were written (and, where meaningful, added vs. updated vs. unchanged)
- **which file** they were written to
- **where they came from** — the calling script plus the input source (Exchange Online,
  a thread-job temp directory, `history.json`, or the test-data generator)

```
[EXPORT] 2026-09-07 14:31:02Z  Collect-ExchangeOnlineMailboxes.ps1
  Records : 412 written (388 updated, 24 added)
  Target  : ..\Web\history.json
  Source  : Exchange Online (Get-EXOMailbox / Get-EXOMailboxStatistics)

[EXPORT] 2026-09-07 14:31:04Z  Merge-CollectionResults.ps1
  Records : 412 merged from 9 thread-job files
  Target  : ..\Web\history.json
  Source  : .\Temp\ThreadJobs\*.json

[EXPORT] 2026-09-07 14:31:05Z  Generate-MailboxSnapshot.ps1
  Records : 412 written
  Target  : ..\Web\data.json
  Source  : ..\Web\history.json (latest sample per ExchangeGuid)
```

A write of 0 records is still logged — a silent empty export is the failure mode this
is meant to catch.

### Console Output (colour-coded)

The operator watching the run should always be able to see **what stage is running** and
**which record is being processed**, without reading a log file. Two helpers in
`MailboxDashboard.Common.psm1` produce all console output, so colour use stays consistent
across every script.

| Colour | Used for |
|--------|----------|
| **Cyan** | Stage banner — the operation now starting (Authenticating, Collecting, Merging, Validating, Generating snapshot) |
| **White / Gray** | Per-item detail — the mailbox, batch, or file currently being processed |
| **Green** | Stage completed successfully; export audit lines |
| **Yellow** | Non-fatal issues — skipped mailbox, repaired record, culled record, retry |
| **Red** | Failure diagnostic block |
| **Magenta** | Auth menu and prompts requiring user attention (e.g. "a sign-in window is opening") |
| **DarkGray** | Counts, timings, and totals |

Example of a run in progress:

```
=== Authenticating =====================================  (cyan)
  Mode: Interactive (OAuth/PKCE)                          (magenta)
  A sign-in window is opening - it may appear behind this  (magenta)
  Connected as aaron.francis.admin@hpwqld.onmicrosoft.com  (green)

=== Collecting mailboxes ===============================  (cyan)
  Source: ..\Mailboxes\mailboxes.csv (412 mailboxes)      (darkgray)
  [  1/412] alice.smith@contoso.com                        (gray)
  [  2/412] bob.jones@contoso.com                          (gray)
  [  3/412] carol.white@contoso.com  SKIPPED - not found   (yellow)
  ...
  [412/412] zoe.young@contoso.com                          (gray)
  Collected 411 of 412 in 00:04:12                         (darkgray)

=== Validating history.json ============================  (cyan)
  Repaired 3 records (usage clamped to quota)              (yellow)
  Culled 1 record (quota = 0)                              (yellow)
  Schema OK                                                (green)

=== Generating snapshot ================================  (cyan)
[EXPORT] 410 records -> ..\Web\data.json                   (green)
         Source: ..\Web\history.json                       (darkgray)

Done in 00:04:26                                           (green)
```

Per-item lines are throttled for large mailbox sets (progress every N items rather than
every item) when `ShowPerItem` is false. All colour output is suppressed entirely when
`Console.UseColour` is false, so scheduled-task and redirected output stays clean.

---

## 8. Expected Deliverables

### New Files
1. `Collector/MailboxDashboard.Config.psm1`
2. `Collector/MailboxDashboard.Common.psm1`
3. `Collector/Invoke-MailboxDashboardAuth.ps1`
4. `Collector/Collect-ExchangeOnlineMailboxes.ps1`
5. `Collector/Merge-CollectionResults.ps1`
6. `Collector/Generate-MailboxSnapshot.ps1`
7. `Collector/Invoke-MailboxDashboardCollection.ps1`
8. `Collector/Initialize-MailboxDashboard.ps1`
9. `Collector/Test-MailboxDashboardJSON.ps1`
10. `Collector/New-MailboxDashboardTestData.ps1`
11. `Collector/Config/dashboardConfig.json` (updated schema)

### Updated Files
1. `Collector/Deploy-MailboxDashboard.ps1` (enhanced)
2. `Collector/Register-EntraApp.ps1` (minor updates for new config)

### Archived/Legacy Files (renamed)
1. `Collector/Update-MailboxDashboard.ps1.legacy`
2. `Collector/Start-HistoryCollectorThreaded.ps1.legacy`
3. `Collector/HistoryCollector.ps1.legacy`
4. `Collector/MergeJSON.ps1.legacy`
5. `Collector/Extract-HotData.ps1.legacy`

### Documentation
1. `OPTIMIZATION_SUMMARY.md` — Technical overview of changes
2. `DEPLOYMENT_GUIDE.md` — Step-by-step deployment for operators
3. `MIGRATION_GUIDE.md` — Path from old scripts to new structure
4. `TROUBLESHOOTING.md` — Common issues and fixes

---

## 9. Success Criteria

- ✅ All new scripts parse without errors
- ✅ Unified config drives all behavior (no hardcoded paths)
- ✅ Auth menu works for all three modes
- ✅ Collection pipeline completes end-to-end with test data
- ✅ JSON validation catches schema errors
- ✅ Repair mode fixes common issues
- ✅ Relative paths resolve correctly on different machines
- ✅ Full operational documentation complete
- ✅ Old scripts functional but marked as legacy
- ✅ Zero loss of functionality from original scripts

---

## 10. Implementation Constraints

1. **Backward Compatibility**: Old scripts remain functional during transition
2. **PowerShell 5.1+**: No PS7-only syntax in core modules
3. **No External Dependencies**: Beyond already-required modules (ExchangeOnlineManagement, Microsoft.Graph.Authentication, graph.auth.lite)
4. **Relative Paths**: All config paths must resolve from script directory
5. **Secure Handling**: ClientSecret not logged; auth tokens stored securely in memory only

---

## Approval Checklist

**Ready to proceed with implementation?**

- [ ] Plan reviewed and understood
- [ ] Phased approach acceptable
- [ ] File naming and structure agreed
- [ ] Config schema finalized
- [ ] Auth menu design approved
- [ ] Validation strategy acceptable

**If approved**, implementation will begin with Phase 1 (Foundation) as outlined above.

---

**Questions or Changes?** Please review and provide feedback before proceeding.

