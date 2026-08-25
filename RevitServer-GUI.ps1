[CmdletBinding()]
param(
    [ValidateRange(1,3650)][int]$Days = 400,
    [string]$ReportRoot = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase

$moduleRoot = Join-Path $PSScriptRoot 'src'
Import-Module (Join-Path $moduleRoot 'Diagnostics.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Repairs.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Reporting.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Orchestration.psm1') -Force
Import-Module (Join-Path $moduleRoot 'PoolMonitor.psm1') -Force
Import-Module (Join-Path $moduleRoot 'GuiController.psm1') -Force

if (-not $ReportRoot) { $ReportRoot = Join-Path $env:ProgramData 'RevitServer-Diagnostics' }
try { New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null }
catch {
    $ReportRoot = Join-Path $env:TEMP 'RevitServer-Diagnostics'
    New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null
}

$xamlPath = Join-Path $PSScriptRoot 'ui\MainWindow.xaml'
if (-not (Test-Path -LiteralPath $xamlPath)) { throw "XAML interface not found: $xamlPath" }
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
$reader = New-Object Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$controlNames = @(
    'NavHome','NavDiagnostic','NavMonitor','NavRepairs','NavReports','HomeRunButton',
    'RunDiagnosticButton','StartMonitorButton','StopMonitorButton','ClearMonitorButton',
    'StartPoolsButton','BaseSettingsButton','RapidFailButton','SetupProcDumpButton',
    'OpenDumpsButton','OpenReportButton','FindingsGrid','PoolsGrid','MonitorGrid',
    'ProgressBar','ProgressText','MainFrame','HomeView','DiagnosticView','MonitorView',
    'RepairsView','ReportsView','ServerText','IisStatusText','PoolCountText','ProblemCountText',
    'LastCheckText','MonitorStatusText','ReportPathText','AdminStatusText'
)
$controls = @{}
foreach ($name in $controlNames) {
    $control = $window.FindName($name)
    if ($null -eq $control) { throw "Required UI control is missing: $name" }
    $controls[$name] = $control
}

$controller = New-GuiController -ModuleRoot $moduleRoot -ReportRoot $ReportRoot
$state = $controller.State
$controls.FindingsGrid.ItemsSource = $state.Findings
$controls.PoolsGrid.ItemsSource = $state.Pools
$controls.MonitorGrid.ItemsSource = $state.MonitorEvents
$controls.ServerText.Text = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'Windows Server' }
$controls.AdminStatusText.Text = if ($controller.IsAdministrator) { 'Администратор' } else { 'Только просмотр' }

function Show-GuiView {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($viewName in @('HomeView','DiagnosticView','MonitorView','RepairsView','ReportsView')) {
        $controls[$viewName].Visibility = if ($viewName -eq $Name) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    }
}

function Show-GuiError {
    param([string]$Message)
    [void][Windows.MessageBox]::Show($window,$Message,'Revit Server Diagnostics',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error)
}

function Refresh-GuiState {
    Sync-GuiQueues -Controller $controller
    if ($controller.DiagnosticRunner -and $controller.DiagnosticRunner.AsyncResult.IsCompleted) {
        [void](Complete-GuiDiagnostic -Controller $controller)
    }
    $controls.ProgressBar.Value = $state.Progress
    $controls.ProgressBar.IsIndeterminate = [bool]($state.Busy -and $state.Progress -lt 100)
    $controls.ProgressText.Text = $state.Stage
    $controls.RunDiagnosticButton.IsEnabled = -not $state.Busy
    $controls.HomeRunButton.IsEnabled = -not $state.Busy
    $controls.PoolCountText.Text = [string]$state.Pools.Count
    $failedFindings = @($state.Findings | Where-Object Level -eq 'FAIL').Count
    $controls.ProblemCountText.Text = [string]($failedFindings + $state.ActiveProblemCount)
    $controls.IisStatusText.Text = if ($state.LastCheck) { if ($state.Pools.Count -gt 0) { 'Доступен' } else { 'Пулы не найдены' } } else { 'Не проверен' }
    $controls.LastCheckText.Text = if ($state.LastCheck) { $state.LastCheck.ToString('dd.MM.yyyy HH:mm:ss') } else { 'Ещё не выполнялась' }
    $controls.MonitorStatusText.Text = if ($state.MonitorRunning) { 'Работает' } else { 'Выключен' }
    $controls.ReportPathText.Text = if ($state.LastReport) { $state.LastReport } else { 'Отчёт ещё не создан' }
    $controls.StartMonitorButton.IsEnabled = (-not $state.MonitorRunning -and $state.Pools.Count -gt 0)
    $controls.StopMonitorButton.IsEnabled = $state.MonitorRunning
    $canRepair = [bool]($controller.IsAdministrator -and $state.Pools.Count -gt 0)
    foreach ($button in @($controls.StartPoolsButton,$controls.BaseSettingsButton,$controls.RapidFailButton)) { $button.IsEnabled = $canRepair }
    $controls.SetupProcDumpButton.IsEnabled = $controller.IsAdministrator
    $controls.OpenReportButton.IsEnabled = [bool]($state.LastReport -and (Test-Path -LiteralPath $state.LastReport))
}

function Start-GuiFullDiagnostic {
    try {
        Show-GuiView 'DiagnosticView'
        [void](Start-GuiDiagnostic -Controller $controller -Days $Days)
        Refresh-GuiState
    } catch { Show-GuiError $_.Exception.Message }
}

function Update-PoolsAfterRepair {
    try {
        $iis = Get-IisState
        $state.Pools.Clear()
        foreach ($pool in @($iis.Pools | Where-Object { $_.Name -match '(?i)Revit|ModelService' })) { $state.Pools.Add($pool) }
    } catch { }
    Refresh-GuiState
}

function Invoke-ConfirmedPoolAction {
    param([ValidateSet('Start','BaseSettings','RapidFail')][string]$Action,[string]$Title)
    try {
        $preview = @(New-PoolActionPreview -Pools @($state.Pools) -Action $Action)
        if ($preview.Count -eq 0) {
            [void][Windows.MessageBox]::Show($window,'Изменения не требуются.',$Title,[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Information)
            return
        }
        $lines = @($preview | ForEach-Object { "{0}: {1}  {2} -> {3}" -f $_.Pool,$_.Setting,$_.Current,$_.Desired })
        $message = "Будут выполнены изменения:`n`n$($lines -join "`n")`n`nПродолжить?"
        $answer = [Windows.MessageBox]::Show($window,$message,$Title,[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
        $actionRoot = Join-Path $ReportRoot ("GuiAction_" + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
        New-Item -ItemType Directory -Path $actionRoot -Force | Out-Null
        $context = New-RepairContext -BasePath $actionRoot
        $results = @(Invoke-PoolAction -Context $context -Pools @($state.Pools) -Action $Action -Confirm:$false)
        $rollback = Complete-RollbackScript -Context $context
        $summary = @($results | ForEach-Object { "{0}: {1} — {2}" -f $_.Name,$_.Status,$_.Message }) -join "`n"
        [void][Windows.MessageBox]::Show($window,"$summary`n`nОткат: $rollback",$Title,[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Information)
        Update-PoolsAfterRepair
    } catch { Show-GuiError $_.Exception.Message }
}

$controls.NavHome.Add_Click({ Show-GuiView 'HomeView' })
$controls.NavDiagnostic.Add_Click({ Show-GuiView 'DiagnosticView' })
$controls.NavMonitor.Add_Click({ Show-GuiView 'MonitorView' })
$controls.NavRepairs.Add_Click({ Show-GuiView 'RepairsView' })
$controls.NavReports.Add_Click({ Show-GuiView 'ReportsView' })
$controls.HomeRunButton.Add_Click({ Start-GuiFullDiagnostic })
$controls.RunDiagnosticButton.Add_Click({ Start-GuiFullDiagnostic })

$controls.StartMonitorButton.Add_Click({
    try {
        $csvPath = Join-Path $ReportRoot ("PoolMonitor_{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
        [void](Start-GuiPoolMonitor -Controller $controller -CsvPath $csvPath)
        Refresh-GuiState
    } catch { Show-GuiError $_.Exception.Message }
})
$controls.StopMonitorButton.Add_Click({ Stop-GuiPoolMonitor -Controller $controller; Refresh-GuiState })
$controls.ClearMonitorButton.Add_Click({ $state.MonitorEvents.Clear();$state.ActiveProblemCount=0;Refresh-GuiState })
$controls.StartPoolsButton.Add_Click({ Invoke-ConfirmedPoolAction -Action Start -Title 'Запуск пулов Revit Server' })
$controls.BaseSettingsButton.Add_Click({ Invoke-ConfirmedPoolAction -Action BaseSettings -Title 'Базовые настройки пулов' })
$controls.RapidFailButton.Add_Click({ Invoke-ConfirmedPoolAction -Action RapidFail -Title 'Rapid-Fail Protection = 20' })

$controls.SetupProcDumpButton.Add_Click({
    $warning = 'Будет загружен официальный ProcDump Sysinternals, проверена подпись Microsoft и настроены полные дампы в C:\Dumps\RevitServer. Дамп может занимать много места и содержать данные памяти. Продолжить?'
    if ([Windows.MessageBox]::Show($window,$warning,'Настройка ProcDump',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning) -ne [Windows.MessageBoxResult]::Yes) { return }
    try {
        $actionRoot = Join-Path $ReportRoot ("ProcDump_" + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
        New-Item -ItemType Directory -Path $actionRoot -Force | Out-Null
        $context = New-RepairContext -BasePath $actionRoot
        $result = Install-VerifiedProcDump -Context $context -Confirm:$false
        [void][Windows.MessageBox]::Show($window,$result.Message,'ProcDump',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Information)
    } catch { Show-GuiError $_.Exception.Message }
})

$controls.OpenReportButton.Add_Click({ if ($state.LastReport -and (Test-Path -LiteralPath $state.LastReport)) { Start-Process $state.LastReport } })
$controls.OpenDumpsButton.Add_Click({
    $dumpPath = 'C:\Dumps\RevitServer'
    if (-not (Test-Path -LiteralPath $dumpPath)) { New-Item -ItemType Directory -Path $dumpPath -Force | Out-Null }
    Start-Process explorer.exe $dumpPath
})

$uiTimer = New-Object Windows.Threading.DispatcherTimer
$uiTimer.Interval = [timespan]::FromMilliseconds(500)
$uiTimer.Add_Tick({ Refresh-GuiState })
$uiTimer.Start()
$window.Add_Closing({
    $uiTimer.Stop()
    Close-GuiController -Controller $controller
})

Show-GuiView 'HomeView'
Refresh-GuiState
[void]$window.ShowDialog()
