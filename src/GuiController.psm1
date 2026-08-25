Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'PoolMonitor.psm1') -Force

function New-GuiState {
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        Busy=$false;Progress=0;Stage='Готово';LastReport='';LastReportFolder=''
        MonitorRunning=$false;ActiveProblemCount=0;LastCheck=$null
        Findings=(New-Object 'System.Collections.ObjectModel.ObservableCollection[object]')
        Pools=(New-Object 'System.Collections.ObjectModel.ObservableCollection[object]')
        MonitorEvents=(New-Object 'System.Collections.ObjectModel.ObservableCollection[object]')
    }
}

function Test-GuiAdministrator {
    [CmdletBinding()]
    param()
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        [bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

function New-GuiController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModuleRoot,
        [Parameter(Mandatory)][string]$ReportRoot,
        [scriptblock]$StopMonitorAction,
        [scriptblock]$StopDiagnosticAction
    )
    if ($null -eq $StopMonitorAction) { $StopMonitorAction = { param($c) Stop-GuiPoolMonitor -Controller $c } }
    if ($null -eq $StopDiagnosticAction) { $StopDiagnosticAction = { param($c) Stop-GuiDiagnostic -Controller $c } }
    [pscustomobject]@{
        State=(New-GuiState);ModuleRoot=$ModuleRoot;ReportRoot=$ReportRoot
        DiagnosticRunner=$null;Monitor=$null
        MonitorQueue=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
        StopMonitorAction=$StopMonitorAction;StopDiagnosticAction=$StopDiagnosticAction
        Closed=$false;IsAdministrator=(Test-GuiAdministrator)
    }
}

function Start-GuiDiagnostic {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Controller,[ValidateRange(1,3650)][int]$Days=400)
    if ($Controller.State.Busy) { throw 'Diagnostic is already running.' }
    $Controller.State.Busy = $true
    $Controller.State.Progress = 10
    $Controller.State.Stage = 'Выполняется диагностика...'
    try {
        $powerShell = [PowerShell]::Create()
        $scriptText = @'
param($ModulePath,$Days,$OutDir)
Import-Module $ModulePath -Force
Invoke-RevitServerDiagnostic -Days $Days -OutDir $OutDir
'@
        [void]$powerShell.AddScript($scriptText).AddArgument((Join-Path $Controller.ModuleRoot 'Orchestration.psm1')).AddArgument($Days).AddArgument($Controller.ReportRoot)
        $async = $powerShell.BeginInvoke()
        $Controller.DiagnosticRunner = [pscustomobject]@{PowerShell=$powerShell;AsyncResult=$async;Disposed=$false;Started=Get-Date}
        $Controller.DiagnosticRunner
    } catch {
        $Controller.State.Busy = $false
        $Controller.State.Progress = 0
        $Controller.State.Stage = 'Ошибка запуска диагностики'
        throw
    }
}

function Complete-GuiDiagnostic {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Controller)
    $runner = $Controller.DiagnosticRunner
    if ($null -eq $runner -or -not $runner.AsyncResult.IsCompleted) { return $false }
    try {
        $output = @($runner.PowerShell.EndInvoke($runner.AsyncResult))
        $result = @($output | Where-Object { $_.PSObject.Properties['Snapshot'] } | Select-Object -Last 1)
        if ($result.Count -eq 0) { throw 'Диагностика не вернула структурированный результат.' }
        $data = $result[0]
        $Controller.State.Findings.Clear()
        foreach ($finding in @($data.Findings)) { $Controller.State.Findings.Add($finding) }
        $Controller.State.Pools.Clear()
        foreach ($pool in @($data.Snapshot.Iis.Pools | Where-Object { $_.Name -match '(?i)Revit|ModelService' })) { $Controller.State.Pools.Add($pool) }
        $Controller.State.LastReport = [string]$data.HtmlPath
        $Controller.State.LastReportFolder = [string]$data.ReportPath
        $Controller.State.LastCheck = Get-Date
        $Controller.State.Progress = 100
        $Controller.State.Stage = 'Проверка завершена'
    } catch {
        $Controller.State.Findings.Add([pscustomobject]@{Time=Get-Date;Level='FAIL';Code='GUI_DIAGNOSTIC_FAILED';Message=$_.Exception.Message;Data=$null})
        $Controller.State.Stage = 'Проверка завершилась с ошибкой'
        $Controller.State.Progress = 0
    } finally {
        $runner.PowerShell.Dispose()
        $runner.Disposed = $true
        $Controller.DiagnosticRunner = $null
        $Controller.State.Busy = $false
    }
    $true
}

function Stop-GuiDiagnostic {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Controller)
    $runner = $Controller.DiagnosticRunner
    if ($null -eq $runner) { return }
    try { if (-not $runner.AsyncResult.IsCompleted) { $runner.PowerShell.Stop() } } catch { }
    try { $runner.PowerShell.Dispose() } catch { }
    if ($runner.PSObject.Properties['Disposed']) { $runner.Disposed = $true }
    $Controller.DiagnosticRunner = $null
    $Controller.State.Busy = $false
}

function Start-GuiPoolMonitor {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Controller,[Parameter(Mandatory)][string]$CsvPath)
    if ($Controller.State.MonitorRunning) { return $Controller.Monitor }
    $targets = @($Controller.State.Pools | ForEach-Object { [string]$_.Name })
    if ($targets.Count -eq 0) { throw 'Сначала выполните проверку: пулы Revit Server не найдены.' }
    $queue = $Controller.MonitorQueue
    $Controller.Monitor = Start-PoolMonitorSession -TargetPools $targets -CsvPath $CsvPath -EventAction { param($row) $queue.Enqueue($row) }
    $Controller.State.MonitorRunning = $true
    $Controller.Monitor
}

function Stop-GuiPoolMonitor {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Controller)
    if ($null -ne $Controller.Monitor) { Stop-PoolMonitorSession -Session $Controller.Monitor }
    $Controller.Monitor = $null
    $Controller.State.MonitorRunning = $false
}

function Sync-GuiQueues {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Controller)
    $item = $null
    while ($Controller.MonitorQueue.TryDequeue([ref]$item)) {
        $Controller.State.MonitorEvents.Add($item)
        while ($Controller.State.MonitorEvents.Count -gt 1000) { $Controller.State.MonitorEvents.RemoveAt(0) }
        if ([string]$item.Level -eq 'FAIL') { $Controller.State.ActiveProblemCount++ }
        $item = $null
    }
}

function Close-GuiController {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Controller)
    if ($Controller.Closed) { return }
    & $Controller.StopMonitorAction $Controller
    & $Controller.StopDiagnosticAction $Controller
    $Controller.Closed = $true
}

Export-ModuleMember -Function New-GuiState,Test-GuiAdministrator,New-GuiController,Start-GuiDiagnostic,Complete-GuiDiagnostic,Stop-GuiDiagnostic,Start-GuiPoolMonitor,Stop-GuiPoolMonitor,Sync-GuiQueues,Close-GuiController
