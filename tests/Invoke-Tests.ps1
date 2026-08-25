$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.5.0 -ErrorAction Stop

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = Join-Path $PSScriptRoot 'TestResults.xml'
$config.TestResult.OutputFormat = 'NUnitXml'

$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0) { exit 1 }
