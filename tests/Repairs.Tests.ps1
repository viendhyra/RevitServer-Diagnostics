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
