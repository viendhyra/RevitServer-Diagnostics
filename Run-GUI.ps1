$ErrorActionPreference = 'Stop'
$base = 'https://raw.githubusercontent.com/viendhyra/RevitServer-Diagnostics/main'
$target = Join-Path $env:TEMP ("RevitServer-Diagnostics-GUI_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $target -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $target 'src') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $target 'ui') -Force | Out-Null

$files = @(
    'RevitServer-GUI.ps1',
    'src/Diagnostics.psm1',
    'src/Repairs.psm1',
    'src/Reporting.psm1',
    'src/Orchestration.psm1',
    'src/PoolMonitor.psm1',
    'src/GuiController.psm1',
    'ui/MainWindow.xaml'
)
foreach ($file in $files) {
    $destination = Join-Path $target ($file -replace '/', '\')
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$file" -OutFile $destination
}

Write-Host "Downloaded from $base" -ForegroundColor Cyan
Write-Host "Local copy: $target" -ForegroundColor Cyan
Write-Host 'Starting Revit Server Diagnostics GUI...' -ForegroundColor Green
& (Join-Path $target 'RevitServer-GUI.ps1')
