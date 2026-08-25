# Revit Server Diagnostics and Repair — Design

## Purpose

Build a public PowerShell project that diagnoses Revit Server, IIS, .NET Framework, Windows Update, networking, and crash behavior, then applies only explicitly requested and reversible repairs.

The project is based on the uploaded `RevitServer-Diag.ps1` version 2.0. Its existing reports and event analysis remain available, but the incorrect assumption that `clr.dll` version `4.8.4795.0` is necessarily stale or broken is removed.

## Supported environment

- Windows PowerShell 5.1 is the minimum runtime.
- Windows Server versions are detected from CIM and feature availability; no repair is selected from a hard-coded OS marketing name such as `Server 2022 21H2`.
- Revit Server instances are discovered by installed directories, IIS applications, services, and endpoints rather than a fixed list of Revit years.
- Administrative privileges are required only for repair operations. Diagnostics continue with reduced coverage when not elevated.
- The tool must not claim that an update exists unless Windows Update Agent returns an applicable, not-installed update.

## User interface

The main entry point is `RevitServer-Diag.ps1`.

### Diagnostic mode

Running with no repair switches makes no system changes:

```powershell
.\RevitServer-Diag.ps1 -Days 400
```

It creates an HTML report, CSV sections, a transcript, a machine-readable JSON summary, and a proposed repair plan.

### Repair switches

- `-Repair`: apply low-risk repairs: start stopped Revit Server services/sites/pools, restore automatic start where the current configuration clearly indicates a Revit Server component, set Revit pools to `AlwaysRunning`, set idle timeout to zero, install missing required IIS role services, register Microsoft Update if absent, and set the Revit application-pool Rapid-Fail maximum to 20 while leaving protection enabled.
- `-SetupProcDump`: configure full crash dumps for `w3wp.exe`. If ProcDump is absent, download it only from the official Sysinternals endpoint, verify the Authenticode signature and Microsoft publisher, extract it to a stable tools directory, then configure capture. Existing dump configuration is preserved in the backup.
- `-InstallUpdates`: search Windows Update Agent/Microsoft Update for applicable, not-installed software updates. Select updates using update metadata and installed product state, not an OS-version string. Display the exact update list and require confirmation unless `-Force` is supplied. Record per-update download/install result and reboot requirement.
- `-UpgradeNet481`: perform a separate in-place .NET Framework 4.8.1 upgrade only on an OS that Microsoft declares compatible. It requires `-SnapshotConfirmed`, verifies the installer signature and supported release information, and never describes the upgrade as Autodesk-certified.
- `-DisableDynamicIpRestrictions`: disable Dynamic IP Restrictions only for the Revit Server site/application scope and only after backing up IIS configuration. This is never included in generic `-Repair`.
- `-AutoReboot`: allow reboot after an update or framework installation. Without it, report that a reboot is pending and leave the machine running.
- `-Force`: suppress only interactive confirmations for operations already selected by explicit switches. It never bypasses signature, compatibility, backup, or snapshot-confirmation gates.

Parameters that materially alter networking, ACLs, security exclusions, or runtime GC behavior remain separate explicit operations. Generic repair must not change NetBIOS, DNS registration, Defender exclusions, Dynamic IP Restrictions, or `Aspnet.config`.

## Update logic

The current `clr.dll` file version and .NET Release registry key are evidence, not a verdict. Version `4.8.4795.0` is recorded without an automatic FAIL.

The update workflow:

1. Record OS version/build, .NET Release key, CLR file versions, Windows Update policies, update services, pending reboot state, and recent installed packages.
2. Ensure Windows Update services can be queried. Diagnostic mode does not change their startup type.
3. Query Windows Update Agent for applicable, not-installed software updates.
4. Register/query Microsoft Update when requested by `-Repair` or `-InstallUpdates`; disclose WSUS policy and whether the query is managed.
5. Classify returned updates from their own titles, categories, KB identifiers, and bundled-update metadata. Do not fabricate a search result from a title pattern.
6. If no applicable .NET update is returned, report `No applicable .NET update found`; do not infer channel failure merely because Defender definitions were offered.
7. On installation, log download and installation result codes, HRESULTs, accepted EULAs, and reboot state.
8. After reboot, compare recorded pre-change and current Release/file versions and installed KBs.

Installing all Windows/IIS cumulative updates is allowed only through the explicit `-InstallUpdates` selection and confirmation. The tool must not scrape Microsoft Update Catalog or guess a `.msu` URL.

## ProcDump design

The default repair path registers ProcDump as a postmortem debugger using the supported `-ma -i <dump-folder>` form so a future unhandled crash produces a full dump. The tool records and can restore any previous AeDebug configuration.

An optional foreground monitor command is printed for targeted troubleshooting of `w3wp.exe` with `-ma -e -w`. The report explains that full dumps can contain sensitive process memory and may be approximately as large as the worker process memory.

The tool verifies free disk space and configures dump retention. It does not automatically upload dumps.

## Diagnostic and repair rules

### IIS and Revit Server

- Detect missing required IIS role services and install only those required for the discovered Revit Server generation and host configuration.
- Start stopped Revit Server application pools, sites, and automatic services.
- Preserve Rapid-Fail protection but change `rapidFailProtectionMaxCrashes` to 20 for Revit pools when `-Repair` is used.
- Back up `%windir%\System32\inetsrv\config\applicationHost.config` before any IIS change.
- Test discovered REST and model-service endpoints after repair.
- Detect client requests for missing Revit Server years. Report the exact missing endpoint and affected event count. Do not attempt to install Autodesk software without a supplied, verified installer and a separate future design.

### Crash analysis

- Correlate `.NET Runtime` 1023, `Application Error` 1000, and WAS 5011 without double-counting one crash as several root-cause events.
- Group by process, module, exception code, offset, application pool, Revit version, hour, weekday, and month.
- Highlight repeat signatures such as `clr.dll`, `SQLite.Interop.dll`, `protsup.dll`, `diprestr.dll`, and `iiscore.dll` without asserting that the named module is always the root cause.
- Correlate crash times with Task Scheduler, AutoSync, service restarts, pool recycling, backup/VSS activity, Defender scans, and recent updates.
- If dumps exist, inventory them and generate instructions for WinDbg `!analyze -v`, SOS loading, and `!clrstack`; automated dump interpretation is outside this version.

### Dynamic IP Restrictions

- Detect whether the module and site-level rule are enabled.
- Recommend a controlled test only when crash events implicate `diprestr.dll` or the configuration is inconsistent.
- `-DisableDynamicIpRestrictions` backs up configuration, changes only the Revit Server scope, restarts only affected pools if necessary, retests endpoints, and records a rollback command.

### Network checks

- Detect duplicate/extra active adapters, interface metrics, DNS registration settings, NetBIOS options, dynamic DNS failures, and name-resolution differences.
- Do not automatically disable NetBIOS or alter DNS in generic repair because the correct adapter cannot be inferred safely on all servers.
- When the target adapter and correction are unambiguous, emit an exact proposed command into the repair plan. Applying network changes requires a dedicated explicit switch and confirmation in a later version.

### Security and runtime checks

- Detect CLR profiler environment variables and non-Microsoft modules loaded in `w3wp.exe`.
- Report Defender/EDR exclusions but do not add them through generic repair.
- Report a possible `gcConcurrent` experiment only when dump evidence points to GC. Never edit machine-wide `Aspnet.config` automatically in this version.

## Safety, backup, and rollback

Before the first mutation, create a timestamped backup directory containing:

- IIS applicationHost configuration backup;
- exported relevant registry keys;
- application-pool and service settings in JSON/CSV;
- Windows Update service/policy state;
- current .NET/CLR versions;
- a generated `Rollback.ps1` limited to changes actually made in that run.

Each repair is idempotent and returns one of: `AlreadyCompliant`, `Changed`, `Failed`, `Skipped`, or `RebootRequired`. A failure in one repair does not trigger unrelated repairs. Critical verification failure causes the corresponding change to be rolled back when a reliable rollback exists.

## Project structure

- `RevitServer-Diag.ps1`: public entry point, parameter validation, orchestration, reporting.
- `Run.ps1`: minimal GitHub launcher that downloads the tagged/main script over TLS, shows the resolved source URL, and invokes it. It does not silently pass repair switches.
- `src/Diagnostics.psm1`: read-only environment, .NET, update, IIS, Revit Server, crash, process, security, and network collectors.
- `src/Repairs.psm1`: explicit mutation functions, backup integration, verification, and rollback records.
- `src/Reporting.psm1`: console, HTML, CSV, JSON, and repair-plan output.
- `tests/*.Tests.ps1`: Pester tests for parsers, classifiers, safety gates, idempotence, update selection, repair planning, and generated commands.
- `README.md`: Russian installation, one-line GitHub launch, parameter table, examples, risks, report contents, rollback, and dump-analysis workflow.
- `CHANGELOG.md`: user-visible changes.
- `LICENSE`: MIT unless the repository owner chooses another license.

## Remote launch

The repository is public so a diagnostic-only launcher can be invoked without a GitHub token:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
irm https://raw.githubusercontent.com/Viend1211/RevitServer-Diagnostics/main/Run.ps1 | iex
```

Because piping remote code to `iex` has supply-chain risk, README also provides a recommended inspect-then-run form that downloads the script locally, displays its path, and lets the administrator review it before execution.

The launcher defaults to diagnostic mode. Repair parameters must be entered after downloading the main script locally or passed explicitly through a documented launcher argument.

## Testing and acceptance

- Pester tests must cover both Server-like mocked states and unavailable-command states.
- PowerShell parsing must succeed under Windows PowerShell 5.1-compatible syntax.
- No diagnostic-only test may call a mutation command.
- Update classification tests must prove that `4.8.4795.0` alone does not create a FAIL or an invented update.
- Repair tests must prove backup-before-write ordering, Revit-only scoping, confirmation gates, signature checks, idempotence, and rollback record generation.
- Static checks reject hard-coded `Server 2022 21H2` update selection.
- The final repository must contain the original diagnostic capabilities, the new repair plan, tests, README, and a working diagnostic-only GitHub command.

## Explicit exclusions

- No automatic deployment of Revit Server 2025/2026.
- No automatic upload or analysis of memory dumps.
- No generic Defender/EDR exclusions.
- No automatic machine-wide GC changes.
- No automatic DNS or NetBIOS mutation in the first release.
- No update installation without an explicit switch and confirmation, except when `-Force` is explicitly combined with that switch.
