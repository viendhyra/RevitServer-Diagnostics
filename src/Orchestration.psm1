Set-StrictMode -Version 2.0

$moduleRoot = $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'Diagnostics.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Reporting.psm1') -Force

function Publish-DiagnosticProgress {
    param([scriptblock]$Action,[int]$Percent,[string]$Stage,[string]$Message)
    if ($null -ne $Action) {
        & $Action ([pscustomobject]@{Percent=$Percent;Stage=$Stage;Message=$Message})
    }
}

function New-EmptyDiagnosticValues {
    [ordered]@{
        Environment = [pscustomobject]@{Computer=$env:COMPUTERNAME;OS='Unknown';Version='';Build='';LastBoot=$null;RAM_GB=0;FreeRAM_GB=0;CPU=0;Disks=@()}
        DotNet = [pscustomobject]@{Framework='Unknown';Release=0;ClrVersion='';Files=@()}
        Updates = [pscustomobject]@{State=[pscustomobject]@{MicrosoftUpdateRegistered=$false;PendingReboot=$false};Available=@()}
        Iis = [pscustomobject]@{Available=$false;Error='Not collected';Pools=@();Sites=@();Applications=@()}
        Revit = [pscustomobject]@{Instances=@();Services=@()}
        Crashes = [pscustomobject]@{RootCauseCrashCount=0;Events=@();Signatures=@()}
        Network = [pscustomobject]@{Adapters=@()}
        Profiler = [pscustomobject]@{InjectionSuspected=$false;Variables=@()}
        Extended = [pscustomobject]@{NativeModules=@();Features=@();Binaries=@();DataDirectories=@();LogErrors=@();EndpointTests=@();MissingEndpoints=@();TaskCorrelations=@();W3wpModules=@();Defender=$null;RelatedEvents=@();DumpState=[pscustomobject]@{AeDebugDebugger=$null;WerDumpType=$null}}
    }
}

function Get-EnvironmentSnapshot {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [pscustomobject]@{
            Drive=$_.DeviceID
            SizeGB=[math]::Round($_.Size/1GB,1)
            FreeGB=[math]::Round($_.FreeSpace/1GB,1)
            FreePct=if($_.Size){[math]::Round(100*$_.FreeSpace/$_.Size,1)}else{0}
        }
    })
    [pscustomobject]@{
        Computer=$env:COMPUTERNAME;OS=$os.Caption;Version=$os.Version;Build=$os.BuildNumber
        LastBoot=$os.LastBootUpTime;RAM_GB=[math]::Round($cs.TotalPhysicalMemory/1GB,1)
        FreeRAM_GB=[math]::Round($os.FreePhysicalMemory/1MB,1);CPU=$cs.NumberOfLogicalProcessors;Disks=$disks
    }
}

function Add-OrchestrationFinding {
    param([Collections.ArrayList]$List,[string]$Level,[string]$Code,[string]$Message,[object]$Data=$null)
    [void]$List.Add((New-DiagnosticFinding -Level $Level -Code $Code -Message $Message -Data $Data))
}

function Get-OrchestrationFindings {
    param([Collections.IDictionary]$Values,[object[]]$CollectorFailures)
    $findings = New-Object Collections.ArrayList
    foreach ($failure in @($CollectorFailures)) {
        Add-OrchestrationFinding $findings FAIL ("COLLECTOR_{0}_FAILED" -f $failure.Name.ToUpperInvariant()) ("Проверка {0} не выполнена: {1}" -f $failure.Name,$failure.Message)
    }
    Add-OrchestrationFinding $findings INFO 'DOTNET_STATE' (".NET Framework {0}, Release {1}, clr.dll {2}." -f $Values.DotNet.Framework,$Values.DotNet.Release,$Values.DotNet.ClrVersion) $Values.DotNet
    if (-not $Values.Iis.Available) {
        Add-OrchestrationFinding $findings FAIL 'IIS_UNAVAILABLE' ("IIS недоступен: {0}" -f $Values.Iis.Error)
    }
    foreach ($pool in @($Values.Iis.Pools | Where-Object Name -match '(?i)Revit|ModelService')) {
        if ($pool.State -ne 'Started') { Add-OrchestrationFinding $findings FAIL 'POOL_STOPPED' ("Пул {0} остановлен." -f $pool.Name) $pool }
        if ($pool.RapidFailMaxCrashes -lt 20) { Add-OrchestrationFinding $findings WARN 'RAPID_FAIL_LOW' ("Пул {0}: Rapid-Fail = {1}; рекомендуется 20." -f $pool.Name,$pool.RapidFailMaxCrashes) $pool }
    }
    if ($Values.Crashes.RootCauseCrashCount -gt 0) {
        Add-OrchestrationFinding $findings FAIL 'CRASHES_FOUND' ("Найдено корневых падений: {0}." -f $Values.Crashes.RootCauseCrashCount) $Values.Crashes.Signatures
    }
    if (-not $Values.Extended.DumpState.AeDebugDebugger -and $Values.Extended.DumpState.WerDumpType -ne 2) {
        Add-OrchestrationFinding $findings WARN 'DUMPS_NOT_CONFIGURED' 'Полные аварийные дампы не настроены.'
    }
    @($findings)
}

function Invoke-DefaultDiagnosticCollection {
    param([int]$Days,[switch]$SkipEndpointTest,[scriptblock]$ProgressAction)
    $values = New-EmptyDiagnosticValues
    $failures = New-Object Collections.ArrayList
    $stages = @('Environment','DotNet','Updates','Iis','Revit','Crashes','Network','Profiler','Extended')
    for ($index=0; $index -lt $stages.Count; $index++) {
        $name = $stages[$index]
        Publish-DiagnosticProgress $ProgressAction ([int](5 + 80*$index/$stages.Count)) $name ("Выполняется: {0}" -f $name)
        try {
            switch ($name) {
                'Environment' { $values.Environment = Get-EnvironmentSnapshot }
                'DotNet' { $values.DotNet = Get-DotNetFrameworkState }
                'Updates' {
                    $state = Get-WindowsUpdateState
                    $available = @(Find-ApplicableUpdates -UseMicrosoftUpdate:$state.MicrosoftUpdateRegistered)
                    $values.Updates = [pscustomobject]@{State=$state;Available=$available}
                }
                'Iis' { $values.Iis = Get-IisState }
                'Revit' { $values.Revit = Get-RevitServerState }
                'Crashes' {
                    $events = @(Get-CrashEvents -Since (Get-Date).AddDays(-$Days))
                    $values.Crashes = Get-CrashTimeline -Events $events
                }
                'Network' { $values.Network = Get-NetworkState }
                'Profiler' { $values.Profiler = Get-ProfilerState }
                'Extended' {
                    $values.Extended = Get-ExtendedDiagnostics -Since (Get-Date).AddDays(-$Days) -IisState $values.Iis -RevitState $values.Revit -CrashEvents @($values.Crashes.Events) -SkipEndpointTest:$SkipEndpointTest
                }
            }
        } catch {
            [void]$failures.Add([pscustomobject]@{Name=$name;Message=$_.Exception.Message})
        }
    }
    [pscustomobject]@{Values=$values;Failures=@($failures)}
}

function Invoke-InjectedDiagnosticCollection {
    param([Collections.IDictionary]$Collectors,[scriptblock]$ProgressAction)
    $values = New-EmptyDiagnosticValues
    $failures = New-Object Collections.ArrayList
    $names = @($Collectors.Keys)
    for ($index=0; $index -lt $names.Count; $index++) {
        $name = [string]$names[$index]
        Publish-DiagnosticProgress $ProgressAction ([int](5 + 80*$index/[math]::Max(1,$names.Count))) $name ("Выполняется: {0}" -f $name)
        try { $values[$name] = & $Collectors[$name] }
        catch { [void]$failures.Add([pscustomobject]@{Name=$name;Message=$_.Exception.Message}) }
    }
    [pscustomobject]@{Values=$values;Failures=@($failures)}
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
    Publish-DiagnosticProgress $ProgressAction 0 'Start' 'Подготовка диагностики'
    if ($null -ne $Collectors) {
        $collection = Invoke-InjectedDiagnosticCollection -Collectors $Collectors -ProgressAction $ProgressAction
    } else {
        $collection = Invoke-DefaultDiagnosticCollection -Days $Days -SkipEndpointTest:$SkipEndpointTest -ProgressAction $ProgressAction
    }
    $values = $collection.Values
    $findings = @(Get-OrchestrationFindings -Values $values -CollectorFailures $collection.Failures)
    $snapshot = [pscustomobject]@{
        Generated=Get-Date;Environment=$values.Environment;DotNet=$values.DotNet;Updates=$values.Updates
        Iis=$values.Iis;Revit=$values.Revit;Crashes=$values.Crashes;Network=$values.Network;Profiler=$values.Profiler;Extended=$values.Extended
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss_fff'
    $reportPath = Join-Path $OutDir ("Report_{0}_{1}" -f $env:COMPUTERNAME,$stamp)
    Publish-DiagnosticProgress $ProgressAction 90 'Report' 'Формирование отчёта'
    $htmlPath = Export-RevitDiagnosticReport -ReportPath $reportPath -Snapshot $snapshot -Findings $findings -RepairResults @()
    Publish-DiagnosticProgress $ProgressAction 100 'Complete' 'Проверка завершена'
    [pscustomobject]@{
        ReportPath=$reportPath;HtmlPath=$htmlPath;Snapshot=$snapshot;Findings=$findings
        AvailableUpdates=@($values.Updates.Available)
    }
}

Export-ModuleMember -Function Invoke-RevitServerDiagnostic
