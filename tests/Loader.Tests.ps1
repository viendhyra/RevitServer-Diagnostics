Describe 'Direct launchers' {
    It 'stores Run.ps1 without a UTF-8 BOM' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '../Run.ps1'))
        @($bytes[0],$bytes[1],$bytes[2]) -join ',' | Should -Not -Be '239,187,191'
    }

    It 'stores Run-GUI.ps1 without a UTF-8 BOM' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '../Run-GUI.ps1'))
        @($bytes[0],$bytes[1],$bytes[2]) -join ',' | Should -Not -Be '239,187,191'
    }

    It 'downloads every GUI runtime file' {
        $text = Get-Content (Join-Path $PSScriptRoot '../Run-GUI.ps1') -Raw
        @(
            'RevitServer-GUI.ps1','src/Diagnostics.psm1','src/Repairs.psm1',
            'src/Reporting.psm1','src/Orchestration.psm1','src/PoolMonitor.psm1',
            'src/GuiController.psm1','ui/MainWindow.xaml'
        ) | ForEach-Object { $text | Should -Match ([regex]::Escape($_)) }
    }
}
