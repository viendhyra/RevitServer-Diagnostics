Set-StrictMode -Version 2.0

function Write-DiagnosticFinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Finding)
    $color = switch ($Finding.Level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'FAIL' {'Red'} default {'Gray'} }
    Write-Host ("[{0,-4}] {1}" -f $Finding.Level,$Finding.Message) -ForegroundColor $color
}

function ConvertTo-HtmlEncoded {
    param([AllowNull()][object]$Value)
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Export-RevitDiagnosticReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][object[]]$Findings,
        [object[]]$RepairResults = @()
    )
    New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
    $Snapshot | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $ReportPath 'summary.json') -Encoding UTF8
    @($Findings) | Export-Csv (Join-Path $ReportPath '00_findings.csv') -NoTypeInformation -Encoding UTF8
    if (@($RepairResults).Count -gt 0) { @($RepairResults) | Export-Csv (Join-Path $ReportPath '00_repairs.csv') -NoTypeInformation -Encoding UTF8 }

    $tables = [ordered]@{
        '01_disks.csv' = @($Snapshot.Environment.Disks)
        '02_clr_versions.csv' = @($Snapshot.DotNet.Files)
        '02_updates_available.csv' = @($Snapshot.Updates.Available)
        '03_apppools.csv' = @($Snapshot.Iis.Pools)
        '03_sites.csv' = @($Snapshot.Iis.Sites)
        '04_instances.csv' = @($Snapshot.Revit.Instances)
        '04_services.csv' = @($Snapshot.Revit.Services)
        '05_crashes.csv' = @($Snapshot.Crashes.Events)
        '05_crash_signatures.csv' = @($Snapshot.Crashes.Signatures)
        '08_network.csv' = @($Snapshot.Network.Adapters)
        '03_native_modules.csv' = @($Snapshot.Extended.NativeModules)
        '03_features.csv' = @($Snapshot.Extended.Features)
        '04_binaries.csv' = @($Snapshot.Extended.Binaries)
        '04_data_dirs.csv' = @($Snapshot.Extended.DataDirectories)
        '04_log_errors.csv' = @($Snapshot.Extended.LogErrors)
        '04_endpoint_test.csv' = @($Snapshot.Extended.EndpointTests)
        '04_missing_endpoints.csv' = @($Snapshot.Extended.MissingEndpoints)
        '06_task_correlation.csv' = @($Snapshot.Extended.TaskCorrelations)
        '07_w3wp_modules.csv' = @($Snapshot.Extended.W3wpModules)
        '08_related.csv' = @($Snapshot.Extended.RelatedEvents)
    }
    foreach ($name in $tables.Keys) {
        if (@($tables[$name]).Count -gt 0) { @($tables[$name]) | Export-Csv (Join-Path $ReportPath $name) -NoTypeInformation -Encoding UTF8 }
    }

    $findingHtml = foreach ($finding in $Findings) {
        $class = ([string]$finding.Level).ToLowerInvariant()
        "<p class='finding $class'><strong>$(ConvertTo-HtmlEncoded $finding.Level)</strong> $(ConvertTo-HtmlEncoded $finding.Message)</p>"
    }
    $repairHtml = foreach ($repair in $RepairResults) {
        "<tr><td>$(ConvertTo-HtmlEncoded $repair.Name)</td><td>$(ConvertTo-HtmlEncoded $repair.Status)</td><td>$(ConvertTo-HtmlEncoded $repair.Message)</td></tr>"
    }
    $html = @"
<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Revit Server Diagnostics</title>
<style>body{font-family:Segoe UI,Arial;margin:24px;background:#f7f8fa;color:#202124}h1,h2{color:#075985}.card{background:white;border:1px solid #dbe2ea;border-radius:8px;padding:16px;margin:12px 0}.finding{padding:8px;border-left:5px solid #64748b}.finding.ok{background:#dcfce7;border-color:#16a34a}.finding.warn{background:#fef3c7;border-color:#d97706}.finding.fail{background:#fee2e2;border-color:#dc2626}.finding.info{background:#e0f2fe;border-color:#0284c7}table{border-collapse:collapse;width:100%}th,td{border:1px solid #dbe2ea;padding:7px;text-align:left}th{background:#e2e8f0}</style></head><body>
<h1>Диагностика Revit Server</h1><div class="card"><b>Сервер:</b> $(ConvertTo-HtmlEncoded $Snapshot.Environment.Computer)<br><b>ОС:</b> $(ConvertTo-HtmlEncoded $Snapshot.Environment.OS)<br><b>Дата:</b> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')<br><b>Режим:</b> $(if (@($RepairResults).Count -eq 0) {'Только диагностика'} else {'Диагностика и выбранные исправления'})</div>
<h2>Ключевые находки</h2><div class="card">$($findingHtml -join "`n")</div>
<h2>Исправления</h2><div class="card"><table><tr><th>Операция</th><th>Результат</th><th>Описание</th></tr>$($repairHtml -join "`n")</table></div>
<h2>Файлы отчёта</h2><div class="card">Полные таблицы находятся рядом с этим HTML-файлом в CSV и JSON.</div>
</body></html>
"@
    $htmlPath = Join-Path $ReportPath 'REPORT.html'
    $html | Set-Content -LiteralPath $htmlPath -Encoding UTF8
    $htmlPath
}

Export-ModuleMember -Function Write-DiagnosticFinding,Export-RevitDiagnosticReport
