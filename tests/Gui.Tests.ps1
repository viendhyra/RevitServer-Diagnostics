Describe 'WPF layout contract' {
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework
        [xml]$script:xaml = Get-Content (Join-Path $PSScriptRoot '../ui/MainWindow.xaml') -Raw
    }

    It 'declares every controller control name exactly once' {
        $required = @(
            'NavHome','NavDiagnostic','NavMonitor','NavRepairs','NavReports',
            'RunDiagnosticButton','StartMonitorButton','StopMonitorButton',
            'StartPoolsButton','BaseSettingsButton','RapidFailButton','SetupProcDumpButton',
            'OpenDumpsButton','OpenReportButton','FindingsGrid','PoolsGrid','MonitorGrid',
            'ProgressBar','ProgressText','MainFrame'
        )
        $names = @($script:xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
            @($_.Attributes | Where-Object LocalName -eq 'Name' | ForEach-Object Value)
        })
        foreach ($name in $required) { @($names | Where-Object { $_ -eq $name }).Count | Should -Be 1 }
    }

    It 'loads through XamlReader' {
        $reader = New-Object Xml.XmlNodeReader $script:xaml
        { [Windows.Markup.XamlReader]::Load($reader) } | Should -Not -Throw
    }

    It 'reads BOM-free XAML explicitly as UTF-8 in Windows PowerShell 5.1' {
        $entry = Get-Content (Join-Path $PSScriptRoot '../RevitServer-GUI.ps1') -Raw
        $entry | Should -Match '\[IO\.File\]::ReadAllText\([^\r\n]+\[Text\.Encoding\]::UTF8\)'
    }
}
