<#
.SYNOPSIS
    Диагностика и явно выбранное безопасное исправление Revit Server, IIS и .NET Framework.
.DESCRIPTION
    Без repair-ключей скрипт ничего не изменяет. Доступные обновления определяются Windows Update Agent,
    а версия clr.dll не используется как самостоятельное доказательство неисправности.
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param(
    [ValidateRange(1,3650)][int]$Days = 400,
    [string]$OutDir = '',
    [switch]$SkipEndpointTest,
    [switch]$Repair,
    [switch]$SetupProcDump,
    [switch]$InstallUpdates,
    [ValidateSet('DotNet','Windows','All')][string]$UpdateKind = 'DotNet',
    [switch]$UpgradeNet481,
    [string]$Net481InstallerPath = '',
    [switch]$SnapshotConfirmed,
    [switch]$DisableDynamicIpRestrictions,
    [switch]$AutoReboot,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$moduleRoot = Join-Path $PSScriptRoot 'src'
Import-Module (Join-Path $moduleRoot 'Diagnostics.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $moduleRoot 'Repairs.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $moduleRoot 'Reporting.psm1') -Force -ErrorAction Stop

if (-not $OutDir) { $OutDir = $PSScriptRoot }
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$reportPath = Join-Path $OutDir "Report_$($env:COMPUTERNAME)_$stamp"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null
Start-Transcript -Path (Join-Path $reportPath 'console.log') -Force | Out-Null

function Add-LocalFinding {
    param([string]$Level,[string]$Code,[string]$Message,[object]$Data=$null)
    $finding = New-DiagnosticFinding -Level $Level -Code $Code -Message $Message -Data $Data
    [void]$script:findings.Add($finding)
    Write-DiagnosticFinding -Finding $finding
}

$script:findings = New-Object System.Collections.ArrayList
$repairResults = New-Object System.Collections.ArrayList
$since = (Get-Date).AddDays(-$Days)

Write-Host ''
Write-Host 'Revit Server Diagnostics' -ForegroundColor Cyan
Write-Host "Отчёт: $reportPath"
Write-Host "Период: $Days дн."

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    [pscustomobject]@{Drive=$_.DeviceID;SizeGB=[math]::Round($_.Size/1GB,1);FreeGB=[math]::Round($_.FreeSpace/1GB,1);FreePct=if($_.Size){[math]::Round(100*$_.FreeSpace/$_.Size,1)}else{0}}
})
$environment = [pscustomobject]@{
    Computer=$env:COMPUTERNAME;OS=$os.Caption;Version=$os.Version;Build=$os.BuildNumber
    LastBoot=$os.LastBootUpTime;RAM_GB=[math]::Round($cs.TotalPhysicalMemory/1GB,1)
    FreeRAM_GB=[math]::Round($os.FreePhysicalMemory/1MB,1);CPU=$cs.NumberOfLogicalProcessors;Disks=$disks
}
foreach ($disk in $disks) { if ($disk.FreePct -lt 15) { Add-LocalFinding WARN 'DISK_LOW' "На диске $($disk.Drive) свободно $($disk.FreeGB) ГБ ($($disk.FreePct)%)." $disk } }

$dotnet = Get-DotNetFrameworkState
Add-LocalFinding INFO 'DOTNET_STATE' ".NET Framework $($dotnet.Framework), Release $($dotnet.Release), clr.dll $($dotnet.ClrVersion). Версия файла сама по себе не считается ошибкой." $dotnet

$updateState = Get-WindowsUpdateState
if ($updateState.MicrosoftUpdateRegistered) { Add-LocalFinding OK 'MU_REGISTERED' 'Microsoft Update подключён.' $updateState }
else { Add-LocalFinding WARN 'MU_NOT_REGISTERED' 'Microsoft Update не зарегистрирован. Обычная диагностика ничего не меняет; используйте -Repair для регистрации.' $updateState }

$availableUpdates = @()
try {
    Write-Host 'Поиск применимых обновлений через Windows Update Agent (может занять 1–3 минуты)...' -ForegroundColor Cyan
    $availableUpdates = @(Find-ApplicableUpdates -UseMicrosoftUpdate:$updateState.MicrosoftUpdateRegistered)
    $dotnetUpdates = @(Select-RelevantUpdates -Updates $availableUpdates -Kind DotNet)
    if ($dotnetUpdates.Count -eq 0) { Add-LocalFinding OK 'DOTNET_NO_UPDATE' 'Применимых обновлений .NET Framework не найдено. Это не считается ошибкой канала обновлений.' }
    else { Add-LocalFinding INFO 'DOTNET_UPDATE_FOUND' "Найдено применимых обновлений .NET Framework: $($dotnetUpdates.Count). Установка возможна только с -InstallUpdates." $dotnetUpdates }
} catch { Add-LocalFinding WARN 'UPDATE_SEARCH_FAILED' "Поиск обновлений не выполнен: $($_.Exception.Message)" }

$iis = Get-IisState
if (-not $iis.Available) { Add-LocalFinding FAIL 'IIS_UNAVAILABLE' "IIS/WebAdministration недоступен: $($iis.Error)" }
else {
    foreach ($pool in @($iis.Pools | Where-Object Name -match '(?i)Revit|ModelService')) {
        if ($pool.State -ne 'Started') { Add-LocalFinding FAIL 'POOL_STOPPED' "Пул $($pool.Name) остановлен." $pool }
        if (-not $pool.AutoStart -or $pool.StartMode -ne 'AlwaysRunning' -or $pool.IdleTimeoutMinutes -ne 0) { Add-LocalFinding WARN 'POOL_CONFIGURATION' "Пул $($pool.Name) требует корректировки автозапуска/тайм-аута." $pool }
        if ($pool.RapidFailMaxCrashes -lt 20) { Add-LocalFinding WARN 'RAPID_FAIL_LOW' "Пул $($pool.Name): Rapid-Fail остановит пул после $($pool.RapidFailMaxCrashes) сбоев; -Repair установит 20, не отключая защиту." $pool }
    }
}

$revit = Get-RevitServerState
if (@($revit.Instances).Count -eq 0) { Add-LocalFinding FAIL 'REVIT_NOT_FOUND' 'Установленные экземпляры Revit Server не найдены.' }
foreach ($service in @($revit.Services | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' })) { Add-LocalFinding FAIL 'SERVICE_STOPPED' "Автоматическая служба $($service.Name) не запущена." $service }

$crashEvents = @(Get-CrashEvents -Since $since)
$crashes = Get-CrashTimeline -Events $crashEvents
if ($crashes.RootCauseCrashCount -eq 0) { Add-LocalFinding OK 'NO_CRASHES' "За последние $Days дней связанных падений не найдено." }
else { Add-LocalFinding FAIL 'CRASHES_FOUND' "Найдено корневых падений: $($crashes.RootCauseCrashCount). Для установления виновника нужен дамп." $crashes.Signatures }

$network = Get-NetworkState
if (@($network.Adapters).Count -gt 1) { Add-LocalFinding INFO 'MULTIPLE_ADAPTERS' "Активных сетевых интерфейсов: $(@($network.Adapters).Count). NetBIOS и DNS автоматически не изменяются." $network.Adapters }
$profiler = Get-ProfilerState
if ($profiler.InjectionSuspected) { Add-LocalFinding FAIL 'CLR_PROFILER' 'Найдены переменные CLR-профилировщика; сторонний код может внедряться в w3wp.exe.' $profiler.Variables }

$extended = Get-ExtendedDiagnostics -Since $since -IisState $iis -RevitState $revit -CrashEvents $crashEvents -SkipEndpointTest:$SkipEndpointTest
$missingFeatures = @($extended.Features | Where-Object InstallState -ne 'Installed')
if ($missingFeatures.Count -gt 0) { Add-LocalFinding FAIL 'IIS_FEATURES_MISSING' "Не установлено компонентов IIS: $($missingFeatures.Name -join ', '). -Repair установит их." $missingFeatures }
$failedEndpoints = @($extended.EndpointTests | Where-Object { $_.Status -ne 200 })
if ($failedEndpoints.Count -gt 0) { Add-LocalFinding FAIL 'ENDPOINT_FAILED' "Не отвечают эндпоинты Revit Server: $($failedEndpoints.Count)." $failedEndpoints }
if (@($extended.LogErrors).Count -gt 0) { Add-LocalFinding WARN 'REVIT_LOG_ERRORS' "В журналах Revit Server найдено строк с ошибками: $(@($extended.LogErrors).Count)." }
if (@($extended.MissingEndpoints).Count -gt 0) { Add-LocalFinding WARN 'MISSING_ENDPOINTS' "Клиенты запрашивают отсутствующие версии Revit Server: $($extended.MissingEndpoints.Year -join ', ')." $extended.MissingEndpoints }
if (@($extended.TaskCorrelations).Count -gt 0) { Add-LocalFinding WARN 'SCHEDULED_TASK_CORRELATION' "Задания планировщика рядом с падениями (±5 мин): $(@($extended.TaskCorrelations).Count)." $extended.TaskCorrelations }
if (-not $extended.DumpState.AeDebugDebugger -and $extended.DumpState.WerDumpType -ne 2) { Add-LocalFinding FAIL 'DUMPS_NOT_CONFIGURED' 'Полные аварийные дампы не настроены. Используйте -SetupProcDump.' }

$snapshot = [pscustomobject]@{
    Generated=Get-Date;Environment=$environment;DotNet=$dotnet
    Updates=[pscustomobject]@{State=$updateState;Available=$availableUpdates}
    Iis=$iis;Revit=$revit;Crashes=$crashes;Network=$network;Profiler=$profiler;Extended=$extended
}

$requested = @(Get-RequestedRepairs -Repair:$Repair -SetupProcDump:$SetupProcDump -InstallUpdates:$InstallUpdates -UpgradeNet481:$UpgradeNet481 -DisableDynamicIpRestrictions:$DisableDynamicIpRestrictions)
$context = $null
if ($requested.Count -gt 0) {
    $context = New-RepairContext -BasePath $reportPath
    $confirmPreferenceBefore = $ConfirmPreference
    if ($Force) { $ConfirmPreference = 'None' }
    try {
        if ($Repair) {
            [void]$repairResults.Add((Register-MicrosoftUpdate -Confirm:(-not $Force)))
            foreach ($result in @(Invoke-RevitBasicRepair -Context $context -IisState $iis -RevitState $revit -Confirm:(-not $Force))) { [void]$repairResults.Add($result) }
        }
        if ($SetupProcDump) { [void]$repairResults.Add((Install-VerifiedProcDump -Context $context -Confirm:(-not $Force))) }
        if ($InstallUpdates) {
            $selected = @(Select-RelevantUpdates -Updates $availableUpdates -Kind $UpdateKind)
            [void]$repairResults.Add((Install-ApplicableUpdates -Updates $selected -AutoReboot:$AutoReboot -Confirm:(-not $Force)))
        }
        if ($UpgradeNet481) {
            if (-not $Net481InstallerPath) { throw '-UpgradeNet481 requires -Net481InstallerPath and -SnapshotConfirmed.' }
            [void]$repairResults.Add((Install-Net481Upgrade -InstallerPath $Net481InstallerPath -SnapshotConfirmed:$SnapshotConfirmed -AutoReboot:$AutoReboot -Confirm:(-not $Force)))
        }
        if ($DisableDynamicIpRestrictions) {
            $paths = @($iis.Applications | Where-Object Path -match '(?i)RevitServer|ModelService' | ForEach-Object { if ($_.Site) { "$($_.Site)$($_.Path)" } else { $_.Path } })
            foreach ($result in @(Disable-RevitDynamicIpRestrictions -Context $context -ApplicationPaths $paths -Confirm:(-not $Force))) { [void]$repairResults.Add($result) }
        }
    } catch { [void]$repairResults.Add((New-RepairResult -Name 'RepairOrchestrator' -Status Failed -Message $_.Exception.Message)) }
    finally { $ConfirmPreference = $confirmPreferenceBefore }
    $rollback = Complete-RollbackScript -Context $context
    Write-Host "Сценарий отката: $rollback" -ForegroundColor Yellow
}

$htmlPath = Export-RevitDiagnosticReport -ReportPath $reportPath -Snapshot $snapshot -Findings @($script:findings) -RepairResults @($repairResults)
Stop-Transcript | Out-Null
Write-Host "Отчёт: $htmlPath" -ForegroundColor Green
try { Start-Process $htmlPath } catch { }
