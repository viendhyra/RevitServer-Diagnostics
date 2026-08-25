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
}
