Set-StrictMode -Version 2.0

function New-RepairResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('AlreadyCompliant','Changed','Failed','Skipped','RebootRequired')][string]$Status,
        [string]$Message = '',
        [string]$Rollback = ''
    )
    [pscustomobject]@{Time=Get-Date;Name=$Name;Status=$Status;Message=$Message;Rollback=$Rollback}
}

function Get-RequestedRepairs {
    [CmdletBinding()]
    param(
        [switch]$Repair,
        [switch]$SetupProcDump,
        [switch]$InstallUpdates,
        [switch]$UpgradeNet481,
        [switch]$DisableDynamicIpRestrictions
    )
    if ($Repair) { 'BasicRepair' }
    if ($SetupProcDump) { 'ProcDump' }
    if ($InstallUpdates) { 'Updates' }
    if ($UpgradeNet481) { 'Net481' }
    if ($DisableDynamicIpRestrictions) { 'DynamicIpRestrictions' }
}

function New-RevitPoolRepairPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Pools)
    $targets = @($Pools | Where-Object { $_.Name -match '(?i)Revit|ModelService' })
    if ($targets.Count -eq 0) { return @() }
    $plan = @([pscustomobject]@{Action='BackupIis';Target='applicationHost.config';Values=$null})
    foreach ($pool in $targets) {
        $desired = [ordered]@{AutoStart=$true;StartMode='AlwaysRunning';IdleTimeoutMinutes=0;RapidFailEnabled=$true;RapidFailMaxCrashes=20}
        $plan += [pscustomobject]@{Action='SetPool';Target=$pool.Name;Values=[pscustomobject]$desired}
    }
    $plan
}

function Test-RevitPoolCompliance {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pool)
    [bool](
        $Pool.AutoStart -eq $true -and
        [string]$Pool.StartMode -eq 'AlwaysRunning' -and
        [double]$Pool.IdleTimeoutMinutes -eq 0 -and
        $Pool.RapidFailEnabled -eq $true -and
        [int]$Pool.RapidFailMaxCrashes -eq 20 -and
        [string]$Pool.State -eq 'Started'
    )
}

function New-PoolActionPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pools,
        [Parameter(Mandatory)][ValidateSet('Start','BaseSettings','RapidFail')][string]$Action
    )
    foreach ($pool in @($Pools | Where-Object { $_.Name -match '(?i)Revit|ModelService' })) {
        switch ($Action) {
            'Start' {
                if ([string]$pool.State -ne 'Started') {
                    [pscustomobject]@{Pool=$pool.Name;Setting='State';Current=[string]$pool.State;Desired='Started'}
                }
            }
            'BaseSettings' {
                [pscustomobject]@{Pool=$pool.Name;Setting='AutoStart';Current=[string]$pool.AutoStart;Desired='True'}
                [pscustomobject]@{Pool=$pool.Name;Setting='StartMode';Current=[string]$pool.StartMode;Desired='AlwaysRunning'}
                [pscustomobject]@{Pool=$pool.Name;Setting='IdleTimeoutMinutes';Current=[string]$pool.IdleTimeoutMinutes;Desired='0'}
            }
            'RapidFail' {
                [pscustomobject]@{Pool=$pool.Name;Setting='RapidFailEnabled';Current=[string]$pool.RapidFailEnabled;Desired='True'}
                [pscustomobject]@{Pool=$pool.Name;Setting='RapidFailMaxCrashes';Current=[string]$pool.RapidFailMaxCrashes;Desired='20'}
            }
        }
    }
}

function Invoke-PoolAction {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pools,
        [Parameter(Mandatory)][ValidateSet('Start','BaseSettings','RapidFail')][string]$Action
    )
    Assert-Administrator
    Import-Module WebAdministration -ErrorAction Stop
    $targets = @($Pools | Where-Object { $_.Name -match '(?i)Revit|ModelService' })
    if ($targets.Count -eq 0) { return New-RepairResult -Name "PoolAction:$Action" -Status Skipped -Message 'No Revit Server pools were found.' }
    if ($Action -ne 'Start') { Backup-IisConfiguration -Context $Context }
    $results = New-Object Collections.ArrayList
    foreach ($pool in $targets) {
        $preview = @(New-PoolActionPreview -Pools @($pool) -Action $Action)
        if ($preview.Count -eq 0) {
            [void]$results.Add((New-RepairResult -Name "$Action`:$($pool.Name)" -Status AlreadyCompliant -Message 'The requested state is already active.'))
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($pool.Name,("Apply pool action {0}" -f $Action))) {
            [void]$results.Add((New-RepairResult -Name "$Action`:$($pool.Name)" -Status Skipped -Message 'Confirmation declined.'))
            continue
        }
        try {
            $iisPath = "IIS:\AppPools\$($pool.Name)"
            switch ($Action) {
                'Start' { Start-WebAppPool -Name $pool.Name }
                'BaseSettings' {
                    Set-ItemProperty $iisPath -Name autoStart -Value $true
                    Set-ItemProperty $iisPath -Name startMode -Value 'AlwaysRunning'
                    Set-ItemProperty $iisPath -Name processModel.idleTimeout -Value ([timespan]::Zero)
                }
                'RapidFail' {
                    Set-ItemProperty $iisPath -Name failure.rapidFailProtection -Value $true
                    Set-ItemProperty $iisPath -Name failure.rapidFailProtectionMaxCrashes -Value 20
                }
            }
            $verifiedItem = Get-Item $iisPath
            $verifiedState = [string](Get-WebAppPoolState -Name $pool.Name).Value
            $verified = switch ($Action) {
                'Start' { $verifiedState -eq 'Started' }
                'BaseSettings' { $verifiedItem.autoStart -eq $true -and [string]$verifiedItem.startMode -eq 'AlwaysRunning' -and [double]$verifiedItem.processModel.idleTimeout.TotalMinutes -eq 0 }
                'RapidFail' { $verifiedItem.failure.rapidFailProtection -eq $true -and [int]$verifiedItem.failure.rapidFailProtectionMaxCrashes -eq 20 }
            }
            if (-not $verified) { throw 'IIS accepted the write but verification did not match the requested state.' }
            [void]$results.Add((New-RepairResult -Name "$Action`:$($pool.Name)" -Status Changed -Message 'The requested state was written and verified.'))
        } catch {
            [void]$results.Add((New-RepairResult -Name "$Action`:$($pool.Name)" -Status Failed -Message $_.Exception.Message))
        }
    }
    @($results)
}

function New-IisFeatureRollbackCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Features)
    $quoted = @($Features | ForEach-Object { "'" + ($_ -replace "'","''") + "'" })
    "Uninstall-WindowsFeature -Name @($($quoted -join ','))"
}

function New-DynamicIpRestrictionChangePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Location)
    @(
        [pscustomobject]@{Location=$Location;Filter='system.webServer/security/dynamicIpSecurity/denyByConcurrentRequests';Name='enabled';Value=$false},
        [pscustomobject]@{Location=$Location;Filter='system.webServer/security/dynamicIpSecurity/denyByRequestRate';Name='enabled';Value=$false}
    )
}

function New-RepairContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BasePath)
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $path = Join-Path $BasePath "Backup_$($env:COMPUTERNAME)_$stamp"
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    [pscustomobject]@{BackupPath=$path;RollbackLines=(New-Object System.Collections.ArrayList);IisBackedUp=$false}
}

function Add-RollbackOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$Command)
    [void]$Context.RollbackLines.Add($Command)
}

function Backup-IisConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    if ($Context.IisBackedUp) { return }
    $source = Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
    if (-not (Test-Path -LiteralPath $source)) { throw "IIS configuration not found: $source" }
    $destination = Join-Path $Context.BackupPath 'applicationHost.config'
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Add-RollbackOperation -Context $Context -Command ("Copy-Item -LiteralPath '{0}' -Destination '{1}' -Force" -f ($destination -replace "'","''"),($source -replace "'","''"))
    $Context.IisBackedUp = $true
}

function Complete-RollbackScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $path = Join-Path $Context.BackupPath 'Rollback.ps1'
    $lines = @(
        "# Generated $(Get-Date -Format s)",
        "# Run from an elevated Windows PowerShell prompt.",
        "`$ErrorActionPreference = 'Stop'"
    )
    $operations = @($Context.RollbackLines)
    [array]::Reverse($operations)
    $lines += $operations
    $lines | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

function Assert-Administrator {
    [CmdletBinding()]
    param()
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This repair requires an elevated Windows PowerShell session.'
    }
}

function Invoke-RevitBasicRepair {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$IisState,
        [Parameter(Mandatory)]$RevitState
    )
    Assert-Administrator
    $results = New-Object System.Collections.ArrayList
    foreach ($featureResult in @(Install-RequiredIisFeatures -Context $Context -Confirm:$false)) { [void]$results.Add($featureResult) }
    Import-Module WebAdministration -ErrorAction Stop
    $poolPlan = @(New-RevitPoolRepairPlan -Pools $IisState.Pools)
    if ($poolPlan.Count -gt 0) { Backup-IisConfiguration -Context $Context }
    foreach ($item in @($poolPlan | Where-Object Action -eq 'SetPool')) {
        if (-not $PSCmdlet.ShouldProcess($item.Target,'Set Revit Server IIS pool safety settings')) { continue }
        try {
            $iisPath = "IIS:\AppPools\$($item.Target)"
            Set-ItemProperty $iisPath -Name autoStart -Value $true
            Set-ItemProperty $iisPath -Name startMode -Value 'AlwaysRunning'
            Set-ItemProperty $iisPath -Name processModel.idleTimeout -Value ([timespan]::Zero)
            Set-ItemProperty $iisPath -Name failure.rapidFailProtection -Value $true
            Set-ItemProperty $iisPath -Name failure.rapidFailProtectionMaxCrashes -Value 20
            if ((Get-WebAppPoolState -Name $item.Target).Value -ne 'Started') { Start-WebAppPool -Name $item.Target }
            $verifiedItem = Get-Item $iisPath
            $verified = [pscustomobject]@{
                AutoStart=$verifiedItem.autoStart;StartMode=[string]$verifiedItem.startMode
                IdleTimeoutMinutes=$verifiedItem.processModel.idleTimeout.TotalMinutes
                RapidFailEnabled=$verifiedItem.failure.rapidFailProtection
                RapidFailMaxCrashes=$verifiedItem.failure.rapidFailProtectionMaxCrashes
                State=(Get-WebAppPoolState -Name $item.Target).Value
            }
            if (-not (Test-RevitPoolCompliance -Pool $verified)) { throw 'IIS accepted the write but verification did not match the required state.' }
            [void]$results.Add((New-RepairResult -Name "Pool:$($item.Target)" -Status Changed -Message 'Settings were written and verified: autoStart, AlwaysRunning, idle timeout 0, Rapid-Fail 20, pool started.'))
        } catch {
            [void]$results.Add((New-RepairResult -Name "Pool:$($item.Target)" -Status Failed -Message $_.Exception.Message))
        }
    }
    $revitSiteNames = @($IisState.Applications | Where-Object { $_.Path -match '(?i)RevitServer|ModelService' } | ForEach-Object Site | Sort-Object -Unique)
    foreach ($site in @($IisState.Sites | Where-Object { $_.Name -in $revitSiteNames -and $_.State -ne 'Started' })) {
        if ($PSCmdlet.ShouldProcess($site.Name,'Start Revit Server IIS site')) {
            try { Start-Website -Name $site.Name; [void]$results.Add((New-RepairResult -Name "Site:$($site.Name)" -Status Changed -Message 'Site started.')) }
            catch { [void]$results.Add((New-RepairResult -Name "Site:$($site.Name)" -Status Failed -Message $_.Exception.Message)) }
        }
    }
    foreach ($service in @($RevitState.Services | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' })) {
        if ($PSCmdlet.ShouldProcess($service.Name,'Start automatic Revit/Autodesk service')) {
            try { Start-Service -Name $service.Name -ErrorAction Stop; [void]$results.Add((New-RepairResult -Name "Service:$($service.Name)" -Status Changed -Message 'Service started.')) }
            catch { [void]$results.Add((New-RepairResult -Name "Service:$($service.Name)" -Status Failed -Message $_.Exception.Message)) }
        }
    }
    @($results)
}

function Install-RequiredIisFeatures {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)]$Context)
    Assert-Administrator
    $required = @(
        'Web-Server','Web-Asp-Net45','Web-Net-Ext45','Web-ISAPI-Ext','Web-ISAPI-Filter',
        'Web-Windows-Auth','Web-Static-Content','Web-Default-Doc','Web-Http-Errors',
        'Web-Http-Logging','Web-Request-Monitor','NET-WCF-HTTP-Activation45','Web-Mgmt-Console'
    )
    if (-not (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) {
        return New-RepairResult -Name 'IisFeatures' -Status Skipped -Message 'ServerManager cmdlets are unavailable on this operating system.'
    }
    $missing = @(Get-WindowsFeature -Name $required | Where-Object InstallState -ne 'Installed' | ForEach-Object Name)
    if ($missing.Count -eq 0) { return New-RepairResult -Name 'IisFeatures' -Status AlreadyCompliant -Message 'Required IIS features are installed.' }
    if (-not $PSCmdlet.ShouldProcess(($missing -join ', '),'Install required Revit Server IIS features')) {
        return New-RepairResult -Name 'IisFeatures' -Status Skipped -Message 'Confirmation declined.'
    }
    try {
        $result = Install-WindowsFeature -Name $missing -IncludeManagementTools -ErrorAction Stop
        Add-RollbackOperation -Context $Context -Command (New-IisFeatureRollbackCommand -Features $missing)
        $status = if ($result.RestartNeeded -eq 'Yes') { 'RebootRequired' } else { 'Changed' }
        New-RepairResult -Name 'IisFeatures' -Status $status -Message "Installed: $($missing -join ', '). RestartNeeded=$($result.RestartNeeded)"
    } catch { New-RepairResult -Name 'IisFeatures' -Status Failed -Message $_.Exception.Message }
}

function Register-MicrosoftUpdate {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param()
    Assert-Administrator
    $manager = New-Object -ComObject Microsoft.Update.ServiceManager
    $id = '7971f918-a847-4430-9279-4a52d1efe18d'
    if (@($manager.Services | Where-Object ServiceID -eq $id).Count -gt 0) {
        return New-RepairResult -Name 'MicrosoftUpdate' -Status AlreadyCompliant -Message 'Microsoft Update is already registered.'
    }
    if ($PSCmdlet.ShouldProcess('Microsoft Update','Register update service')) {
        try {
            [void]$manager.AddService2($id,7,'')
            return New-RepairResult -Name 'MicrosoftUpdate' -Status Changed -Message 'Microsoft Update registered.'
        } catch { return New-RepairResult -Name 'MicrosoftUpdate' -Status Failed -Message $_.Exception.Message }
    }
    New-RepairResult -Name 'MicrosoftUpdate' -Status Skipped -Message 'Confirmation declined.'
}

function New-ProcDumpInstallArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DumpPath)
    @('-accepteula','-ma','-i',$DumpPath)
}

function Assert-MicrosoftSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Signature)
    if ([string]$Signature.Status -ne 'Valid') { throw "Invalid Authenticode signature: $($Signature.Status)" }
    if ($null -eq $Signature.SignerCertificate -or [string]$Signature.SignerCertificate.Subject -notmatch '(?i)Microsoft Corporation') {
        throw 'The file is not signed by Microsoft Corporation.'
    }
}

function Install-VerifiedProcDump {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$InstallPath = 'C:\Tools\Sysinternals\ProcDump',
        [string]$DumpPath = 'C:\Dumps\RevitServer'
    )
    Assert-Administrator
    if (-not $PSCmdlet.ShouldProcess($InstallPath,'Download, verify and configure ProcDump')) {
        return New-RepairResult -Name 'ProcDump' -Status Skipped -Message 'Confirmation declined.'
    }
    try {
        New-Item -ItemType Directory -Path $InstallPath,$DumpPath -Force | Out-Null
        $zip = Join-Path $env:TEMP 'Procdump.zip'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://download.sysinternals.com/files/Procdump.zip' -OutFile $zip
        $extract = Join-Path $env:TEMP ("ProcDump_" + [guid]::NewGuid().ToString('N'))
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $source = Join-Path $extract 'procdump64.exe'
        if (-not (Test-Path -LiteralPath $source)) { throw 'procdump64.exe is missing from the official archive.' }
        Assert-MicrosoftSignature -Signature (Get-AuthenticodeSignature -FilePath $source)
        $exe = Join-Path $InstallPath 'procdump64.exe'
        Copy-Item -LiteralPath $source -Destination $exe -Force
        $ae = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug' -ErrorAction SilentlyContinue
        $ae | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Context.BackupPath 'AeDebug-before.json') -Encoding UTF8
        $args = New-ProcDumpInstallArguments -DumpPath $DumpPath
        $process = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -ne 0) { throw "ProcDump exited with code $($process.ExitCode)." }
        $registered = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug' -ErrorAction Stop
        if ([string]$registered.Debugger -notmatch '(?i)procdump') { throw 'ProcDump registration was not found in AeDebug.' }
        Add-RollbackOperation -Context $Context -Command ("& '{0}' -u" -f ($exe -replace "'","''"))
        New-RepairResult -Name 'ProcDump' -Status Changed -Message "Full postmortem dumps configured in $DumpPath" -Rollback "$exe -u"
    } catch { New-RepairResult -Name 'ProcDump' -Status Failed -Message $_.Exception.Message }
}

function Assert-Net481UpgradeGate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OsCaption,[Parameter(Mandatory)][bool]$SnapshotConfirmed)
    if (-not $SnapshotConfirmed) { throw 'A verified VM snapshot/backup must be confirmed with -SnapshotConfirmed.' }
    if ($OsCaption -notmatch '(?i)Windows Server 2022') {
        throw ".NET Framework 4.8.1 upgrade mode is enabled only for Windows Server 2022; detected: $OsCaption"
    }
}

function Install-Net481Upgrade {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][bool]$SnapshotConfirmed,
        [switch]$AutoReboot
    )
    Assert-Administrator
    $os = Get-CimInstance Win32_OperatingSystem
    Assert-Net481UpgradeGate -OsCaption $os.Caption -SnapshotConfirmed $SnapshotConfirmed
    if (-not (Test-Path -LiteralPath $InstallerPath)) { throw "Installer not found: $InstallerPath" }
    Assert-MicrosoftSignature -Signature (Get-AuthenticodeSignature -FilePath $InstallerPath)
    if (-not $PSCmdlet.ShouldProcess($os.Caption,'Install .NET Framework 4.8.1 in-place upgrade')) {
        return New-RepairResult -Name 'Net481' -Status Skipped -Message 'Confirmation declined.'
    }
    $arguments = @('/q','/norestart')
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0,1641,3010)) { return New-RepairResult -Name 'Net481' -Status Failed -Message "Installer exit code $($process.ExitCode)." }
    if ($AutoReboot) { shutdown.exe /r /t 60 /c '.NET Framework 4.8.1 installation completed' }
    New-RepairResult -Name 'Net481' -Status RebootRequired -Message 'Installation completed; reboot is required.'
}

function Install-ApplicableUpdates {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)][object[]]$Updates,[switch]$AutoReboot)
    Assert-Administrator
    if (@($Updates).Count -eq 0) { return New-RepairResult -Name 'WindowsUpdates' -Status AlreadyCompliant -Message 'No selected applicable updates.' }
    if (-not $PSCmdlet.ShouldProcess((@($Updates.Title) -join '; '),'Download and install selected updates')) {
        return New-RepairResult -Name 'WindowsUpdates' -Status Skipped -Message 'Confirmation declined.'
    }
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $collection = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($item in $Updates) {
            $raw = $item.Raw
            if (-not $raw.EulaAccepted) { $raw.AcceptEula() }
            [void]$collection.Add($raw)
        }
        $downloader = $session.CreateUpdateDownloader(); $downloader.Updates = $collection
        $downloadResult = $downloader.Download()
        if ($downloadResult.ResultCode -notin @(2,3)) { throw "Download result code $($downloadResult.ResultCode), HRESULT $($downloadResult.HResult)" }
        $installer = $session.CreateUpdateInstaller(); $installer.Updates = $collection
        $installResult = $installer.Install()
        $status = if ($installResult.RebootRequired) { 'RebootRequired' } elseif ($installResult.ResultCode -in @(2,3)) { 'Changed' } else { 'Failed' }
        if ($AutoReboot -and $installResult.RebootRequired) { shutdown.exe /r /t 60 /c 'Windows updates completed' }
        New-RepairResult -Name 'WindowsUpdates' -Status $status -Message "Result=$($installResult.ResultCode); HRESULT=$($installResult.HResult); Reboot=$($installResult.RebootRequired)"
    } catch { New-RepairResult -Name 'WindowsUpdates' -Status Failed -Message $_.Exception.Message }
}

function Disable-RevitDynamicIpRestrictions {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string[]]$ApplicationPaths)
    Assert-Administrator
    Import-Module WebAdministration -ErrorAction Stop
    $targets = @(New-DynamicIpRestrictionPlanLocal -Applications $ApplicationPaths)
    if ($targets.Count -eq 0) { return New-RepairResult -Name 'DynamicIpRestrictions' -Status Skipped -Message 'No Revit application paths were discovered.' }
    Backup-IisConfiguration -Context $Context
    $results = @()
    foreach ($target in $targets) {
        if (-not $PSCmdlet.ShouldProcess($target,'Disable Dynamic IP Restrictions for Revit application scope')) { continue }
        try {
            foreach ($change in @(New-DynamicIpRestrictionChangePlan -Location $target)) {
                Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $change.Location -Filter $change.Filter -Name $change.Name -Value $change.Value
            }
            $results += New-RepairResult -Name "DynamicIpRestrictions:$target" -Status Changed -Message 'Both dynamic deny rules disabled at Revit scope.'
        } catch { $results += New-RepairResult -Name "DynamicIpRestrictions:$target" -Status Failed -Message $_.Exception.Message }
    }
    $results
}

function New-DynamicIpRestrictionPlanLocal {
    param([string[]]$Applications)
    @($Applications | Where-Object { $_ -match '(?i)RevitServer|ModelService' })
}

Export-ModuleMember -Function New-RepairResult,Get-RequestedRepairs,New-RevitPoolRepairPlan,Test-RevitPoolCompliance,New-PoolActionPreview,Invoke-PoolAction,New-IisFeatureRollbackCommand,New-DynamicIpRestrictionChangePlan,New-RepairContext,Add-RollbackOperation,Backup-IisConfiguration,Complete-RollbackScript,Invoke-RevitBasicRepair,Install-RequiredIisFeatures,Register-MicrosoftUpdate,New-ProcDumpInstallArguments,Assert-MicrosoftSignature,Install-VerifiedProcDump,Assert-Net481UpgradeGate,Install-Net481Upgrade,Install-ApplicableUpdates,Disable-RevitDynamicIpRestrictions
