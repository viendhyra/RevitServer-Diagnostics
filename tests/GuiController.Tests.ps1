BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/GuiController.psm1') -Force
}

Describe 'GUI controller state' {
    It 'starts in safe idle mode' {
        $state = New-GuiState
        $state.Busy | Should -BeFalse
        $state.MonitorRunning | Should -BeFalse
        $state.Findings.Count | Should -Be 0
        $state.Pools.Count | Should -Be 0
        $state.MonitorEvents.Count | Should -Be 0
    }

    It 'rejects a second diagnostic run' {
        $controller = New-GuiController -ModuleRoot (Join-Path $PSScriptRoot '../src') -ReportRoot $TestDrive
        $controller.State.Busy = $true
        { Start-GuiDiagnostic -Controller $controller -Days 1 } | Should -Throw '*already*'
    }

    It 'closes monitor and diagnostic resources only once' {
        $calls = New-Object Collections.ArrayList
        $controller = New-GuiController -ModuleRoot (Join-Path $PSScriptRoot '../src') -ReportRoot $TestDrive `
            -StopMonitorAction { param($c) [void]$calls.Add('monitor') } `
            -StopDiagnosticAction { param($c) [void]$calls.Add('diagnostic') }
        $controller.Monitor = [pscustomobject]@{Stopped=$false}
        $controller.DiagnosticRunner = [pscustomobject]@{Disposed=$false}

        Close-GuiController -Controller $controller
        Close-GuiController -Controller $controller

        @($calls) | Should -Be @('monitor','diagnostic')
        $controller.Closed | Should -BeTrue
    }

    It 'moves queued monitor events into the visible collection' {
        $controller = New-GuiController -ModuleRoot (Join-Path $PSScriptRoot '../src') -ReportRoot $TestDrive
        $controller.MonitorQueue.Enqueue([pscustomobject]@{Level='FAIL';Pool='RevitServerAppPool2024'})
        Sync-GuiQueues -Controller $controller
        $controller.State.MonitorEvents.Count | Should -Be 1
        $controller.State.ActiveProblemCount | Should -Be 1
    }
}
