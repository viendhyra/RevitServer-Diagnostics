Describe 'Direct launchers' {
    It 'stores Run.ps1 without a UTF-8 BOM' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '../Run.ps1'))
        @($bytes[0],$bytes[1],$bytes[2]) -join ',' | Should -Not -Be '239,187,191'
    }
}
