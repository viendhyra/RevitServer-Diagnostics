BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Repairs.psm1') -Force
}

Describe 'Repair result contract' {
    It 'rejects unknown repair status' {
        { New-RepairResult -Name 'X' -Status 'Unknown' } | Should -Throw
    }

    It 'creates a changed result with rollback metadata' {
        $result = New-RepairResult -Name 'Pool' -Status Changed -Message 'updated' -Rollback 'restore pool'
        $result.Status | Should -Be 'Changed'
        $result.Rollback | Should -Be 'restore pool'
    }
}

Describe 'Requested repairs' {
    It 'does not request mutations in diagnostic mode' {
        @(Get-RequestedRepairs).Count | Should -Be 0
    }

    It 'does not include Dynamic IP Restrictions in generic repair' {
        @(Get-RequestedRepairs -Repair) | Should -Not -Contain 'DynamicIpRestrictions'
    }

    It 'includes Dynamic IP Restrictions only through its dedicated switch' {
        @(Get-RequestedRepairs -DisableDynamicIpRestrictions) | Should -Contain 'DynamicIpRestrictions'
    }
}

Describe 'Revit pool repair planning' {
    It 'backs up before the first write and ignores non-Revit pools' {
        $plan = New-RevitPoolRepairPlan -Pools @(
            [pscustomobject]@{Name='RevitServerAppPool2024';AutoStart=$false;StartMode='OnDemand';IdleTimeoutMinutes=20;RapidFailMaxCrashes=5},
            [pscustomobject]@{Name='DefaultAppPool';AutoStart=$false;StartMode='OnDemand';IdleTimeoutMinutes=20;RapidFailMaxCrashes=5}
        )
        $plan[0].Action | Should -Be 'BackupIis'
        @($plan | Where-Object Target -eq 'DefaultAppPool').Count | Should -Be 0
        @($plan | Where-Object Action -eq 'SetPool').Count | Should -Be 1
    }

    It 'recognizes only a fully compliant Revit pool state' {
        $good = [pscustomobject]@{AutoStart=$true;StartMode='AlwaysRunning';IdleTimeoutMinutes=0;RapidFailEnabled=$true;RapidFailMaxCrashes=20;State='Started'}
        $bad = [pscustomobject]@{AutoStart=$true;StartMode='AlwaysRunning';IdleTimeoutMinutes=20;RapidFailEnabled=$true;RapidFailMaxCrashes=20;State='Started'}
        (Test-RevitPoolCompliance -Pool $good) | Should -BeTrue
        (Test-RevitPoolCompliance -Pool $bad) | Should -BeFalse
    }
}

Describe 'Focused GUI pool actions' {
    BeforeAll {
        $script:guiPools = @(
            [pscustomobject]@{Name='RevitServerAppPool2024';State='Stopped';AutoStart=$false;StartMode='OnDemand';IdleTimeoutMinutes=20;RapidFailEnabled=$false;RapidFailMaxCrashes=5},
            [pscustomobject]@{Name='DefaultAppPool';State='Stopped';AutoStart=$false;StartMode='OnDemand';IdleTimeoutMinutes=20;RapidFailEnabled=$false;RapidFailMaxCrashes=5}
        )
    }

    It 'previews Rapid-Fail 20 only for target pools and enables protection' {
        $rows = @(New-PoolActionPreview -Pools $script:guiPools -Action RapidFail)
        @($rows.Pool | Sort-Object -Unique) | Should -Be @('RevitServerAppPool2024')
        @($rows | Where-Object Setting -eq 'RapidFailEnabled').Desired | Should -Be 'True'
        @($rows | Where-Object Setting -eq 'RapidFailMaxCrashes').Desired | Should -Be '20'
    }

    It 'previews start only for a stopped target pool' {
        $rows = @(New-PoolActionPreview -Pools $script:guiPools -Action Start)
        $rows.Count | Should -Be 1
        $rows[0].Pool | Should -Be 'RevitServerAppPool2024'
        $rows[0].Desired | Should -Be 'Started'
    }

    It 'previews base settings separately from Rapid-Fail' {
        $rows = @(New-PoolActionPreview -Pools $script:guiPools -Action BaseSettings)
        @($rows.Setting) | Should -Contain 'AutoStart'
        @($rows.Setting) | Should -Contain 'StartMode'
        @($rows.Setting) | Should -Contain 'IdleTimeoutMinutes'
        @($rows.Setting) | Should -Not -Contain 'RapidFailMaxCrashes'
    }
}

Describe 'IIS feature rollback' {
    It 'quotes each feature as a separate array item' {
        New-IisFeatureRollbackCommand -Features @('Web-Server','Web-Asp-Net45') | Should -Be "Uninstall-WindowsFeature -Name @('Web-Server','Web-Asp-Net45')"
    }
}

Describe 'Dynamic IP Restrictions change plan' {
    It 'targets the two child configuration sections explicitly' {
        $plan = New-DynamicIpRestrictionChangePlan -Location 'Default Web Site/RevitServerAdminRESTService2024'
        @($plan.Filter) | Should -Be @(
            'system.webServer/security/dynamicIpSecurity/denyByConcurrentRequests',
            'system.webServer/security/dynamicIpSecurity/denyByRequestRate'
        )
        @($plan.Name | Sort-Object -Unique) | Should -Be @('enabled')
    }
}

Describe 'ProcDump safety' {
    It 'builds the documented full postmortem registration arguments' {
        (New-ProcDumpInstallArguments -DumpPath 'C:\Dumps') -join ' ' | Should -Be '-accepteula -ma -i C:\Dumps'
    }

    It 'rejects a valid signature from a non-Microsoft publisher' {
        $signature = [pscustomobject]@{
            Status='Valid'
            SignerCertificate=[pscustomobject]@{Subject='CN=Example Software Ltd'}
        }
        { Assert-MicrosoftSignature -Signature $signature } | Should -Throw
    }

    It 'accepts a valid Microsoft signature' {
        $signature = [pscustomobject]@{
            Status='Valid'
            SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'}
        }
        { Assert-MicrosoftSignature -Signature $signature } | Should -Not -Throw
    }
}

Describe '.NET Framework 4.8.1 safety gate' {
    It 'refuses an upgrade without snapshot confirmation' {
        { Assert-Net481UpgradeGate -OsCaption 'Microsoft Windows Server 2022 Standard' -SnapshotConfirmed:$false } | Should -Throw
    }

    It 'allows the supported server with snapshot confirmation' {
        { Assert-Net481UpgradeGate -OsCaption 'Microsoft Windows Server 2022 Standard' -SnapshotConfirmed:$true } | Should -Not -Throw
    }

    It 'rejects an unsupported older server' {
        { Assert-Net481UpgradeGate -OsCaption 'Microsoft Windows Server 2019 Standard' -SnapshotConfirmed:$true } | Should -Throw
    }
}
