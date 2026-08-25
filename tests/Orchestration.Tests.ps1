BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Orchestration.psm1') -Force
}

Describe 'Diagnostic orchestration contract' {
    It 'publishes monotonic progress and returns a structured snapshot' {
        $steps = New-Object Collections.ArrayList
        $collectors = [ordered]@{
            Environment = { [pscustomobject]@{Computer='TEST';OS='Windows';Version='10';Build='1';Disks=@()} }
            DotNet = { [pscustomobject]@{Framework='4.8';Release=528449;ClrVersion='4.8.4795.0';Files=@()} }
            Updates = { [pscustomobject]@{State=[pscustomobject]@{MicrosoftUpdateRegistered=$true};Available=@()} }
            Iis = { [pscustomobject]@{Available=$true;Pools=@();Sites=@();Applications=@()} }
            Revit = { [pscustomobject]@{Instances=@();Services=@()} }
            Crashes = { [pscustomobject]@{RootCauseCrashCount=0;Events=@();Signatures=@()} }
            Network = { [pscustomobject]@{Adapters=@()} }
            Profiler = { [pscustomobject]@{InjectionSuspected=$false;Variables=@()} }
            Extended = { [pscustomobject]@{Features=@();EndpointTests=@();LogErrors=@();MissingEndpoints=@();TaskCorrelations=@();DumpState=[pscustomobject]@{AeDebugDebugger='configured';WerDumpType=2};NativeModules=@();Binaries=@();DataDirectories=@();W3wpModules=@();RelatedEvents=@()} }
        }

        $result = Invoke-RevitServerDiagnostic -Days 1 -OutDir $TestDrive -SkipEndpointTest `
            -Collectors $collectors -ProgressAction { param($p) [void]$steps.Add($p.Percent) }

        $result.Snapshot.Environment.Computer | Should -Be 'TEST'
        $result.ReportPath | Should -Not -BeNullOrEmpty
        $result.HtmlPath | Should -Exist
        @($steps) | Should -Be (@($steps) | Sort-Object)
        $steps[-1] | Should -Be 100
    }

    It 'turns a collector exception into a finding instead of stopping' {
        $collectors = [ordered]@{
            Environment = { throw 'environment unavailable' }
        }
        $result = Invoke-RevitServerDiagnostic -Days 1 -OutDir $TestDrive -Collectors $collectors
        @($result.Findings | Where-Object Code -eq 'COLLECTOR_ENVIRONMENT_FAILED').Count | Should -Be 1
    }
}
