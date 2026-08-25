BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/PoolMonitor.psm1') -Force
}

Describe 'Pool monitor classification' {
    It 'accepts only Revit or ModelService pools' {
        Test-RevitPoolName 'RevitServerAppPool2024' | Should -BeTrue
        Test-RevitPoolName 'ModelService2022' | Should -BeTrue
        Test-RevitPoolName 'DefaultAppPool' | Should -BeFalse
    }

    It 'normalizes a related WAS failure' {
        $record = [pscustomobject]@{TimeCreated=[datetime]'2026-08-25 14:00';Id=5011;ProviderName='Microsoft-Windows-WAS';Message='Application pool RevitServerAppPool2024 failed communication with w3wp.exe'}
        $event = ConvertTo-PoolMonitorEvent -Record $record -TargetPools @('RevitServerAppPool2024')
        $event.Level | Should -Be 'FAIL'
        $event.Pool | Should -Be 'RevitServerAppPool2024'
        $event.EventId | Should -Be 5011
    }

    It 'drops unrelated events' {
        $record = [pscustomobject]@{TimeCreated=Get-Date;Id=5011;ProviderName='Microsoft-Windows-WAS';Message='DefaultAppPool stopped'}
        ConvertTo-PoolMonitorEvent -Record $record -TargetPools @('RevitServerAppPool2024') | Should -BeNullOrEmpty
    }

    It 'emits a row only when state changes' {
        $previous = @{RevitServerAppPool2024='Started'}
        $result = Update-PoolStateTransitions -Previous $previous -Current @([pscustomobject]@{Name='RevitServerAppPool2024';State='Stopped'}) -Now ([datetime]'2026-08-25 14:01')
        $result.Events.Count | Should -Be 1
        $result.Events[0].Level | Should -Be 'FAIL'
        $again = Update-PoolStateTransitions -Previous $result.State -Current @([pscustomobject]@{Name='RevitServerAppPool2024';State='Stopped'}) -Now ([datetime]'2026-08-25 14:02')
        $again.Events.Count | Should -Be 0
    }

    It 'keeps the newest 1000 monitor rows' {
        $buffer = New-Object Collections.ArrayList
        1..1005 | ForEach-Object {
            Add-BoundedMonitorEvent -Buffer $buffer -Event ([pscustomobject]@{Sequence=$_}) -Maximum 1000
        }
        $buffer.Count | Should -Be 1000
        $buffer[0].Sequence | Should -Be 6
    }
}

Describe 'Pool monitor lifecycle' {
    It 'disposes every watcher and stops the timer' {
        $watcher1 = [pscustomobject]@{Enabled=$true;Disposed=$false}
        $watcher1 | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
        $watcher2 = [pscustomobject]@{Enabled=$true;Disposed=$false}
        $watcher2 | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
        $timer = [pscustomobject]@{IsEnabled=$true}
        $timer | Add-Member ScriptMethod Stop { $this.IsEnabled=$false }
        $session = [pscustomobject]@{Watchers=@($watcher1,$watcher2);Timer=$timer;Handlers=@();Stopped=$false}

        Stop-PoolMonitorSession -Session $session

        $watcher1.Enabled | Should -BeFalse
        $watcher1.Disposed | Should -BeTrue
        $watcher2.Disposed | Should -BeTrue
        $timer.IsEnabled | Should -BeFalse
        $session.Stopped | Should -BeTrue
    }

    It 'can stop the same session twice' {
        $session = [pscustomobject]@{Watchers=@();Timer=$null;Handlers=@();Stopped=$false}
        Stop-PoolMonitorSession -Session $session
        { Stop-PoolMonitorSession -Session $session } | Should -Not -Throw
    }

    It 'writes a session CSV with one data row' {
        $path = Join-Path $TestDrive 'monitor.csv'
        $event = [pscustomobject]@{Time=[datetime]'2026-08-25';Level='FAIL';Pool='RevitServerAppPool2024';Type='WAS';EventId=5011;Provider='WAS';Message='failed';Details='details'}
        Write-PoolMonitorCsvEvent -Path $path -Event $event
        @(Import-Csv $path).Count | Should -Be 1
    }
}
