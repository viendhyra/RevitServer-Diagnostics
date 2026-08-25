Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Diagnostics.psm1') -Force

function Test-RevitPoolName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    [bool]($Name -match '(?i)Revit|ModelService')
}

function New-PoolMonitorEvent {
    [CmdletBinding()]
    param(
        [datetime]$Time=(Get-Date),
        [ValidateSet('INFO','WARN','FAIL')][string]$Level='INFO',
        [string]$Pool='',[string]$Type='',[int]$EventId=0,[string]$Provider='',
        [string]$Message='',[string]$Details=''
    )
    [pscustomobject]@{
        Time=$Time;Level=$Level;Pool=$Pool;Type=$Type;EventId=$EventId
        Provider=$Provider;Message=$Message;Details=$Details
    }
}

function Get-MonitorRecordMessage {
    param([Parameter(Mandatory)]$Record)
    if ($Record.PSObject.Properties['Message'] -and $Record.Message) { return [string]$Record.Message }
    if ($Record.PSObject.Methods['FormatDescription']) {
        try { return [string]$Record.FormatDescription() } catch { }
    }
    ''
}

function ConvertTo-PoolMonitorEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record,[Parameter(Mandatory)][string[]]$TargetPools)
    $message = Get-MonitorRecordMessage -Record $Record
    $pool = @($TargetPools | Where-Object {
        $message.IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -ge 0
    } | Select-Object -First 1)
    $id = if ($Record.PSObject.Properties['Id']) { [int]$Record.Id } else { 0 }
    $provider = if ($Record.PSObject.Properties['ProviderName']) { [string]$Record.ProviderName } else { '' }
    if ($pool.Count -eq 0 -and $id -eq 1000 -and $message -match '(?i)w3wp\.exe') {
        $pool = @('w3wp.exe')
    }
    if ($pool.Count -eq 0) { return $null }

    $level = 'INFO'
    $type = 'WindowsEvent'
    if ($id -in @(1000,5002,5009,5011)) { $level='FAIL';$type='PoolFailure' }
    elseif ($message -match '(?i)stopp|останов') { $level='WARN';$type='PoolStopped' }
    elseif ($message -match '(?i)start|запущ') { $level='INFO';$type='PoolStarted' }
    $time = if ($Record.PSObject.Properties['TimeCreated'] -and $Record.TimeCreated) { [datetime]$Record.TimeCreated } else { Get-Date }
    New-PoolMonitorEvent -Time $time -Level $level -Pool $pool[0] -Type $type -EventId $id -Provider $provider -Message $message -Details $message
}

function Update-PoolStateTransitions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Previous,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Current,
        [datetime]$Now=(Get-Date)
    )
    $state = @{}
    foreach ($key in $Previous.Keys) { $state[[string]$key] = [string]$Previous[$key] }
    $events = New-Object Collections.ArrayList
    foreach ($pool in @($Current | Where-Object { Test-RevitPoolName -Name ([string]$_.Name) })) {
        $name = [string]$pool.Name
        $currentState = [string]$pool.State
        $hadPrevious = $state.ContainsKey($name)
        $oldState = if ($hadPrevious) { [string]$state[$name] } else { '' }
        $state[$name] = $currentState
        if ($hadPrevious -and $oldState -ne $currentState) {
            $level = if ($currentState -eq 'Started') { 'INFO' } elseif ($currentState -eq 'Stopped') { 'FAIL' } else { 'WARN' }
            [void]$events.Add((New-PoolMonitorEvent -Time $Now -Level $level -Pool $name -Type 'PoolStateChanged' -Message ("{0}: {1} -> {2}" -f $name,$oldState,$currentState) -Details ("Previous={0}; Current={1}" -f $oldState,$currentState)))
        }
    }
    [pscustomobject]@{State=$state;Events=@($events)}
}

function Add-BoundedMonitorEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.ArrayList]$Buffer,[Parameter(Mandatory)]$Event,[ValidateRange(1,100000)][int]$Maximum=1000)
    [void]$Buffer.Add($Event)
    while ($Buffer.Count -gt $Maximum) { $Buffer.RemoveAt(0) }
}

function Write-PoolMonitorCsvEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Event)
    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    @($Event) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -Append
}

function Add-PoolSessionEvent {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Event)
    Add-BoundedMonitorEvent -Buffer $Context.Buffer -Event $Event -Maximum 1000
    Write-PoolMonitorCsvEvent -Path $Context.CsvPath -Event $Event
    if ($null -ne $Context.EventAction) { & $Context.EventAction $Event }
}

function New-EventLogWatcherResource {
    param([string]$LogName,[string]$Query)
    $eventQuery = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($LogName,[System.Diagnostics.Eventing.Reader.PathType]::LogName,$Query)
    New-Object System.Diagnostics.Eventing.Reader.EventLogWatcher($eventQuery)
}

function Start-PoolMonitorSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$TargetPools,
        [Parameter(Mandatory)][string]$CsvPath,
        [scriptblock]$EventAction,
        [scriptblock]$StateProvider,
        [scriptblock]$WatcherFactory,
        [scriptblock]$TimerFactory
    )
    $targets = @($TargetPools | Where-Object { Test-RevitPoolName $_ } | Sort-Object -Unique)
    if ($targets.Count -eq 0) { throw 'Не найдены целевые пулы Revit Server.' }
    if ($null -eq $StateProvider) {
        $StateProvider = { @((Get-IisState).Pools | Where-Object { Test-RevitPoolName $_.Name }) }
    }
    $context = [pscustomobject]@{
        TargetPools=$targets;CsvPath=$CsvPath;EventAction=$EventAction;StateProvider=$StateProvider
        Buffer=(New-Object Collections.ArrayList);State=@{}
    }
    foreach ($pool in @(& $StateProvider)) { $context.State[[string]$pool.Name] = [string]$pool.State }

    $watchers = New-Object Collections.ArrayList
    $subscriptions = New-Object Collections.ArrayList
    $specs = @(
        [pscustomobject]@{Log='Application';Query="*[System[(EventID=1000) and Provider[@Name='Application Error']]]"},
        [pscustomobject]@{Log='System';Query="*[System[(EventID=5002 or EventID=5009 or EventID=5011) and (Provider[@Name='Microsoft-Windows-WAS'] or Provider[@Name='Microsoft-Windows-W3SVC-WP'])]]"}
    )
    foreach ($spec in $specs) {
        $watcher = if ($null -ne $WatcherFactory) { & $WatcherFactory $spec.Log $spec.Query } else { New-EventLogWatcherResource -LogName $spec.Log -Query $spec.Query }
        [void]$watchers.Add($watcher)
        $subscription = Register-ObjectEvent -InputObject $watcher -EventName EventRecordWritten -MessageData $context -Action {
            if ($null -ne $EventArgs.EventException -or $null -eq $EventArgs.EventRecord) { return }
            $normalized = ConvertTo-PoolMonitorEvent -Record $EventArgs.EventRecord -TargetPools $event.MessageData.TargetPools
            if ($null -ne $normalized) { Add-PoolSessionEvent -Context $event.MessageData -Event $normalized }
        }
        [void]$subscriptions.Add($subscription)
        $watcher.Enabled = $true
    }

    $timer = if ($null -ne $TimerFactory) { & $TimerFactory } else { New-Object Timers.Timer 5000 }
    $timerSubscription = Register-ObjectEvent -InputObject $timer -EventName Elapsed -MessageData $context -Action {
        try {
            $current = @(& $event.MessageData.StateProvider)
            $transition = Update-PoolStateTransitions -Previous $event.MessageData.State -Current $current -Now (Get-Date)
            $event.MessageData.State = $transition.State
            foreach ($row in @($transition.Events)) { Add-PoolSessionEvent -Context $event.MessageData -Event $row }
        } catch { }
    }
    [void]$subscriptions.Add($timerSubscription)
    if ($timer.PSObject.Properties['AutoReset']) { $timer.AutoReset = $true }
    if ($timer.PSObject.Methods['Start']) { $timer.Start() }

    [pscustomobject]@{Watchers=@($watchers);Timer=$timer;Subscriptions=@($subscriptions);Handlers=@();Context=$context;Stopped=$false}
}

function Stop-PoolMonitorSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    if ($Session.PSObject.Properties['Stopped'] -and $Session.Stopped) { return }
    if ($Session.PSObject.Properties['Timer'] -and $null -ne $Session.Timer -and $Session.Timer.PSObject.Methods['Stop']) {
        $Session.Timer.Stop()
    }
    if ($Session.PSObject.Properties['Watchers']) {
        foreach ($watcher in @($Session.Watchers)) {
            if ($watcher.PSObject.Properties['Enabled']) { $watcher.Enabled = $false }
            if ($watcher.PSObject.Methods['Dispose']) { $watcher.Dispose() }
        }
    }
    if ($Session.PSObject.Properties['Subscriptions']) {
        foreach ($subscription in @($Session.Subscriptions)) {
            Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue
            Remove-Job -Id $subscription.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if ($Session.PSObject.Properties['Stopped']) { $Session.Stopped = $true }
}

Export-ModuleMember -Function Test-RevitPoolName,New-PoolMonitorEvent,ConvertTo-PoolMonitorEvent,Update-PoolStateTransitions,Add-BoundedMonitorEvent,Write-PoolMonitorCsvEvent,Start-PoolMonitorSession,Stop-PoolMonitorSession
