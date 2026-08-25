# Revit Server GUI and Live Pool Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Russian WPF application for Windows PowerShell 5.1 that runs the existing Revit Server diagnostics, monitors only Revit/IIS application-pool failures while the window is open, and exposes confirmed manual repairs, Rapid-Fail = 20, and ProcDump setup.

**Architecture:** Extract reusable orchestration from the current CLI, then place a WPF controller above the existing diagnostics, repairs, and reporting modules. A pool-monitor module normalizes EventLogWatcher records and five-second IIS state transitions; the GUI owns and disposes the runspace, watchers, timer, and session CSV.

**Tech Stack:** Windows PowerShell 5.1, WPF/XAML, `System.Diagnostics.Eventing.Reader.EventLogWatcher`, `System.Windows.Threading.DispatcherTimer`, WebAdministration, Pester 5.5, GitHub Actions `windows-latest`.

**Spec:** `docs/superpowers/specs/2026-08-25-gui-live-pool-monitor-design.md`

## Global Constraints

- The monitor exists only while the WPF window is open; do not install a service, tray agent, scheduled task, or startup entry.
- The live log includes only Revit Server application-pool state changes, `w3wp.exe` crashes, and related WAS/W3SVC-WP events.
- Never repair automatically; every mutation requires a user button and a confirmation dialog.
- Keep Windows PowerShell 5.1 compatibility and do not require PowerShell 7, .NET SDK, a web server, or a third-party GUI framework.
- Set Rapid-Fail maximum failures to exactly `20` and keep Rapid-Fail Protection enabled.
- Download ProcDump only from Sysinternals and retain Microsoft Authenticode verification.
- Do not upload reports or dumps.
- Preserve all existing CLI parameters and diagnostic-only default behavior.
- Save `Run.ps1` and `Run-GUI.ps1` as UTF-8 without BOM; save other Russian PowerShell source files as UTF-8 with BOM for Windows PowerShell 5.1.

## File Structure

- Create `src/Orchestration.psm1`: reusable full-diagnostic workflow, progress callback, structured result.
- Create `src/PoolMonitor.psm1`: target-pool filtering, event normalization, transition de-duplication, bounded log, watcher lifecycle.
- Create `src/GuiController.psm1`: GUI state, background diagnostic runspace, manual-action plans, lifecycle cleanup.
- Create `ui/MainWindow.xaml`: WPF layout and styles only.
- Create `RevitServer-GUI.ps1`: composition root, event bindings, dialogs, and window lifecycle.
- Create `Run-GUI.ps1`: BOM-free direct GitHub loader for GUI files.
- Modify `RevitServer-Diag.ps1`: delegate diagnostic collection to orchestration while preserving CLI switches and output.
- Modify `Run.ps1`: remove BOM and make the loader testable without changing behavior.
- Modify `src/Diagnostics.psm1`: safe ACL projection and progress-friendly data access.
- Modify `src/Repairs.psm1`: expose focused plans/functions for pool start, base settings, and Rapid-Fail.
- Modify `README.md`: GUI command, screens, permissions, monitoring limits, dump warning.
- Create `tests/Loader.Tests.ps1`, `tests/Orchestration.Tests.ps1`, `tests/PoolMonitor.Tests.ps1`, `tests/GuiController.Tests.ps1`, `tests/Gui.Tests.ps1`.
- Modify `tests/Diagnostics.Tests.ps1`, `tests/Repairs.Tests.ps1`, and `tests/Integration.Tests.ps1` for regressions and compatibility.

---

### Task 1: Fix direct-loader BOM and empty ACL regressions

**Files:**
- Modify: `Run.ps1:1`
- Modify: `src/Diagnostics.psm1:318-335`
- Create: `tests/Loader.Tests.ps1`
- Modify: `tests/Diagnostics.Tests.ps1`

**Interfaces:**
- Produces: `Get-NetworkServiceAclState -Acl <Object>` returning `{ HasNetworkService: bool; Rights: string }`.
- Produces: BOM-free `Run.ps1` that remains valid when its downloaded text is passed to `Invoke-Expression`.

- [ ] **Step 1: Write the failing loader and ACL tests**

```powershell
# tests/Loader.Tests.ps1
Describe 'Direct launchers' {
    It 'stores Run.ps1 without a UTF-8 BOM' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '../Run.ps1'))
        @($bytes[0],$bytes[1],$bytes[2]) -join ',' | Should -Not -Be '239,187,191'
    }
}

# append inside tests/Diagnostics.Tests.ps1
Describe 'Data directory ACL projection' {
    It 'returns an empty rights string when NETWORK SERVICE has no ACE' {
        $acl = [pscustomobject]@{ Access = @(
            [pscustomobject]@{ IdentityReference='BUILTIN\Administrators'; FileSystemRights='FullControl' }
        ) }
        $state = Get-NetworkServiceAclState -Acl $acl
        $state.HasNetworkService | Should -BeFalse
        $state.Rights | Should -Be ''
    }
}
```

- [ ] **Step 2: Run focused tests and confirm both fail**

Run on Windows PowerShell 5.1:

```powershell
Invoke-Pester .\tests\Loader.Tests.ps1,.\tests\Diagnostics.Tests.ps1 -Output Detailed
```

Expected: loader test reports BOM bytes and ACL test reports `Get-NetworkServiceAclState` is unknown.

- [ ] **Step 3: Implement the ACL helper and use explicit projection**

```powershell
function Get-NetworkServiceAclState {
    [CmdletBinding()]
    param([AllowNull()]$Acl)
    $matches = @()
    if ($null -ne $Acl) {
        $matches = @($Acl.Access | Where-Object {
            [string]$_.IdentityReference -match 'NETWORK SERVICE|СЕТЕВАЯ СЛУЖБА'
        })
    }
    $rights = @($matches | ForEach-Object { [string]$_.FileSystemRights })
    [pscustomobject]@{
        HasNetworkService = [bool]($matches.Count -gt 0)
        Rights = $rights -join '; '
    }
}
```

Replace the direct `$networkService.FileSystemRights` read with:

```powershell
$aclState = Get-NetworkServiceAclState -Acl $acl
HasNetworkService = $aclState.HasNetworkService
NetworkServiceRights = $aclState.Rights
```

Export `Get-NetworkServiceAclState` from `Diagnostics.psm1`. Rewrite `Run.ps1` as UTF-8 without BOM without changing its statements.

- [ ] **Step 4: Run focused tests and the whole suite**

```powershell
.\tests\Invoke-Tests.ps1
```

Expected: all existing and new tests pass; no `PropertyNotFoundStrict` occurs for an empty ACL match.

- [ ] **Step 5: Commit the regression fixes**

```bash
git add Run.ps1 src/Diagnostics.psm1 tests/Loader.Tests.ps1 tests/Diagnostics.Tests.ps1
git commit -m "fix: handle direct loader BOM and empty ACL"
```

### Task 2: Add reusable diagnostic orchestration

**Files:**
- Create: `src/Orchestration.psm1`
- Create: `tests/Orchestration.Tests.ps1`
- Modify: `RevitServer-Diag.ps1`
- Modify: `tests/Integration.Tests.ps1`

**Interfaces:**
- Consumes: public functions in `Diagnostics.psm1` and `Reporting.psm1`.
- Produces: `Invoke-RevitServerDiagnostic -Days <int> -OutDir <string> -SkipEndpointTest:<bool> -ProgressAction <scriptblock>`.
- Returns: `{ ReportPath; HtmlPath; Snapshot; Findings; AvailableUpdates }`.
- Progress callback receives `{ Percent: int; Stage: string; Message: string }`.

- [ ] **Step 1: Write failing orchestration contract tests**

```powershell
BeforeAll { Import-Module (Join-Path $PSScriptRoot '../src/Orchestration.psm1') -Force }

Describe 'Diagnostic orchestration contract' {
    It 'publishes monotonic progress and returns the report contract' {
        $steps = New-Object Collections.ArrayList
        $result = Invoke-RevitServerDiagnostic -Days 1 -OutDir $TestDrive -SkipEndpointTest `
            -Collectors ([ordered]@{
                Environment={ [pscustomobject]@{Computer='TEST';OS='Windows';Disks=@()} }
                DotNet={ [pscustomobject]@{Framework='4.8';Release=528449;ClrVersion='4.8.4795.0';Files=@()} }
                Updates={ [pscustomobject]@{State=[pscustomobject]@{MicrosoftUpdateRegistered=$true};Available=@()} }
                Iis={ [pscustomobject]@{Available=$true;Pools=@();Sites=@();Applications=@()} }
                Revit={ [pscustomobject]@{Instances=@();Services=@()} }
                Crashes={ [pscustomobject]@{RootCauseCrashCount=0;Events=@();Signatures=@()} }
                Network={ [pscustomobject]@{Adapters=@()} }
                Profiler={ [pscustomobject]@{InjectionSuspected=$false;Variables=@()} }
                Extended={ [pscustomobject]@{Features=@();EndpointTests=@();LogErrors=@();MissingEndpoints=@();TaskCorrelations=@();DumpState=[pscustomobject]@{AeDebugDebugger='x';WerDumpType=2};NativeModules=@();Binaries=@();DataDirectories=@();W3wpModules=@();RelatedEvents=@()} }
            }) -ProgressAction { param($p) [void]$steps.Add($p.Percent) }
        $result.Snapshot.Environment.Computer | Should -Be 'TEST'
        $result.ReportPath | Should -Not -BeNullOrEmpty
        @($steps) | Should -Be (@($steps) | Sort-Object)
    }
}
```

- [ ] **Step 2: Run the orchestration test and confirm it fails**

```powershell
Invoke-Pester .\tests\Orchestration.Tests.ps1 -Output Detailed
```

Expected: FAIL because `Orchestration.psm1` or `Invoke-RevitServerDiagnostic` does not exist.

- [ ] **Step 3: Implement the orchestration shell and collector seam**

```powershell
function Publish-DiagnosticProgress {
    param([scriptblock]$Action,[int]$Percent,[string]$Stage,[string]$Message)
    if ($null -ne $Action) {
        & $Action ([pscustomobject]@{Percent=$Percent;Stage=$Stage;Message=$Message})
    }
}

function Invoke-RevitServerDiagnostic {
    [CmdletBinding()]
    param(
        [ValidateRange(1,3650)][int]$Days=400,
        [Parameter(Mandatory)][string]$OutDir,
        [switch]$SkipEndpointTest,
        [scriptblock]$ProgressAction,
        [Collections.IDictionary]$Collectors
    )
    if ($null -eq $Collectors) { $Collectors = New-DefaultDiagnosticCollectors -Days $Days -SkipEndpointTest:$SkipEndpointTest }
    $values = [ordered]@{}
    $names = @($Collectors.Keys)
    for ($index=0; $index -lt $names.Count; $index++) {
        $name = [string]$names[$index]
        Publish-DiagnosticProgress $ProgressAction ([int](5 + 80*$index/[math]::Max(1,$names.Count))) $name "Выполняется: $name"
        try { $values[$name] = & $Collectors[$name] }
        catch { $values[$name] = New-CollectorFailure -Name $name -Exception $_.Exception }
    }
    $result = Complete-DiagnosticResult -Values $values -OutDir $OutDir
    Publish-DiagnosticProgress $ProgressAction 100 'Complete' 'Проверка завершена'
    $result
}
```

Implement `New-DefaultDiagnosticCollectors`, `New-CollectorFailure`, and `Complete-DiagnosticResult` by moving the current read-only collection and finding construction from `RevitServer-Diag.ps1`. Keep repairs in the CLI after the returned diagnostic result. Do not change existing CLI parameter names.

- [ ] **Step 4: Add CLI compatibility assertions**

Append to `tests/Integration.Tests.ps1`:

```powershell
It 'keeps every published CLI switch' {
    $command = Get-Command (Join-Path $PSScriptRoot '../RevitServer-Diag.ps1')
    @($command.Parameters.Keys) | Should -Contain 'Repair'
    @($command.Parameters.Keys) | Should -Contain 'SetupProcDump'
    @($command.Parameters.Keys) | Should -Contain 'InstallUpdates'
    @($command.Parameters.Keys) | Should -Contain 'UpgradeNet481'
    @($command.Parameters.Keys) | Should -Contain 'DisableDynamicIpRestrictions'
}
```

- [ ] **Step 5: Run orchestration, integration, and full tests**

```powershell
Invoke-Pester .\tests\Orchestration.Tests.ps1,.\tests\Integration.Tests.ps1 -Output Detailed
.\tests\Invoke-Tests.ps1
```

Expected: orchestration progress is monotonic; CLI switches remain; full suite passes.

- [ ] **Step 6: Commit orchestration**

```bash
git add src/Orchestration.psm1 RevitServer-Diag.ps1 tests/Orchestration.Tests.ps1 tests/Integration.Tests.ps1
git commit -m "refactor: expose reusable diagnostic orchestration"
```

### Task 3: Build pure pool-monitor state and event classification

**Files:**
- Create: `src/PoolMonitor.psm1`
- Create: `tests/PoolMonitor.Tests.ps1`

**Interfaces:**
- Produces: `Test-RevitPoolName -Name <string> -> bool`.
- Produces: `ConvertTo-PoolMonitorEvent -Record <Object> -TargetPools <string[]> -> event or null`.
- Produces: `Update-PoolStateTransitions -Previous <IDictionary> -Current <Object[]> -Now <datetime> -> { State; Events }`.
- Produces: `Add-BoundedMonitorEvent -Buffer <ArrayList> -Event <Object> -Maximum 1000`.

- [ ] **Step 1: Write failing classification and transition tests**

```powershell
BeforeAll { Import-Module (Join-Path $PSScriptRoot '../src/PoolMonitor.psm1') -Force }

Describe 'Pool monitor classification' {
    It 'accepts only Revit or ModelService pools' {
        Test-RevitPoolName 'RevitServerAppPool2024' | Should -BeTrue
        Test-RevitPoolName 'ModelService2022' | Should -BeTrue
        Test-RevitPoolName 'DefaultAppPool' | Should -BeFalse
    }

    It 'normalizes a related WAS failure' {
        $record = [pscustomobject]@{TimeCreated=[datetime]'2026-08-25 14:00';Id=5011;ProviderName='Microsoft-Windows-WAS';Message='Application pool RevitServerAppPool2024 failed communication with w3wp.exe'}
        $event = ConvertTo-PoolMonitorEvent -Record $record -TargetPools @('RevitServerAppPool2024')
        $event.Level | Should -Be 'FAIL'
        $event.Pool | Should -Be 'RevitServerAppPool2024'
    }

    It 'drops unrelated events' {
        $record = [pscustomobject]@{TimeCreated=Get-Date;Id=5011;ProviderName='Microsoft-Windows-WAS';Message='DefaultAppPool stopped'}
        ConvertTo-PoolMonitorEvent -Record $record -TargetPools @('RevitServerAppPool2024') | Should -BeNullOrEmpty
    }

    It 'emits a row only when state changes' {
        $previous = @{RevitServerAppPool2024='Started'}
        $result = Update-PoolStateTransitions -Previous $previous -Current @([pscustomobject]@{Name='RevitServerAppPool2024';State='Stopped'}) -Now ([datetime]'2026-08-25 14:01')
        $result.Events.Count | Should -Be 1
        $again = Update-PoolStateTransitions -Previous $result.State -Current @([pscustomobject]@{Name='RevitServerAppPool2024';State='Stopped'}) -Now ([datetime]'2026-08-25 14:02')
        $again.Events.Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run tests and confirm the module is missing**

```powershell
Invoke-Pester .\tests\PoolMonitor.Tests.ps1 -Output Detailed
```

Expected: FAIL because exported monitor functions are unavailable.

- [ ] **Step 3: Implement target filtering and normalized event objects**

```powershell
function Test-RevitPoolName {
    param([Parameter(Mandatory)][string]$Name)
    $Name -match '(?i)Revit|ModelService'
}

function New-PoolMonitorEvent {
    param([datetime]$Time,[string]$Level,[string]$Pool,[string]$Type,[int]$EventId,[string]$Provider,[string]$Message,[string]$Details)
    [pscustomobject]@{Time=$Time;Level=$Level;Pool=$Pool;Type=$Type;EventId=$EventId;Provider=$Provider;Message=$Message;Details=$Details}
}
```

Implement record matching by checking each exact target-pool name in the record message. Classify Application Error 1000 and WAS 5002/5009/5011 as `FAIL`, stopping/stopped as `WARN`, and starts/state recovery as `INFO`. `Update-PoolStateTransitions` copies the input dictionary, compares each target state, and emits `PoolStateChanged` only on a difference.

- [ ] **Step 4: Add and test the 1000-row buffer**

```powershell
It 'keeps the newest 1000 monitor rows' {
    $buffer = New-Object Collections.ArrayList
    1..1005 | ForEach-Object {
        [void](Add-BoundedMonitorEvent -Buffer $buffer -Event ([pscustomobject]@{Sequence=$_}) -Maximum 1000)
    }
    $buffer.Count | Should -Be 1000
    $buffer[0].Sequence | Should -Be 6
}
```

Implement by appending the event and removing index zero while `Count -gt Maximum`.

- [ ] **Step 5: Run focused and full tests, then commit**

```powershell
Invoke-Pester .\tests\PoolMonitor.Tests.ps1 -Output Detailed
.\tests\Invoke-Tests.ps1
git add src/PoolMonitor.psm1 tests/PoolMonitor.Tests.ps1
git commit -m "feat: classify live Revit pool events"
```

### Task 4: Add watcher, timer, CSV, and deterministic cleanup

**Files:**
- Modify: `src/PoolMonitor.psm1`
- Modify: `tests/PoolMonitor.Tests.ps1`

**Interfaces:**
- Consumes: Task 3 normalization and transition functions.
- Produces: `Start-PoolMonitorSession -TargetPools <string[]> -CsvPath <string> -EventAction <scriptblock> -StateProvider <scriptblock>`.
- Produces: session object with `Watchers`, `Timer`, `Buffer`, `CsvPath`, `Stop()` semantics through `Stop-PoolMonitorSession -Session`.

- [ ] **Step 1: Write failing lifecycle tests with injected resources**

```powershell
It 'disposes every watcher and stops the timer' {
    $watcher1 = [pscustomobject]@{Enabled=$true;Disposed=$false}
    $watcher1 | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
    $watcher2 = [pscustomobject]@{Enabled=$true;Disposed=$false}
    $watcher2 | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
    $timer = [pscustomobject]@{IsEnabled=$true}
    $timer | Add-Member ScriptMethod Stop { $this.IsEnabled=$false }
    $session = [pscustomobject]@{Watchers=@($watcher1,$watcher2);Timer=$timer;Subscriptions=@()}
    Stop-PoolMonitorSession -Session $session
    $watcher1.Enabled | Should -BeFalse
    $watcher1.Disposed | Should -BeTrue
    $watcher2.Disposed | Should -BeTrue
    $timer.IsEnabled | Should -BeFalse
}
```

- [ ] **Step 2: Run the lifecycle test and confirm failure**

```powershell
Invoke-Pester .\tests\PoolMonitor.Tests.ps1 -Output Detailed
```

Expected: FAIL because `Stop-PoolMonitorSession` is unavailable.

- [ ] **Step 3: Implement lifecycle cleanup first**

```powershell
function Stop-PoolMonitorSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    if ($null -ne $Session.Timer) { $Session.Timer.Stop() }
    foreach ($watcher in @($Session.Watchers)) {
        $watcher.Enabled = $false
        $watcher.Dispose()
    }
    foreach ($subscription in @($Session.Subscriptions)) {
        Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue
        Remove-Job -Id $subscription.Id -Force -ErrorAction SilentlyContinue
    }
}
```

- [ ] **Step 4: Implement session startup with injectable factories**

`Start-PoolMonitorSession` accepts optional `WatcherFactory` and `TimerFactory` scriptblocks for tests. Production defaults create one EventLogWatcher for Application and one for System, subscribe to `EventRecordWritten`, and create a five-second DispatcherTimer. Each normalized event is added to the bounded buffer, appended with `Export-Csv -Append -NoTypeInformation -Encoding UTF8`, then passed to `EventAction`.

Use exact event-log queries:

```powershell
$applicationQuery = "*[System[(EventID=1000) and Provider[@Name='Application Error']]]"
$systemQuery = "*[System[(EventID=5002 or EventID=5009 or EventID=5011) and (Provider[@Name='Microsoft-Windows-WAS'] or Provider[@Name='Microsoft-Windows-W3SVC-WP'])]]"
```

- [ ] **Step 5: Verify cleanup, CSV creation, and full suite**

Add a factory-backed test that sends one normalized event, asserts one CSV data row, calls stop twice, and asserts no exception. Run:

```powershell
Invoke-Pester .\tests\PoolMonitor.Tests.ps1 -Output Detailed
.\tests\Invoke-Tests.ps1
```

Expected: all monitor and existing tests pass; double cleanup is safe.

- [ ] **Step 6: Commit monitor lifecycle**

```bash
git add src/PoolMonitor.psm1 tests/PoolMonitor.Tests.ps1
git commit -m "feat: monitor pool events while GUI is open"
```

### Task 5: Expose focused manual pool-repair commands

**Files:**
- Modify: `src/Repairs.psm1`
- Modify: `tests/Repairs.Tests.ps1`

**Interfaces:**
- Produces: `New-PoolActionPreview -Pools <Object[]> -Action Start|BaseSettings|RapidFail`.
- Produces: `Invoke-PoolAction -Context <Object> -Pools <Object[]> -Action <string> -Confirm:<bool>`.
- Preview rows return `{ Pool; Setting; Current; Desired }`.

- [ ] **Step 1: Write failing focused-action tests**

```powershell
Describe 'Focused GUI pool actions' {
    BeforeAll {
        $script:pools = @(
            [pscustomobject]@{Name='RevitServerAppPool2024';State='Stopped';AutoStart=$false;StartMode='OnDemand';IdleTimeoutMinutes=20;RapidFailEnabled=$false;RapidFailMaxCrashes=5},
            [pscustomobject]@{Name='DefaultAppPool';State='Stopped';AutoStart=$false;StartMode='OnDemand';IdleTimeoutMinutes=20;RapidFailEnabled=$false;RapidFailMaxCrashes=5}
        )
    }

    It 'previews Rapid-Fail 20 only for target pools and enables protection' {
        $rows = @(New-PoolActionPreview -Pools $script:pools -Action RapidFail)
        @($rows.Pool | Sort-Object -Unique) | Should -Be @('RevitServerAppPool2024')
        @($rows | Where-Object Setting -eq 'RapidFailEnabled').Desired | Should -Be 'True'
        @($rows | Where-Object Setting -eq 'RapidFailMaxCrashes').Desired | Should -Be '20'
    }
}
```

- [ ] **Step 2: Run the focused test and confirm missing functions**

```powershell
Invoke-Pester .\tests\Repairs.Tests.ps1 -Output Detailed
```

- [ ] **Step 3: Implement exact previews and reuse verified writes**

```powershell
function New-PoolActionPreview {
    [CmdletBinding()]
    param([object[]]$Pools,[ValidateSet('Start','BaseSettings','RapidFail')][string]$Action)
    foreach ($pool in @($Pools | Where-Object Name -match '(?i)Revit|ModelService')) {
        switch ($Action) {
            'Start' { if ($pool.State -ne 'Started') { [pscustomobject]@{Pool=$pool.Name;Setting='State';Current=$pool.State;Desired='Started'} } }
            'BaseSettings' {
                [pscustomobject]@{Pool=$pool.Name;Setting='AutoStart';Current=[string]$pool.AutoStart;Desired='True'}
                [pscustomobject]@{Pool=$pool.Name;Setting='StartMode';Current=$pool.StartMode;Desired='AlwaysRunning'}
                [pscustomobject]@{Pool=$pool.Name;Setting='IdleTimeoutMinutes';Current=[string]$pool.IdleTimeoutMinutes;Desired='0'}
            }
            'RapidFail' {
                [pscustomobject]@{Pool=$pool.Name;Setting='RapidFailEnabled';Current=[string]$pool.RapidFailEnabled;Desired='True'}
                [pscustomobject]@{Pool=$pool.Name;Setting='RapidFailMaxCrashes';Current=[string]$pool.RapidFailMaxCrashes;Desired='20'}
            }
        }
    }
}
```

`Invoke-PoolAction` must back up IIS once, apply only previewed settings, re-read IIS through `Get-IisState`, and return `Changed` only when every desired value is observed. Reuse `New-RepairContext`, `Invoke-RevitBasicRepair`, and rollback helpers rather than duplicating command construction.

- [ ] **Step 4: Run repair and full suites**

```powershell
Invoke-Pester .\tests\Repairs.Tests.ps1 -Output Detailed
.\tests\Invoke-Tests.ps1
```

Expected: `DefaultAppPool` never appears; Rapid-Fail is enabled and exactly 20.

- [ ] **Step 5: Commit focused repairs**

```bash
git add src/Repairs.psm1 tests/Repairs.Tests.ps1
git commit -m "feat: expose confirmed pool repair actions"
```

### Task 6: Build the GUI controller and background diagnostic runner

**Files:**
- Create: `src/GuiController.psm1`
- Create: `tests/GuiController.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-RevitServerDiagnostic`, `Start-PoolMonitorSession`, `Stop-PoolMonitorSession`, `New-PoolActionPreview`, and `Invoke-PoolAction`.
- Produces: `New-GuiState`, `Start-GuiDiagnostic`, `Complete-GuiDiagnostic`, `Start-GuiPoolMonitor`, `Stop-GuiPoolMonitor`, `Close-GuiController`.
- `New-GuiState` returns observable collections for Findings, Pools, and MonitorEvents plus Busy, Progress, Stage, LastReport, and MonitorRunning.

- [ ] **Step 1: Write failing state and cleanup tests**

```powershell
BeforeAll { Import-Module (Join-Path $PSScriptRoot '../src/GuiController.psm1') -Force }

Describe 'GUI controller state' {
    It 'starts in safe idle mode' {
        $state = New-GuiState
        $state.Busy | Should -BeFalse
        $state.MonitorRunning | Should -BeFalse
        $state.Findings.Count | Should -Be 0
    }

    It 'closes the monitor and diagnostic runner idempotently' {
        $monitor = [pscustomobject]@{Stopped=$false}
        $runner = [pscustomobject]@{Disposed=$false}
        $controller = [pscustomobject]@{Monitor=$monitor;DiagnosticRunner=$runner}
        Mock Stop-GuiPoolMonitor { $Controller.Monitor.Stopped=$true }
        Mock Stop-GuiDiagnostic { $Controller.DiagnosticRunner.Disposed=$true }
        Close-GuiController -Controller $controller
        Close-GuiController -Controller $controller
        $monitor.Stopped | Should -BeTrue
        $runner.Disposed | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run tests and confirm missing module/functions**

```powershell
Invoke-Pester .\tests\GuiController.Tests.ps1 -Output Detailed
```

- [ ] **Step 3: Implement GUI state with WPF-friendly collections**

```powershell
function New-GuiState {
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        Busy=$false;Progress=0;Stage='Готово';LastReport='';MonitorRunning=$false
        Findings=(New-Object Collections.ObjectModel.ObservableCollection[object])
        Pools=(New-Object Collections.ObjectModel.ObservableCollection[object])
        MonitorEvents=(New-Object Collections.ObjectModel.ObservableCollection[object])
    }
}
```

- [ ] **Step 4: Implement one active background runspace**

`Start-GuiDiagnostic` creates `[PowerShell]::Create()`, imports the modules in that runspace, invokes `Invoke-RevitServerDiagnostic`, and stores the async handle. It rejects a second call while `Busy` is true. Progress enters a thread-safe `ConcurrentQueue[object]`; the WPF timer drains the queue on the UI thread. `Complete-GuiDiagnostic` calls `EndInvoke`, disposes PowerShell/runspace, updates collections, and resets Busy in `finally`.

Use this return shape:

```powershell
[pscustomobject]@{ PowerShell=$powershell; AsyncResult=$async; ProgressQueue=$queue; Started=Get-Date }
```

- [ ] **Step 5: Add tests for busy rejection and failure recovery**

Inject `RunnerFactory` into `Start-GuiDiagnostic`. Assert that a second start throws `Диагностика уже выполняется`, and a runner exception returns Busy to false while adding one `FAIL` finding with code `GUI_DIAGNOSTIC_FAILED`.

- [ ] **Step 6: Run controller and full tests, then commit**

```powershell
Invoke-Pester .\tests\GuiController.Tests.ps1 -Output Detailed
.\tests\Invoke-Tests.ps1
git add src/GuiController.psm1 tests/GuiController.Tests.ps1
git commit -m "feat: add nonblocking GUI controller"
```

### Task 7: Create and validate the WPF interface

**Files:**
- Create: `ui/MainWindow.xaml`
- Create: `RevitServer-GUI.ps1`
- Create: `tests/Gui.Tests.ps1`

**Interfaces:**
- Consumes: Task 6 controller functions and GUI state.
- Produces: named controls `NavHome`, `NavDiagnostic`, `NavMonitor`, `NavRepairs`, `NavReports`, `RunDiagnosticButton`, `StartMonitorButton`, `StopMonitorButton`, `StartPoolsButton`, `BaseSettingsButton`, `RapidFailButton`, `SetupProcDumpButton`, `OpenDumpsButton`, `OpenReportButton`, `FindingsGrid`, `PoolsGrid`, `MonitorGrid`, `ProgressBar`, `ProgressText`, `MainFrame`.

- [ ] **Step 1: Write failing XAML contract tests**

```powershell
Describe 'WPF layout contract' {
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework
        [xml]$script:xaml = Get-Content (Join-Path $PSScriptRoot '../ui/MainWindow.xaml') -Raw
    }
    It 'declares every controller control name exactly once' {
        $required = @('NavHome','NavDiagnostic','NavMonitor','NavRepairs','NavReports','RunDiagnosticButton','StartMonitorButton','StopMonitorButton','StartPoolsButton','BaseSettingsButton','RapidFailButton','SetupProcDumpButton','OpenDumpsButton','OpenReportButton','FindingsGrid','PoolsGrid','MonitorGrid','ProgressBar','ProgressText','MainFrame')
        $names = @($script:xaml.SelectNodes('//*[@Name]') | ForEach-Object { $_.Name })
        foreach ($name in $required) { @($names | Where-Object { $_ -eq $name }).Count | Should -Be 1 }
    }
    It 'loads through XamlReader' {
        $reader = New-Object Xml.XmlNodeReader $script:xaml
        { [Windows.Markup.XamlReader]::Load($reader) } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run GUI tests and confirm missing XAML**

```powershell
Invoke-Pester .\tests\Gui.Tests.ps1 -Output Detailed
```

- [ ] **Step 3: Create the WPF shell and five views**

Create a 1100×700 minimum window using Segoe UI, a 220-pixel blue navigation column, and a content Grid named `MainFrame`. Define shared styles for navigation buttons, primary buttons, cards, status chips, DataGrids, and confirmation buttons. Put each view in a named Grid and toggle `Visibility` from navigation handlers. Bind Findings, Pools, and MonitorEvents to their DataGrids.

Use status colors exactly:

```xml
<SolidColorBrush x:Key="StatusOk" Color="#16A34A"/>
<SolidColorBrush x:Key="StatusWarn" Color="#D97706"/>
<SolidColorBrush x:Key="StatusFail" Color="#DC2626"/>
<SolidColorBrush x:Key="Accent" Color="#0369A1"/>
<SolidColorBrush x:Key="Surface" Color="#FFFFFF"/>
<SolidColorBrush x:Key="Background" Color="#F1F5F9"/>
```

- [ ] **Step 4: Implement composition and event bindings**

`RevitServer-GUI.ps1` loads PresentationFramework, imports all modules, parses XAML, resolves every required named control, builds controller/state, and connects:

- navigation buttons → view visibility;
- diagnostic button → `Start-GuiDiagnostic`;
- monitor buttons → start/stop monitor;
- repair buttons → preview table, confirmation `MessageBox`, then focused action;
- ProcDump button → warning/confirmation then existing verified installer;
- open buttons → `Start-Process` on an existing validated path;
- window Closing → `Close-GuiController`.

Disable mutation buttons unless the process is elevated and target pools exist. Show the exact reason in each disabled button tooltip.

- [ ] **Step 5: Run GUI, integration, and full tests**

```powershell
Invoke-Pester .\tests\Gui.Tests.ps1,.\tests\Integration.Tests.ps1 -Output Detailed
.\tests\Invoke-Tests.ps1
```

Expected: XAML loads on `windows-latest`, all names exist once, and every PowerShell file parses under Windows PowerShell 5.1.

- [ ] **Step 6: Commit the WPF interface**

```bash
git add ui/MainWindow.xaml RevitServer-GUI.ps1 tests/Gui.Tests.ps1
git commit -m "feat: add Revit Server WPF interface"
```

### Task 8: Add the direct GUI loader and user documentation

**Files:**
- Create: `Run-GUI.ps1`
- Modify: `tests/Loader.Tests.ps1`
- Modify: `README.md`

**Interfaces:**
- Produces: `Run-GUI.ps1` that downloads both entry points, five modules, and XAML into one timestamped temporary directory, then invokes `RevitServer-GUI.ps1`.

- [ ] **Step 1: Extend failing loader tests**

```powershell
It 'stores Run-GUI.ps1 without a UTF-8 BOM' {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '../Run-GUI.ps1'))
    @($bytes[0],$bytes[1],$bytes[2]) -join ',' | Should -Not -Be '239,187,191'
}

It 'downloads every GUI runtime file' {
    $text = Get-Content (Join-Path $PSScriptRoot '../Run-GUI.ps1') -Raw
    @('RevitServer-GUI.ps1','src/Diagnostics.psm1','src/Repairs.psm1','src/Reporting.psm1','src/Orchestration.psm1','src/PoolMonitor.psm1','src/GuiController.psm1','ui/MainWindow.xaml') | ForEach-Object {
        $text | Should -Match ([regex]::Escape($_))
    }
}
```

- [ ] **Step 2: Run loader tests and confirm failure**

```powershell
Invoke-Pester .\tests\Loader.Tests.ps1 -Output Detailed
```

- [ ] **Step 3: Implement the BOM-free GUI loader**

Use the existing `Run.ps1` download loop pattern, add `src` and `ui` directories, download the exact runtime list from `https://raw.githubusercontent.com/viendhyra/RevitServer-Diagnostics/main`, print the local directory, then call:

```powershell
& (Join-Path $target 'RevitServer-GUI.ps1')
```

- [ ] **Step 4: Document commands, permissions, monitoring scope, and dumps**

Add a GUI-first README section containing:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
irm https://raw.githubusercontent.com/viendhyra/RevitServer-Diagnostics/main/Run-GUI.ps1 | iex
```

State that monitoring starts only after the button is pressed, stops with the window, only pool-related events appear, fixes require confirmation, and full dumps may contain process-memory data and consume disk space.

- [ ] **Step 5: Run all tests and commit**

```powershell
.\tests\Invoke-Tests.ps1
git add Run-GUI.ps1 tests/Loader.Tests.ps1 README.md
git commit -m "docs: add direct GUI launch and usage"
```

### Task 9: Verify Windows behavior and publish the pull request

**Files:**
- Modify only if verification exposes a tested defect.

**Interfaces:**
- Consumes: complete GUI, loaders, tests, and GitHub workflow.
- Produces: a reviewable GitHub pull request targeting `main`.

- [ ] **Step 1: Run repository hygiene checks**

```bash
git diff main...HEAD --check
git status --short
```

Expected: no whitespace errors and no uncommitted files.

- [ ] **Step 2: Run the complete Windows PowerShell 5.1 suite**

```powershell
.\tests\Invoke-Tests.ps1
```

Expected: zero failed tests and `TestResults.xml` records all tests.

- [ ] **Step 3: Perform a Windows Server smoke test**

Run the GUI direct command, start monitoring, stop and restart one non-production Revit test pool, confirm the event appears within ten seconds, preview and apply Rapid-Fail, verify `enabled = true` and `maximumFailures = 20`, configure ProcDump, open the dump folder, stop monitoring, and close the window. Verify no application PowerShell process remains.

- [ ] **Step 4: Push the branch and inspect GitHub Actions**

Push `feature/gui-live-pool-monitor`, open a pull request titled `Добавить GUI и живой монитор пулов Revit Server`, and wait for the Windows PowerShell workflow to finish successfully.

- [ ] **Step 5: Review changed files and merge only a green PR**

Confirm the PR contains only the intended GUI, monitor, orchestration, regression fixes, tests, and documentation. Squash-merge after GitHub Actions reports success, then verify both raw launcher URLs resolve from `main`.

