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

Export-ModuleMember -Function New-DiagnosticFinding,ConvertTo-DotNetState,Get-DotNetFrameworkState,ConvertFrom-WuaUpdate,Select-RelevantUpdates,Get-WindowsUpdateState,Find-ApplicableUpdates,Get-CrashTimeline,Get-MissingEndpointRequest,Get-CrashEvents,Get-IisState,Get-RevitServerState,Get-NetworkState,Get-ProfilerState,New-DynamicIpRestrictionPlan
