# Architecture

```
UltaMac.app (SwiftUI, macOS 14+, arm64)
├── Design/        Theme tokens, components (Page, Card, Ring, Sparkline, Pill, SelectionBar…),
│                  Navigation (Destination/NavGroup), Removal (ReviewSheet: the only path to deletion)
├── Sound/         SoundManager (AVAudioPlayer; bundled WAVs from scripts/make-sounds.swift)
├── Models/        AppSettings, AppState, MonitorModel, feature models, HealthChecks, ToolsModels
└── Screens/       one file per area
UltaMacCore (library, no UI; all unit-tested)
├── Safety/        SafetyPolicy, FileRemover, AuditLog
├── Junk/          JunkRules (14 documented rules), JunkScanner
├── Storage/       SizeCalculator, StorageAnalyzer, TreemapLayout
├── Files/         LargeOldFinder, DuplicateFinder
├── Apps/          AppInventory (+architecture, last used), LeftoverFinder
├── Monitor/       CPUSampler, MemoryStats, ProcessSampler, NetworkSampler, BatteryStatus/Details, DiskStatus, SystemInfo
├── Startup/       LaunchItemsScanner
├── System/        ProcessRunner, NetworkSnapshot, Maintenance, SystemReport, FullDiskAccess
└── Disk/          DiskInventory, DiskSafetyGate, DiskOperationLock, ImageInspector, RawImageWriter,
                   DiskEraser, MacInstallerMedia, WindowsMedia, DiskOperationLog
```

## Concurrency
Engines are synchronous and cancellable (`CancellationFlag`). Views start them with `runInBackground` (a detached task) and receive throttled progress on the main actor. The monitor samples only while a view or the menu-bar item is subscribed, and processes only while the Process Inspector is open.

## Data sources (all public or documented system interfaces)
| Data | API |
|---|---|
| CPU | `host_processor_info`, `getloadavg`, `hw.perflevel*` |
| Memory | `host_statistics64`, `vm.swapusage`, `kern.memorystatus_vm_pressure_level` |
| Processes | `proc_listallpids`, `proc_pid_rusage`, `proc_pidpath` |
| Network | `getifaddrs` + `inet_ntop`, SystemConfiguration (DNS, router, interface names), `lsof`, `ping` (user-initiated) |
| Battery | IOPowerSources; `AppleSmartBattery` IORegistry (undocumented keys, labelled) |
| Disks | `diskutil … -plist`, `hdiutil`, `/usr/libexec/authopen` |
| Apps | Info.plist, Mach-O header, Spotlight `kMDItemLastUsedDate`, Security framework |

## Health checks (no combined score)
| Check | Attention when | Critical when |
|---|---|---|
| Disk space | < 15% available | < 5% |
| Memory pressure | kernel reports Warning | Critical |
| Swap | swap used > half of RAM | — |
| Battery | full-charge < 80% of design, or macOS condition ≠ Good | — |
| Thermal | `.serious` | `.critical` |
| Junk | > 1 GB recommended | — |
Large/old files, Intel-only apps, unused apps and Full Disk Access are informational.
