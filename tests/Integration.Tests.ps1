Describe 'PowerShell 5.1 compatibility surface' {
    It 'parses every shipped PowerShell file without syntax errors' {
        $root = Split-Path $PSScriptRoot -Parent
        $files = @(Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') -and $_.FullName -notmatch '\\.git\\' })
        $failures = @()
        foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
            if (@($errors).Count -gt 0) {
                $failures += "$($file.FullName): $((@($errors).Message) -join '; ')"
            }
        }
        $failures | Should -BeNullOrEmpty
    }

    It 'keeps every published CLI repair switch' {
        $command = Get-Command (Join-Path $PSScriptRoot '../RevitServer-Diag.ps1')
        @($command.Parameters.Keys) | Should -Contain 'Repair'
        @($command.Parameters.Keys) | Should -Contain 'SetupProcDump'
        @($command.Parameters.Keys) | Should -Contain 'InstallUpdates'
        @($command.Parameters.Keys) | Should -Contain 'UpgradeNet481'
        @($command.Parameters.Keys) | Should -Contain 'DisableDynamicIpRestrictions'
    }
}
