Set-StrictMode -Version 2.0

function New-DiagnosticFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('OK','WARN','FAIL','INFO')][string]$Level,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        [object]$Data
    )
    [pscustomobject]@{
        Time = Get-Date
        Level = $Level
        Code = $Code
        Message = $Message
        Data = $Data
    }
}

function ConvertTo-DotNetState {
    [CmdletBinding()]
    param(
        [AllowNull()][int]$Release,
        [AllowEmptyString()][string]$ClrVersion = ''
    )
    $framework = 'Unknown'
    if ($Release -ge 533320) { $framework = '4.8.1' }
    elseif ($Release -ge 528040) { $framework = '4.8' }
    elseif ($Release -ge 461808) { $framework = '4.7.2' }
    elseif ($Release -gt 0) { $framework = 'Older than 4.7.2' }

    $health = if ($Release -le 0) { 'WARN' } else { 'INFO' }
    [pscustomobject]@{
        Framework = $framework
        Release = $Release
        ClrVersion = $ClrVersion
        Health = $health
        Note = 'CLR file version is evidence only. Update availability is determined by Windows Update Agent.'
    }
}

function Get-DotNetFrameworkState {
    [CmdletBinding()]
    param()
    $key = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
    $paths = @(
        "$env:windir\Microsoft.NET\Framework64\v4.0.30319\clr.dll",
        "$env:windir\Microsoft.NET\Framework\v4.0.30319\clr.dll"
    )
    $files = foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path
            [pscustomobject]@{
                Path = $path
                Version = (($item.VersionInfo.FileVersion -split '\s+')[0])
                ProductVersion = $item.VersionInfo.ProductVersion
                Modified = $item.LastWriteTime
            }
        }
    }
    $primaryVersion = ''
    $primary = @($files | Where-Object { $_.Path -match 'Framework64' } | Select-Object -First 1)
    if ($primary.Count -gt 0) { $primaryVersion = $primary[0].Version }
    $state = ConvertTo-DotNetState -Release ([int]$key.Release) -ClrVersion $primaryVersion
    $state | Add-Member -NotePropertyName Files -NotePropertyValue @($files)
    $state
}

function ConvertFrom-WuaUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Update)
    $categories = @()
    foreach ($category in @($Update.Categories)) {
        if ($category -is [string]) { $categories += $category }
        elseif ($null -ne $category.Name) { $categories += [string]$category.Name }
    }
    $kb = @()
    foreach ($id in @($Update.KBArticleIDs)) { $kb += [string]$id }
    [pscustomobject]@{
        Title = [string]$Update.Title
        Categories = $categories
        IsInstalled = [bool]$Update.IsInstalled
        IsHidden = [bool]$Update.IsHidden
        KBArticleIDs = $kb
        MaxDownloadSize = [long]$Update.MaxDownloadSize
        EulaAccepted = [bool]$Update.EulaAccepted
        Raw = $Update
    }
}

function Select-RelevantUpdates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Updates,
        [ValidateSet('DotNet','Windows','All')][string]$Kind = 'DotNet'
    )
    foreach ($update in @($Updates)) {
        if ($null -eq $update) { continue }
        if ([bool]$update.IsInstalled -or [bool]$update.IsHidden) { continue }
        $categoryNames = @()
        foreach ($category in @($update.Categories)) {
            if ($category -is [string]) { $categoryNames += $category }
            elseif ($null -ne $category.Name) { $categoryNames += [string]$category.Name }
        }
        $text = ([string]$update.Title) + ' ' + ($categoryNames -join ' ')
        $include = $false
        switch ($Kind) {
            'DotNet' { $include = $text -match '(?i)\.NET Framework|\.NET\b' }
            'Windows' { $include = $text -notmatch '(?i)Definition Updates|Security intelligence|Driver' }
            'All' { $include = $true }
        }
        if ($include) { $update }
    }
}

function Get-WindowsUpdateState {
    [CmdletBinding()]
    param()
    $policy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
    $au = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
    $services = @()
    try {
        $manager = New-Object -ComObject Microsoft.Update.ServiceManager
        foreach ($service in @($manager.Services)) {
            $services += [pscustomobject]@{
                Name = $service.Name
                ServiceID = $service.ServiceID
                IsDefault = $service.IsDefaultAUService
                IsManaged = $service.IsManaged
            }
        }
    } catch { }
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    $wuServer = $null
    $noAutoUpdate = $null
    $auOptions = $null
    if ($null -ne $policy) { $wuServer = $policy.WUServer }
    if ($null -ne $au) { $noAutoUpdate = $au.NoAutoUpdate; $auOptions = $au.AUOptions }
    [pscustomobject]@{
        WUServer = $wuServer
        NoAutoUpdate = $noAutoUpdate
        AUOptions = $auOptions
        Services = $services
        MicrosoftUpdateRegistered = [bool]($services | Where-Object ServiceID -eq '7971f918-a847-4430-9279-4a52d1efe18d')
        PendingReboot = [bool]$pending
    }
}

function Find-ApplicableUpdates {
    [CmdletBinding()]
    param([switch]$UseMicrosoftUpdate)
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    if ($UseMicrosoftUpdate) {
        $searcher.ServerSelection = 3
        $searcher.ServiceID = '7971f918-a847-4430-9279-4a52d1efe18d'
    }
    $result = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    foreach ($update in @($result.Updates)) { ConvertFrom-WuaUpdate -Update $update }
}

function Get-CrashTimeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events,
        [ValidateRange(1,60)][int]$CorrelationSeconds = 5
    )
    $sorted = @($Events | Sort-Object Time)
    $applicationErrors = @($sorted | Where-Object Type -eq 'AppError-1000')
    $unmatchedWas = 0
    foreach ($was in @($sorted | Where-Object Type -eq 'WAS-5011')) {
        $matched = @($applicationErrors | Where-Object {
            [math]::Abs((([datetime]$_.Time) - ([datetime]$was.Time)).TotalSeconds) -le $CorrelationSeconds
        }).Count -gt 0
        if (-not $matched) { $unmatchedWas++ }
    }
    [pscustomobject]@{
        RootCauseCrashCount = $applicationErrors.Count + $unmatchedWas
        Events = $sorted
        Signatures = @($applicationErrors | Group-Object Module,Code,Offset | Sort-Object Count -Descending | ForEach-Object {
            [pscustomobject]@{ Signature=$_.Name; Count=$_.Count }
        })
    }
}

function Get-MissingEndpointRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    $endpoint = ''
    if ($Message -match "The service '([^']+)' does not exist") { $endpoint = $matches[1] }
    elseif ($Message -match '(\/RevitServer[^\s\"'']+)') { $endpoint = $matches[1] }
    $year = ([regex]::Match($endpoint, '(?<!\d)(20\d{2})(?!\d)')).Value
    [pscustomobject]@{ Endpoint=$endpoint; Year=$year; Message=$Message }
}

function Get-CrashEvents {
    [CmdletBinding()]
    param([datetime]$Since = (Get-Date).AddDays(-400))
    $events = New-Object System.Collections.ArrayList
    try {
        Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='Application Error';Id=1000;StartTime=$Since} -ErrorAction Stop | ForEach-Object {
            $p = $_.Properties
            [void]$events.Add([pscustomobject]@{Time=$_.TimeCreated;Type='AppError-1000';Process=$p[0].Value;Module=$p[3].Value;Code=$p[6].Value;Offset=$p[7].Value;Pool=''})
        }
    } catch { }
    try {
        Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-WAS';Id=5011;StartTime=$Since} -ErrorAction Stop | ForEach-Object {
            [void]$events.Add([pscustomobject]@{Time=$_.TimeCreated;Type='WAS-5011';Process='w3wp.exe';Module='';Code='';Offset='';Pool=$_.Properties[0].Value})
        }
    } catch { }
    @($events)
}

function Get-IisState {
    [CmdletBinding()]
    param()
    try { Import-Module WebAdministration -ErrorAction Stop } catch {
        return [pscustomobject]@{Available=$false;Error=$_.Exception.Message;Pools=@();Sites=@();Applications=@()}
    }
    $pools = @(Get-ChildItem IIS:\AppPools | ForEach-Object {
        [pscustomobject]@{
            Name=$_.Name;State=$_.State;AutoStart=$_.autoStart;StartMode=[string]$_.startMode
            IdleTimeoutMinutes=$_.processModel.idleTimeout.TotalMinutes
            RapidFailEnabled=$_.failure.rapidFailProtection
            RapidFailMaxCrashes=$_.failure.rapidFailProtectionMaxCrashes
            RapidFailInterval=[string]$_.failure.rapidFailProtectionInterval
        }
    })
    $sites = @(Get-ChildItem IIS:\Sites | ForEach-Object {
        [pscustomobject]@{Name=$_.Name;State=$_.State;PhysicalPath=$_.PhysicalPath;Bindings=($_.Bindings.Collection.bindingInformation -join ';')}
    })
    $applications = @(Get-WebApplication | ForEach-Object {
        $siteName = ''
        try { $siteName = $_.GetParentElement().Attributes['name'].Value } catch { }
        [pscustomobject]@{Site=$siteName;Path=$_.Path;Pool=$_.ApplicationPool;PhysicalPath=[Environment]::ExpandEnvironmentVariables($_.PhysicalPath)}
    })
    [pscustomobject]@{Available=$true;Error='';Pools=$pools;Sites=$sites;Applications=$applications}
}

function Get-RevitServerState {
    [CmdletBinding()]
    param()
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $instances = @()
    foreach ($root in $roots) {
        $autodesk = Join-Path $root 'Autodesk'
        if (-not (Test-Path -LiteralPath $autodesk)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $autodesk -Directory -Filter 'Revit Server*' -ErrorAction SilentlyContinue)) {
            $instances += [pscustomobject]@{Name=$dir.Name;Year=([regex]::Match($dir.Name,'20\d{2}')).Value;Path=$dir.FullName}
        }
    }
    $services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Revit|Autodesk|AdSk' } | Select-Object Name,DisplayName,State,StartMode,StartName,ProcessId,PathName)
    [pscustomobject]@{Instances=$instances;Services=$services}
}

function Get-NetworkState {
    [CmdletBinding()]
    param()
    $adapters = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Description=$_.Description;Index=$_.Index;IPAddress=@($_.IPAddress);DnsServers=@($_.DNSServerSearchOrder)
            TcpipNetbiosOptions=$_.TcpipNetbiosOptions;FullDNSRegistrationEnabled=$_.FullDNSRegistrationEnabled
        }
    })
    [pscustomobject]@{Adapters=$adapters;HostName=$env:COMPUTERNAME}
}

function Get-ProfilerState {
    [CmdletBinding()]
    param()
    $key = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue
    $variables = @($key.PSObject.Properties | Where-Object { $_.Name -match '^(COR_|CORECLR_|COMPlus_)' } | ForEach-Object {
        [pscustomobject]@{Name=$_.Name;Value=$_.Value}
    })
    [pscustomobject]@{Variables=$variables;InjectionSuspected=($variables.Count -gt 0)}
}

function New-DynamicIpRestrictionPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Applications)
    $targets = @($Applications | Where-Object { $_ -match '(?i)RevitServer|ModelService' })
    [pscustomobject]@{Targets=$targets;RequiresDedicatedSwitch=$true}
}

function Get-ExtendedDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$Since,
        [Parameter(Mandatory)]$IisState,
        [Parameter(Mandatory)]$RevitState,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CrashEvents,
        [switch]$SkipEndpointTest
    )
    $nativeNames = @('protsup.dll','diprestr.dll','iiscore.dll','cachuri.dll','cachfile.dll','compdyn.dll','compstat.dll','filter.dll','static.dll','defdoc.dll','authanon.dll','isapi.dll','iisreqs.dll')
    $nativeModules = foreach ($name in $nativeNames) {
        $path = Join-Path $env:windir "System32\inetsrv\$name"
        if (Test-Path -LiteralPath $path) {
            $file = Get-Item -LiteralPath $path
            [pscustomobject]@{Name=$name;Version=$file.VersionInfo.FileVersion;Modified=$file.LastWriteTime;Path=$path;Suspect=($name -in @('protsup.dll','diprestr.dll','iiscore.dll'))}
        }
    }

    $features = @()
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $featureNames = @('Web-Server','Web-Asp-Net45','Web-Net-Ext45','Web-ISAPI-Ext','Web-ISAPI-Filter','Web-Windows-Auth','Web-Static-Content','Web-Default-Doc','Web-Http-Errors','Web-Http-Logging','Web-Request-Monitor','NET-WCF-HTTP-Activation45','Web-Mgmt-Console')
        $features = @(Get-WindowsFeature -Name $featureNames | Select-Object Name,DisplayName,InstallState)
    }

    $binaries = @()
    $dataDirectories = @()
    $logFiles = @()
    foreach ($instance in @($RevitState.Instances)) {
        foreach ($relative in @('Services\ModelService\bin\SQLite.Interop.dll','Services\ModelService\bin\System.Data.SQLite.dll','Tools\RevitServerToolCommand.exe','AutoSync\RevitServerAutoSync.exe')) {
            $path = Join-Path $instance.Path $relative
            if (Test-Path -LiteralPath $path) {
                $file = Get-Item -LiteralPath $path
                $binaries += [pscustomobject]@{Instance=$instance.Name;File=$file.Name;Version=$file.VersionInfo.FileVersion;Modified=$file.LastWriteTime;Path=$path}
            }
        }
        foreach ($candidate in @("$env:ProgramData\Autodesk\Revit Server $($instance.Year)","$env:ProgramData\Autodesk\Revit Server\$($instance.Year)")) {
            if (Test-Path -LiteralPath $candidate) {
                $files = @(Get-ChildItem -LiteralPath $candidate -Recurse -File -ErrorAction SilentlyContinue)
                $acl = $null
                try { $acl = Get-Acl -LiteralPath $candidate } catch { }
                $networkService = @()
                if ($null -ne $acl) { $networkService = @($acl.Access | Where-Object { $_.IdentityReference -match 'NETWORK SERVICE|СЕТЕВАЯ СЛУЖБА' }) }
                $dataDirectories += [pscustomobject]@{
                    Instance=$instance.Name;Path=$candidate;Files=$files.Count
                    SizeGB=[math]::Round((($files | Measure-Object Length -Sum).Sum)/1GB,2)
                    LastWrite=($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
                    HasNetworkService=[bool]($networkService.Count -gt 0)
                    NetworkServiceRights=($networkService.FileSystemRights -join '; ')
                }
                $logFiles += @($files | Where-Object { $_.Extension -in @('.log','.txt') -and $_.LastWriteTime -gt $Since } | Sort-Object LastWriteTime -Descending | Select-Object -First 10)
            }
        }
    }
    $logErrors = @()
    foreach ($log in @($logFiles | Sort-Object FullName -Unique | Select-Object -First 30)) {
        try {
            $logErrors += @(Select-String -LiteralPath $log.FullName -Pattern 'error|exception|fail|fatal|denied' -ErrorAction Stop | Select-Object -Last 20 | ForEach-Object {
                [pscustomobject]@{Log=$log.FullName;Line=$_.LineNumber;Text=(($_.Line -replace '\s+',' ').Trim())}
            })
        } catch { }
    }

    $endpointTests = @()
    if (-not $SkipEndpointTest) {
        foreach ($instance in @($RevitState.Instances)) {
            if (-not $instance.Year) { continue }
            $url = "http://localhost/RevitServerAdminRESTService$($instance.Year)/AdminRESTService.svc"
            $watch = [Diagnostics.Stopwatch]::StartNew(); $status=''; $errorText=''
            try { $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 20 -ErrorAction Stop; $status=$response.StatusCode }
            catch { if ($null -ne $_.Exception.Response) { $status=[int]$_.Exception.Response.StatusCode }; $errorText=$_.Exception.Message }
            $watch.Stop()
            $endpointTests += [pscustomobject]@{Instance=$instance.Name;Url=$url;Status=$status;Milliseconds=$watch.ElapsedMilliseconds;Error=$errorText}
        }
    }

    $missingEndpoints = @()
    try {
        $wcfEvents = @(Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='System.ServiceModel 4.0.0.0';Id=3;StartTime=$Since} -ErrorAction Stop)
        $requests = @($wcfEvents | ForEach-Object { Get-MissingEndpointRequest -Message $_.Message } | Where-Object Endpoint)
        $missingEndpoints = @($requests | Group-Object Endpoint | Sort-Object Count -Descending | ForEach-Object {
            [pscustomobject]@{Endpoint=$_.Name;Year=($_.Group | Select-Object -First 1).Year;Count=$_.Count}
        })
    } catch { }

    $taskCorrelations = @()
    $crashTimes = @($CrashEvents | Where-Object Type -eq 'WAS-5011' | ForEach-Object Time)
    if ($crashTimes.Count -gt 0 -and (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        try {
            foreach ($task in @(Get-ScheduledTask)) {
                $info = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
                if ($null -eq $info -or $info.LastRunTime -lt [datetime]'2000-01-01') { continue }
                foreach ($crashTime in $crashTimes) {
                    $delta = ($crashTime - $info.LastRunTime).TotalMinutes
                    if ([math]::Abs($delta) -le 5) { $taskCorrelations += [pscustomobject]@{Task="$($task.TaskPath)$($task.TaskName)";TaskRun=$info.LastRunTime;CrashTime=$crashTime;DeltaMinutes=[math]::Round($delta,1)} }
                }
            }
        } catch { }
    }

    $w3wpModules = @()
    foreach ($process in @(Get-Process w3wp -ErrorAction SilentlyContinue)) {
        try {
            foreach ($module in @($process.Modules)) { $w3wpModules += [pscustomobject]@{PID=$process.Id;Module=$module.ModuleName;Company=$module.FileVersionInfo.CompanyName;Version=$module.FileVersionInfo.FileVersion;Path=$module.FileName} }
        } catch { }
    }
    $defender = $null
    try {
        $preference = Get-MpPreference -ErrorAction Stop
        $defender = [pscustomobject]@{ExclusionPath=@($preference.ExclusionPath);ExclusionProcess=@($preference.ExclusionProcess);ExclusionExtension=@($preference.ExclusionExtension)}
    } catch { }

    $relatedSpecs = @(
        @{Log='System';Provider='Schannel';Id=36874;Label='TLS handshake'},
        @{Log='System';Provider='NetBT';Id=4321;Label='NetBIOS name conflict'},
        @{Log='System';Provider='Microsoft-Windows-DNS-Client';Id=8016;Label='Dynamic DNS update'},
        @{Log='Application';Provider='VSS';Id=@(13,8193);Label='VSS'},
        @{Log='System';Provider='Service Control Manager';Id=@(7000,7009,7031,7034);Label='Service failures'},
        @{Log='System';Provider='Microsoft-Windows-WAS';Id=@(5002,5021,5117);Label='WAS pool failures'}
    )
    $relatedEvents = @()
    foreach ($spec in $relatedSpecs) {
        try {
            $events = @(Get-WinEvent -FilterHashtable @{LogName=$spec.Log;ProviderName=$spec.Provider;Id=$spec.Id;StartTime=$Since} -ErrorAction Stop)
            $relatedEvents += [pscustomobject]@{Label=$spec.Label;Provider=$spec.Provider;EventId=(@($spec.Id) -join ',');Count=$events.Count;First=($events | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated;Last=($events | Sort-Object TimeCreated | Select-Object -Last 1).TimeCreated}
        } catch { }
    }

    $aeDebug = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug' -ErrorAction SilentlyContinue
    $wer = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps' -ErrorAction SilentlyContinue
    $dumpState = [pscustomobject]@{AeDebugDebugger=if($aeDebug){$aeDebug.Debugger}else{$null};AeDebugAuto=if($aeDebug){$aeDebug.Auto}else{$null};WerDumpFolder=if($wer){$wer.DumpFolder}else{$null};WerDumpType=if($wer){$wer.DumpType}else{$null}}

    [pscustomobject]@{
        NativeModules=@($nativeModules);Features=$features;Binaries=$binaries;DataDirectories=$dataDirectories
        LogErrors=$logErrors;EndpointTests=$endpointTests;MissingEndpoints=$missingEndpoints
        TaskCorrelations=$taskCorrelations;W3wpModules=$w3wpModules;Defender=$defender
        RelatedEvents=$relatedEvents;DumpState=$dumpState
    }
}

Export-ModuleMember -Function New-DiagnosticFinding,ConvertTo-DotNetState,Get-DotNetFrameworkState,ConvertFrom-WuaUpdate,Select-RelevantUpdates,Get-WindowsUpdateState,Find-ApplicableUpdates,Get-CrashTimeline,Get-MissingEndpointRequest,Get-CrashEvents,Get-IisState,Get-RevitServerState,Get-NetworkState,Get-ProfilerState,New-DynamicIpRestrictionPlan,Get-ExtendedDiagnostics
