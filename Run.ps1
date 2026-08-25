$ErrorActionPreference = 'Stop'
$base = 'https://raw.githubusercontent.com/viendhyra/RevitServer-Diagnostics/main'
$target = Join-Path $env:TEMP ("RevitServer-Diagnostics_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
$src = Join-Path $target 'src'
New-Item -ItemType Directory -Path $src -Force | Out-Null

$files = @(
    'RevitServer-Diag.ps1',
    'src/Diagnostics.psm1',
    'src/Repairs.psm1',
    'src/Reporting.psm1'
)
foreach ($file in $files) {
    $destination = Join-Path $target ($file -replace '/', '\')
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$file" -OutFile $destination
}

Write-Host "Скрипт загружен из $base" -ForegroundColor Cyan
Write-Host "Локальная копия: $target" -ForegroundColor Cyan
Write-Host 'Запускается безопасный режим: только диагностика.' -ForegroundColor Green
& (Join-Path $target 'RevitServer-Diag.ps1')
