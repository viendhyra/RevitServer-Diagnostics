BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Diagnostics.psm1') -Force
}

Describe 'Diagnostic contracts' {
    It 'creates a structured warning' {
        $result = New-DiagnosticFinding -Level WARN -Code 'DISK_LOW' -Message 'Less than 15 percent free'
        $result.Level | Should -Be 'WARN'
        $result.Code | Should -Be 'DISK_LOW'
        $result.Message | Should -Be 'Less than 15 percent free'
    }
}

Describe '.NET state' {
    It 'does not mark clr 4.8.4795.0 as a failure by version alone' {
        $state = ConvertTo-DotNetState -Release 528449 -ClrVersion '4.8.4795.0'
        $state.Health | Should -Not -Be 'FAIL'
        $state.Framework | Should -Be '4.8'
    }

    It 'recognizes 4.8.1 release keys at and above 533320' {
        (ConvertTo-DotNetState -Release 533320 -ClrVersion '4.8.9000.0').Framework | Should -Be '4.8.1'
    }
}

Describe 'Applicable update selection' {
    BeforeAll {
        $script:updates = @(
            [pscustomobject]@{
                Title = '2026-08 Cumulative Update for .NET Framework 3.5 and 4.8'
                Categories = @('.NET')
                IsInstalled = $false
                IsHidden = $false
                KBArticleIDs = @('KB1234567')
            },
            [pscustomobject]@{
                Title = 'Security intelligence update for Microsoft Defender Antivirus'
                Categories = @('Definition Updates')
                IsInstalled = $false
                IsHidden = $false
                KBArticleIDs = @('KB2267602')
            }
        )
    }

    It 'selects only applicable .NET metadata for DotNet' {
        $selected = @(Select-RelevantUpdates -Updates $script:updates -Kind DotNet)
        $selected.Count | Should -Be 1
        $selected[0].KBArticleIDs | Should -Contain 'KB1234567'
    }

    It 'does not invent an update when Windows Update Agent returns none' {
        @(Select-RelevantUpdates -Updates @() -Kind DotNet).Count | Should -Be 0
    }
}

Describe 'Crash correlation' {
    It 'deduplicates paired AppError and WAS events for one crash' {
        $events = @(
            [pscustomobject]@{ Type='AppError-1000'; Time=[datetime]'2026-08-21 09:15:01'; Module='clr.dll'; Code='0xc0000005'; Offset='0x4b2bb1'; Pool='' },
            [pscustomobject]@{ Type='WAS-5011'; Time=[datetime]'2026-08-21 09:15:02'; Module=''; Code=''; Offset=''; Pool='RevitServerAppPool2024' }
        )
        $timeline = Get-CrashTimeline -Events $events -CorrelationSeconds 5
        $timeline.RootCauseCrashCount | Should -Be 1
        $timeline.Events.Count | Should -Be 2
    }

    It 'extracts a missing Revit Server year from an endpoint error' {
        $message = "The service '/RevitServerAdminRESTService2026/AdminRESTService.svc' does not exist."
        $result = Get-MissingEndpointRequest -Message $message
        $result.Year | Should -Be '2026'
        $result.Endpoint | Should -Match 'RevitServerAdminRESTService2026'
    }
}

Describe 'Dynamic IP Restrictions scope' {
    It 'keeps only discovered Revit applications' {
        $plan = New-DynamicIpRestrictionPlan -Applications @('/RevitServerAdminRESTService2024','/OtherApp','/ModelService2022')
        $plan.Targets | Should -Be @('/RevitServerAdminRESTService2024','/ModelService2022')
    }
}

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

Describe 'Dump registration state' {
    It 'treats absent registry values as an unconfigured dump collector' {
        $aeDebug = [pscustomobject]@{ PSPath = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\AeDebug' }
        $wer = [pscustomobject]@{ PSPath = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps' }

        { $script:dumpState = ConvertTo-DumpRegistrationState -AeDebug $aeDebug -Wer $wer } | Should -Not -Throw
        $script:dumpState.AeDebugDebugger | Should -BeNullOrEmpty
        $script:dumpState.AeDebugAuto | Should -BeNullOrEmpty
        $script:dumpState.WerDumpFolder | Should -BeNullOrEmpty
        $script:dumpState.WerDumpType | Should -BeNullOrEmpty
    }

    It 'preserves configured dump collector values' {
        $aeDebug = [pscustomobject]@{ Debugger = 'procdump64.exe -ma %ld %ld'; Auto = '1' }
        $wer = [pscustomobject]@{ DumpFolder = 'C:\Dumps'; DumpType = 2 }

        $state = ConvertTo-DumpRegistrationState -AeDebug $aeDebug -Wer $wer
        $state.AeDebugDebugger | Should -Match 'procdump64'
        $state.AeDebugAuto | Should -Be '1'
        $state.WerDumpFolder | Should -Be 'C:\Dumps'
        $state.WerDumpType | Should -Be 2
    }
}
