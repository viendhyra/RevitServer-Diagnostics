# Revit Server Diagnostics and Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the existing Revit Server diagnostic script into a tested, OS-independent diagnostic and explicitly gated repair toolkit published at `viendhyra/RevitServer-Diagnostics`.

**Architecture:** Keep a small public entry script and split read-only collectors, mutation functions, and reporting into three PowerShell modules. Every mutation produces a backup record before execution, verifies its result, and appends a rollback operation. Windows Update Agent is the authority for update availability; installed CLR versions are evidence only.

**Tech Stack:** Windows PowerShell 5.1, PowerShell modules (`.psm1`), Pester 5, IIS WebAdministration, Windows Update Agent COM API, CIM/WMI, Sysinternals ProcDump.

**Spec:** `docs/superpowers/specs/2026-08-25-revit-server-diagnostics-design.md`

## Global Constraints

- Diagnostic mode must make no system changes.
- Windows PowerShell 5.1 syntax is the minimum compatibility target.
- Do not hard-code an update for `Windows Server 2022 21H2` or infer update availability from `clr.dll 4.8.4795.0`.
- All repair operations require elevation, an explicit repair switch, backup-before-write ordering, verification, and a rollback record when rollback is reliable.
- `-Force` may suppress confirmation but must never bypass signature, compatibility, backup, or `-SnapshotConfirmed` gates.
- Generic `-Repair` must not alter DNS, NetBIOS, Defender exclusions, Dynamic IP Restrictions, machine-wide GC settings, or install Revit Server versions.
- Remote `Run.ps1` defaults to diagnostic-only mode.

---

### Task 1: Project skeleton and immutable result contracts

**Files:**
- Create: `RevitServer-Diag.ps1`
- Create: `src/Diagnostics.psm1`
- Create: `src/Repairs.psm1`
- Create: `src/Reporting.psm1`
- Create: `tests/Contracts.Tests.ps1`
- Create: `tests/Invoke-Tests.ps1`

**Interfaces:**
- Produces: `New-DiagnosticFinding`, `New-RepairResult`, and `Invoke-RevitServerDiagnostics`.
- Result status values: `AlreadyCompliant`, `Changed`, `Failed`, `Skipped`, `RebootRequired`.

- [ ] **Step 1: Write contract tests**

```powershell
Describe 'Result contracts' {
    It 'creates a finding without mutating the machine' {
        $r = New-DiagnosticFinding -Level WARN -Code 'TEST' -Message 'sample'
        $r.Level | Should -Be 'WARN'
        $r.Code | Should -Be 'TEST'
    }
    It 'rejects an unknown repair status' {
        { New-RepairResult -Name X -Status Unknown } | Should -Throw
    }
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1`

Expected: FAIL because the modules/functions do not exist.

- [ ] **Step 3: Implement the result contracts and entry-point parameter sets**

```powershell
function New-RepairResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('AlreadyCompliant','Changed','Failed','Skipped','RebootRequired')]
        [string]$Status,
        [string]$Message = '',
        [string]$Rollback = ''
    )
    [pscustomobject]@{ Name=$Name; Status=$Status; Message=$Message; Rollback=$Rollback }
}
```

Define the main switches exactly as in the spec: `Repair`, `SetupProcDump`, `InstallUpdates`, `UpgradeNet481`, `SnapshotConfirmed`, `DisableDynamicIpRestrictions`, `AutoReboot`, and `Force`.

- [ ] **Step 4: Run contract tests and verify GREEN**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1`

Expected: all `Contracts.Tests.ps1` tests pass.

- [ ] **Step 5: Commit**

```bash
git add RevitServer-Diag.ps1 src tests
git commit -m "feat: add diagnostic toolkit skeleton"
```

### Task 2: OS-independent .NET and Windows Update diagnostics

**Files:**
- Modify: `src/Diagnostics.psm1`
- Create: `tests/UpdateDiagnostics.Tests.ps1`

**Interfaces:**
- Produces: `Get-DotNetFrameworkState`, `Get-WindowsUpdateState`, `Find-ApplicableUpdates`, and `Select-RelevantUpdates`.
- `Find-ApplicableUpdates` returns update objects supplied by Windows Update Agent and never synthetic title matches.

- [ ] **Step 1: Write failing update-classification tests**

```powershell
Describe 'Update diagnostics' {
    It 'does not fail solely for CLR 4.8.4795.0' {
        $state = Get-DotNetFrameworkState -Release 528449 -ClrVersion '4.8.4795.0'
        $state.Health | Should -Not -Be 'FAIL'
    }
    It 'classifies an applicable .NET update from update metadata' {
        $updates = @([pscustomobject]@{
            Title='2026-08 Cumulative Update for .NET Framework 3.5 and 4.8'
            Categories=@('.NET'); IsInstalled=$false; KBArticleIDs=@('KB1234567')
        })
        @(Select-RelevantUpdates -Updates $updates -Kind DotNet).Count | Should -Be 1
    }
    It 'returns no update when WUA returns none' {
        @(Select-RelevantUpdates -Updates @() -Kind DotNet).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Verify RED**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/UpdateDiagnostics.Tests.ps1`

Expected: FAIL because update functions are undefined.

- [ ] **Step 3: Implement registry/file evidence and WUA query**

Use `HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full`, both Framework CLR paths, Windows Update policy keys, pending reboot keys, and `Microsoft.Update.Session`. Query `IsInstalled=0 and Type='Software' and IsHidden=0`. Preserve WUA update objects and normalize only fields required by reporting.

`Get-DotNetFrameworkState` must return `InstalledFamily`, `Release`, `ClrFiles`, and `Health='INFO'` unless a concrete absence/corruption condition exists.

- [ ] **Step 4: Verify GREEN and static constraint**

Run:

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/UpdateDiagnostics.Tests.ps1
if (Select-String -Path src/*.psm1,RevitServer-Diag.ps1 -Pattern 'Cumulative Update.*21H2') { exit 1 }
```

Expected: tests pass; static check returns no match.

- [ ] **Step 5: Commit**

```bash
git add src/Diagnostics.psm1 tests/UpdateDiagnostics.Tests.ps1
git commit -m "feat: detect applicable updates without OS hardcoding"
```

### Task 3: IIS, Revit Server, crash, and network collectors

**Files:**
- Modify: `src/Diagnostics.psm1`
- Create: `tests/Diagnostics.Tests.ps1`

**Interfaces:**
- Produces: `Get-IisState`, `Get-RevitServerState`, `Get-CrashTimeline`, `Get-CrashCorrelations`, `Get-ProcessInjectionState`, and `Get-NetworkState`.
- Consumes: result contracts from Task 1.

- [ ] **Step 1: Write collector tests with injected data**

```powershell
Describe 'Crash grouping' {
    It 'does not count AppError and WAS rows as two root-cause crashes' {
        $events = @(
            [pscustomobject]@{Type='AppError-1000';Time=[datetime]'2026-08-21 09:15:01';Module='clr.dll';Code='0xc0000005';Offset='0x4b2bb1'},
            [pscustomobject]@{Type='WAS-5011';Time=[datetime]'2026-08-21 09:15:02';Pool='RevitServerAppPool2024'}
        )
        $timeline = Get-CrashTimeline -Events $events
        $timeline.RootCauseCrashCount | Should -Be 1
    }
}
Describe 'Missing endpoints' {
    It 'extracts the Revit year without assuming a fixed version list' {
        $r = Get-MissingEndpointRequest -Message "The service '/RevitServerAdminRESTService2026/AdminRESTService.svc' does not exist."
        $r.Year | Should -Be '2026'
    }
}
```

- [ ] **Step 2: Verify RED**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/Diagnostics.Tests.ps1`

Expected: FAIL because collectors are undefined.

- [ ] **Step 3: Port and isolate the uploaded diagnostic logic**

Port environment/disks, IIS pools/sites/modules/features, discovered Revit Server instances/services/data/config/logs/endpoints, event IDs 1023/1000/5011, scheduled tasks, AutoSync, VSS/Defender/update timing, `w3wp` modules, CLR profiler variables, DNS/NetBIOS/adapter state, and dump inventory into read-only functions. Add `-Events`/`-InputObject` parameters to parsers so tests do not require Windows event logs.

- [ ] **Step 4: Verify GREEN**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/Diagnostics.Tests.ps1`

Expected: all collector/parser tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Diagnostics.psm1 tests/Diagnostics.Tests.ps1
git commit -m "feat: add Revit Server and crash collectors"
```

### Task 4: Backup, rollback, and low-risk repair engine

**Files:**
- Modify: `src/Repairs.psm1`
- Create: `tests/RepairSafety.Tests.ps1`

**Interfaces:**
- Produces: `New-RepairContext`, `Backup-IisConfiguration`, `Add-RollbackOperation`, `Complete-RollbackScript`, `Repair-RevitServices`, `Repair-RevitIisPools`, `Install-RevitIisFeatures`, and `Register-MicrosoftUpdate`.

- [ ] **Step 1: Write safety/order tests**

```powershell
Describe 'Repair safety' {
    It 'backs up before changing an IIS pool' {
        Mock Backup-IisConfiguration { $script:order += 'backup' }
        Mock Set-RevitPoolConfiguration { $script:order += 'write' }
        $script:order=@()
        Repair-RevitIisPools -Context (New-TestRepairContext) -Pools @('RevitServerAppPool2024')
        $script:order | Should -Be @('backup','write')
    }
    It 'does not alter a non-Revit pool' {
        Mock Set-RevitPoolConfiguration {}
        Repair-RevitIisPools -Context (New-TestRepairContext) -Pools @('DefaultAppPool')
        Should -Invoke Set-RevitPoolConfiguration -Times 0
    }
}
```

- [ ] **Step 2: Verify RED**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/RepairSafety.Tests.ps1`

Expected: FAIL because repair functions are undefined.

- [ ] **Step 3: Implement idempotent repairs**

Create one backup directory per run. Back up `applicationHost.config`, relevant registry keys, pool/service/update state, and .NET versions. Set only discovered Revit pools to `autoStart=$true`, `startMode=AlwaysRunning`, `idleTimeout=00:00:00`, `rapidFailProtection=$true`, and `rapidFailProtectionMaxCrashes=20`. Start stopped Revit sites/pools and automatic Autodesk/Revit services. Install only missing feature names already declared required by the diagnostic collector. Verify every property after writing.

- [ ] **Step 4: Generate and parse rollback script**

`Complete-RollbackScript` writes only operations appended during the run, in reverse order, with quoted literal paths. Parse it with `[scriptblock]::Create((Get-Content -Raw $path))` in the test.

- [ ] **Step 5: Verify GREEN**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/RepairSafety.Tests.ps1`

Expected: all tests pass and generated rollback script parses.

- [ ] **Step 6: Commit**

```bash
git add src/Repairs.psm1 tests/RepairSafety.Tests.ps1
git commit -m "feat: add backed-up Revit repair engine"
```

### Task 5: ProcDump acquisition and crash-dump configuration

**Files:**
- Modify: `src/Repairs.psm1`
- Create: `tests/ProcDump.Tests.ps1`

**Interfaces:**
- Produces: `Install-VerifiedProcDump` and `Enable-W3wpCrashDumps`.

- [ ] **Step 1: Write signature and command tests**

```powershell
Describe 'ProcDump safety' {
    It 'rejects a non-Microsoft signature' {
        { Assert-MicrosoftSignature -Signature ([pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Example'}}) } | Should -Throw
    }
    It 'uses the supported postmortem full-dump form' {
        (New-ProcDumpInstallArguments -DumpPath 'C:\Dumps') -join ' ' | Should -Be '-accepteula -ma -i C:\Dumps'
    }
}
```

- [ ] **Step 2: Verify RED**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/ProcDump.Tests.ps1`

Expected: FAIL because functions are undefined.

- [ ] **Step 3: Implement official download, verification, and registration**

Download only `https://download.sysinternals.com/files/Procdump.zip`, validate ZIP extraction boundaries, validate `Get-AuthenticodeSignature` status and Microsoft subject, check dump disk free space, preserve AeDebug state, then invoke `procdump64.exe -accepteula -ma -i <folder>`. Verify registration by rereading AeDebug. Print the optional targeted monitor command `-accepteula -ma -e -w w3wp.exe <folder>` without launching it automatically.

- [ ] **Step 4: Verify GREEN**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/ProcDump.Tests.ps1`

Expected: all tests pass with download/process calls mocked.

- [ ] **Step 5: Commit**

```bash
git add src/Repairs.psm1 tests/ProcDump.Tests.ps1
git commit -m "feat: configure verified ProcDump crash capture"
```

### Task 6: Explicit update installation and .NET Framework 4.8.1 gate

**Files:**
- Modify: `src/Repairs.psm1`
- Create: `tests/UpdatesRepair.Tests.ps1`

**Interfaces:**
- Produces: `Install-ApplicableUpdates`, `Test-Net481Compatibility`, and `Install-Net481Upgrade`.
- Consumes: applicable WUA objects from Task 2 and repair context from Task 4.

- [ ] **Step 1: Write confirmation and compatibility tests**

```powershell
Describe 'Update repair gates' {
    It 'refuses 4.8.1 without snapshot confirmation' {
        { Install-Net481Upgrade -InstallerPath 'C:\ndp481.exe' -SnapshotConfirmed:$false } | Should -Throw
    }
    It 'does not install updates in diagnostic mode' {
        Mock Invoke-WuaInstall {}
        Install-ApplicableUpdates -Updates @() -WhatIf
        Should -Invoke Invoke-WuaInstall -Times 0
    }
}
```

- [ ] **Step 2: Verify RED**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/UpdatesRepair.Tests.ps1`

Expected: FAIL because repair functions are undefined.

- [ ] **Step 3: Implement WUA download/install results**

Accept only WUA-returned updates selected by the administrator. Present title, KB, size, categories, and EULA state. Require `ShouldContinue` unless `-Force`. Record per-update download/install result code, HRESULT, and reboot requirement. Do not scrape Microsoft Update Catalog or synthesize `.msu` URLs.

- [ ] **Step 4: Implement 4.8.1 compatibility/signature/snapshot gates**

Accept a local installer path or download URL resolved from the official Microsoft redirect embedded in configuration. Require compatible server OS evidence, valid Microsoft signature, `SnapshotConfirmed=$true`, sufficient disk, and explicit confirmation. Invoke silently only after logging the pre-upgrade Release key and CLR versions. Return `RebootRequired` when appropriate.

- [ ] **Step 5: Verify GREEN**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/UpdatesRepair.Tests.ps1`

Expected: all tests pass with COM/process operations mocked.

- [ ] **Step 6: Commit**

```bash
git add src/Repairs.psm1 tests/UpdatesRepair.Tests.ps1
git commit -m "feat: add gated update and net481 installation"
```

### Task 7: Dynamic IP Restrictions scoped experiment

**Files:**
- Modify: `src/Diagnostics.psm1`
- Modify: `src/Repairs.psm1`
- Create: `tests/DynamicIpRestrictions.Tests.ps1`

**Interfaces:**
- Produces: `Get-DynamicIpRestrictionState` and `Disable-RevitDynamicIpRestrictions`.

- [ ] **Step 1: Write scope tests**

```powershell
Describe 'Dynamic IP Restrictions' {
    It 'targets only discovered Revit application paths' {
        $plan = New-DynamicIpRestrictionPlan -Applications @('/RevitServerAdminRESTService2024','/OtherApp')
        $plan.Targets | Should -Be @('/RevitServerAdminRESTService2024')
    }
    It 'requires its dedicated switch' {
        (Get-RequestedRepairs -Repair -DisableDynamicIpRestrictions:$false) | Should -Not -Contain 'DynamicIpRestrictions'
    }
}
```

- [ ] **Step 2: Verify RED**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/DynamicIpRestrictions.Tests.ps1`

Expected: FAIL because scoped plan functions are undefined.

- [ ] **Step 3: Implement scoped backup/change/retest**

Read effective `system.webServer/security/dynamicIpSecurity` configuration for each discovered Revit application. Back up IIS first, set `denyAction`/enabled state only at the selected Revit scope, restart only affected pools when IIS requires it, retest endpoints, and generate an exact restore operation.

- [ ] **Step 4: Verify GREEN and commit**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/DynamicIpRestrictions.Tests.ps1`

```bash
git add src tests/DynamicIpRestrictions.Tests.ps1
git commit -m "feat: add scoped dynamic IP restriction experiment"
```

### Task 8: Reporting, launcher, documentation, and integration verification

**Files:**
- Modify: `src/Reporting.psm1`
- Modify: `RevitServer-Diag.ps1`
- Create: `Run.ps1`
- Create: `README.md`
- Create: `CHANGELOG.md`
- Create: `LICENSE`
- Create: `.gitignore`
- Create: `tests/Integration.Tests.ps1`

**Interfaces:**
- Produces: HTML, CSV, JSON, transcript, proposed repair plan, applied repair results, and `Rollback.ps1`.
- `Run.ps1` downloads and invokes the main script without repair switches by default.

- [ ] **Step 1: Write integration tests**

```powershell
Describe 'Diagnostic-only integration' {
    It 'plans no mutations without repair switches' {
        $request = Get-RequestedRepairs
        @($request).Count | Should -Be 0
    }
    It 'keeps remote launcher diagnostic-only by default' {
        $text = Get-Content "$PSScriptRoot/../Run.ps1" -Raw
        $text | Should -Not -Match '-Repair\b|-InstallUpdates\b|-UpgradeNet481\b'
    }
}
```

- [ ] **Step 2: Verify RED**

Run: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/Integration.Tests.ps1`

Expected: FAIL until orchestrator, reporting, and launcher are complete.

- [ ] **Step 3: Implement report orchestration and launcher**

Wire collectors into the original nine diagnostic sections, preserve existing CSV names where practical, add `summary.json`, `repair-plan.json`, `repair-results.csv`, and generated rollback output. `Run.ps1` downloads `RevitServer-Diag.ps1` and the `src` directory to a timestamped local directory, prints the source URL/path, and invokes only diagnostic mode.

- [ ] **Step 4: Write Russian README and changelog**

Document the public one-line command, recommended inspect-then-run command, all switches, permissions, backup/rollback, ProcDump privacy/disk warnings, update behavior, .NET 4.8.1 snapshot requirement, reports, examples, and non-automated limitations.

- [ ] **Step 5: Run complete verification**

Run:

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1
[scriptblock]::Create((Get-Content -Raw ./RevitServer-Diag.ps1)) | Out-Null
[scriptblock]::Create((Get-Content -Raw ./Run.ps1)) | Out-Null
Get-ChildItem ./src/*.psm1 | ForEach-Object { [scriptblock]::Create((Get-Content -Raw $_.FullName)) | Out-Null }
```

Expected: all Pester tests pass and every PowerShell file parses.

- [ ] **Step 6: Verify repository content and remote command**

Fetch `README.md`, `Run.ps1`, and `RevitServer-Diag.ps1` from the GitHub default branch after publishing. Confirm the raw launcher URL returns the committed content and that the launcher contains no default repair switch.

- [ ] **Step 7: Commit**

```bash
git add .
git commit -m "docs: publish Revit Server diagnostics toolkit"
```
