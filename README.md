# RevitServer-Diagnostics

Диагностика Revit Server, IIS, .NET Framework, Windows Update и падений `w3wp.exe` с безопасными, явно выбранными исправлениями.

Главное правило: обычный запуск ничего не меняет. Версия `clr.dll 4.8.4795.0` не считается ошибкой сама по себе. Наличие обновлений определяется только результатом Windows Update Agent/Microsoft Update.

## Графический интерфейс

Откройте **Windows PowerShell от имени администратора** и выполните:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
irm https://raw.githubusercontent.com/viendhyra/RevitServer-Diagnostics/main/Run-GUI.ps1 | iex
```

В окне доступны:

- главная панель состояния сервера, IIS и пулов Revit Server;
- полная безопасная диагностика с прогрессом и HTML-отчётом;
- живой журнал остановок, запусков и аварий только пулов Revit Server;
- отдельные подтверждаемые действия: запуск пулов, AutoStart/AlwaysRunning/idle timeout и Rapid-Fail = 20;
- установка проверенного Microsoft Sysinternals ProcDump и открытие папки дампов.

Живой монитор запускается отдельной кнопкой и работает только пока открыто окно. Он не устанавливает службу и ничего не исправляет автоматически. Для изменения настроек нужны права администратора и подтверждение каждого действия.

Полный дамп может занимать столько же места, сколько память процесса `w3wp.exe`, и содержать рабочие данные из памяти. Дампы не отправляются в интернет.

## Быстрый запуск с GitHub

Откройте **Windows PowerShell от имени администратора**:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
irm https://raw.githubusercontent.com/viendhyra/RevitServer-Diagnostics/main/Run.ps1 | iex
```

Команда загружает локальную копию в `%TEMP%`, показывает её путь и запускает только диагностику.

Более безопасный вариант с просмотром файла перед запуском:

```powershell
$url = 'https://raw.githubusercontent.com/viendhyra/RevitServer-Diagnostics/main/Run.ps1'
$file = "$env:TEMP\Run-RevitServerDiagnostics.ps1"
Invoke-WebRequest -UseBasicParsing $url -OutFile $file
notepad $file
& $file
```

## Локальная установка

Скачайте репозиторий или ZIP, распакуйте и запустите:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\RevitServer-Diag.ps1 -Days 400
```

Отчёт создаётся рядом со скриптом: `Report_<сервер>_<дата>\REPORT.html`.

## Что проверяется

- ОС, память, диски и время последней загрузки;
- .NET Release key и версии `clr.dll` без ошибочного сравнения с одной «плохой» версией;
- реальные применимые обновления через Windows Update Agent;
- Microsoft Update и политики WSUS;
- IIS: сайты, приложения, пулы, автозапуск, idle timeout и Rapid-Fail;
- обнаруженные экземпляры и службы Revit Server любых годов;
- падения `Application Error 1000` и `WAS 5011` без двойного подсчёта;
- сигнатуры `clr.dll`, `SQLite.Interop.dll`, `protsup.dll`, `diprestr.dll`, `iiscore.dll`;
- активные сетевые адаптеры, DNS и NetBIOS-настройки;
- переменные `COR_*`, `CORECLR_*`, `COMPlus_*`, указывающие на профайлер или внедрение кода.

## Исправления

Исправления выполняются только соответствующими ключами.

| Ключ | Действие |
|---|---|
| `-Repair` | Ставит недостающие компоненты IIS, запускает службы/сайты/пулы Revit Server, включает `AlwaysRunning`, отключает idle timeout и устанавливает Rapid-Fail = 20, не отключая защиту |
| `-SetupProcDump` | Скачивает ProcDump только с Sysinternals, проверяет подпись Microsoft и включает полные постмортем-дампы |
| `-InstallUpdates` | Устанавливает выбранные применимые обновления, найденные Windows Update Agent |
| `-UpdateKind DotNet` | С `-InstallUpdates` выбирает только .NET Framework |
| `-UpdateKind Windows` | Выбирает накопительные/безопасностные обновления, исключая определения Defender и драйверы |
| `-UpdateKind All` | Выбирает все применимые программные обновления |
| `-UpgradeNet481` | Отдельный in-place переход на .NET Framework 4.8.1 на Windows Server 2022 |
| `-Net481InstallerPath` | Путь к официальному офлайн-установщику .NET Framework 4.8.1 |
| `-SnapshotConfirmed` | Обязательное подтверждение снапшота/резервной копии для 4.8.1 |
| `-DisableDynamicIpRestrictions` | Отключает Dynamic IP Restrictions только в областях приложений Revit Server |
| `-AutoReboot` | Разрешает отложенную на 60 секунд перезагрузку после установки |
| `-Force` | Убирает интерактивные вопросы, но не проверки подписи, ОС, резервной копии и снапшота |

Примеры:

```powershell
# Базовые безопасные исправления
.\RevitServer-Diag.ps1 -Repair

# Настроить сбор дампов
.\RevitServer-Diag.ps1 -SetupProcDump

# Найти и установить только реально предложенные обновления .NET
.\RevitServer-Diag.ps1 -InstallUpdates -UpdateKind DotNet

# Установить обновления и разрешить перезагрузку
.\RevitServer-Diag.ps1 -InstallUpdates -UpdateKind Windows -AutoReboot

# Переход на 4.8.1 после снапшота виртуальной машины
.\RevitServer-Diag.ps1 -UpgradeNet481 `
  -Net481InstallerPath C:\Install\ndp481-x86-x64-allos-enu.exe `
  -SnapshotConfirmed
```

## ProcDump

Скрипт использует официальный архив:

`https://download.sysinternals.com/files/Procdump.zip`

После проверки Authenticode регистрируется полный постмортем-дамп:

```text
procdump64.exe -accepteula -ma -i C:\Dumps\RevitServer
```

Для целевого наблюдения за следующим `w3wp.exe` можно отдельно использовать:

```powershell
C:\Tools\Sysinternals\ProcDump\procdump64.exe -accepteula -ma -e -w w3wp.exe C:\Dumps\RevitServer
```

Полный дамп может быть размером с память процесса и содержит содержимое памяти сервера. Скрипт не выгружает дампы в интернет.

Отмена регистрации:

```powershell
C:\Tools\Sysinternals\ProcDump\procdump64.exe -u
```

## Резервная копия и откат

При первом изменении создаётся каталог `Backup_<сервер>_<дата>` внутри отчёта. В нём сохраняются настройки и генерируется `Rollback.ps1` только для реально выполненных обратимых действий.

Запуск отката:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Rollback.ps1
```

Обновления Windows и in-place переход на .NET Framework 4.8.1 штатным скриптом не откатываются. Поэтому для 4.8.1 обязателен снапшот виртуальной машины или проверенная полная резервная копия.

## Что намеренно не исправляется автоматически

- установка отсутствующих Revit Server 2025/2026 без дистрибутива Autodesk;
- DNS и NetBIOS на многосетевом сервере;
- исключения Defender/EDR;
- изменение `gcConcurrent` в системном `Aspnet.config`;
- анализ и отправка дампов.

Эти изменения зависят от инфраструктуры и могут нарушить доступ к серверу.

## Анализ дампа

Откройте `.dmp` в WinDbg Preview и выполните:

```text
!analyze -v
.loadby sos clr
!clrstack
lm
```

Если стек приводит к `SQLite.Interop.dll`, `diprestr.dll` или другому нативному модулю, запись `clr.dll` в журнале могла быть только местом проявления, а не первопричиной.

## Файлы отчёта

- `REPORT.html` — сводка;
- `summary.json` — полный машинно-читаемый снимок;
- `00_findings.csv` — ключевые проблемы;
- `00_repairs.csv` — выполненные исправления и результаты;
- `02_updates_available.csv` — реально найденные обновления;
- `03_apppools.csv`, `03_sites.csv` — IIS;
- `04_instances.csv`, `04_services.csv` — Revit Server;
- `05_crashes.csv`, `05_crash_signatures.csv` — падения;
- `08_network.csv` — сетевые интерфейсы;
- `console.log` — полный вывод.

## Требования

- Windows PowerShell 5.1;
- Windows Server с Revit Server/IIS;
- права администратора для исправлений;
- доступ к Microsoft Update/Sysinternals для обновлений и автоматической загрузки ProcDump.

## Лицензия

MIT.
