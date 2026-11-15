# Phase 2 — Design for "UltaMac", an offline Mac cleaner

**Decisions (2026-11-15):** macOS 14+ · Apple Silicon native (arm64) · no privileged helper · no private APIs by default (temperature/fan sensors deferred to an opt-in later) · ad-hoc signed for personal use · zero networking.

## 1. Principles
1. **Read-only until you say so.** Scanning never changes anything. Every removal goes through one function (`FileRemover.remove`) that checks `SafetyPolicy` for each item.
2. **The Trash is the default.** Permanent deletion is a per-action choice with a second confirmation. Emptying the Trash is always permanent and is labelled that way.
3. **User domain only.** Without a root helper, the app only removes things you own: your home folder, external volumes, and app bundles you can write to. Anything else is shown but not removed.
4. **Never weaken macOS.** No clearing of immutable/SIP flags, no quarantine stripping, no `chflags`, no `sudo`, no editing other apps' binaries.
5. **Offline by construction.** No `URLSession`, no analytics, no crash reporter, no update checker. The network block in Phase 5 proves it.

## 2. Architecture

```
UltaMac.app (SwiftUI, @MainActor view models)
 ├─ Dashboard · Storage · Junk · Uninstaller · Monitor · Startup Items · Settings
 │
 └─ UltaMacCore (Swift library, no UI, unit tested)
     ├─ Safety      SafetyPolicy (deny-lists, file-flag checks, allowed roots)
     │              FileRemover (trash / permanent; reports per-item result)
     ├─ Storage     SizeCalculator, StorageAnalyzer (tree, same-volume only)
     ├─ Junk        JunkRules (readable rule table), JunkScanner
     ├─ Apps        AppInventory, LeftoverFinder (bundle-ID and name matching)
     ├─ Monitor     CPUSampler (host_processor_info), MemoryInfo (host_statistics64),
     │              ProcessSampler (proc_pid_rusage), NetworkSampler (getifaddrs),
     │              BatteryInfo (IOPowerSources), DiskInfo, uptime/thermal/swap
     ├─ Startup     LaunchItemsScanner (LaunchAgents/Daemons plists)
     └─ System      Permissions (Full Disk Access probe)
```

Engines are plain synchronous Swift run off the main thread by `Task.detached`. Each takes a `home` URL so tests can run against a temporary fake home folder.

## 3. Safety policy
Removal is **denied** when any of these is true:
- the path isn't absolute, or contains `..` after standardisation, or doesn't exist (`lstat`)
- it is a protected root itself: `/`, `/System`, `/Library`, `/Applications`, `/Users`, `~`, `~/Library`, the standard user folders, and the cache/log/support containers themselves (only their *contents* can be removed)
- it lies inside a system or sensitive area: `/System`, `/usr`, `/bin`, `/sbin`, `/private`, `/Library/Apple`, `~/Library/Keychains`, `~/Library/Mail`, `~/Library/Messages`, `~/Library/Mobile Documents`, `~/Library/CloudStorage`, MobileSync backups, `~/.ssh`, `~/.gnupg`, any `.photoslibrary`
- the file has the `SF_RESTRICTED` (SIP), `SF_IMMUTABLE`, `UF_IMMUTABLE` or `SF_NOUNLINK` flag
- it is in your custom exclusions
- it is outside the allowed roots: under `~`, under `/Volumes/<name>/` (not the volume root), or for uninstalls an `.app` in `/Applications` or `~/Applications` that isn't an Apple app or UltaMac itself

## 4. Feature specs
| Screen | What it does | Removes? |
|---|---|---|
| **Dashboard** | Disk ring, memory, CPU, battery and uptime tiles; a "Scan for junk" shortcut; Full Disk Access status | No |
| **Storage** | Scans a chosen folder (home by default), sized bars per child, drill-down with breadcrumbs, reveal in Finder | Selected items → Trash, after confirmation |
| **Junk** | Rule-based scan by category (caches, logs, developer, downloads, Trash). Risky rules start unticked. Caches of running apps start unticked. | Selected items, after confirmation |
| **Uninstaller** | Apps sorted by size and searchable. Leftovers are matched by bundle ID (ticked) or by name (unticked, lower confidence). Refuses running apps and offers to quit them. | App and selected leftovers → Trash |
| **Monitor** | Live CPU and network charts, memory breakdown, swap, pressure, thermal state, and the top processes by CPU and memory | No |
| **Startup Items** | Launch agents and daemons (user and system) with label, program and run-at-load; a link to the Login Items settings | User-level plists only, after confirmation |
| **Settings** | Default removal mode, custom exclusions, permissions help | — |

## 5. Junk rules (original, readable, in `JunkRules.swift`)
| Rule | Location | Default |
|---|---|---|
| App caches | `~/Library/Caches/*` except `com.apple.*` | ✓ |
| Apple app caches | `~/Library/Caches/com.apple.*` | ✗ |
| User logs and crash reports | `~/Library/Logs/*` | ✓ |
| Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData/*` | ✓ |
| Simulator caches | `~/Library/Developer/CoreSimulator/Caches/*` | ✓ |
| iOS device support files | `~/Library/Developer/Xcode/iOS DeviceSupport/*` | ✗ |
| npm cache | `~/.npm/_cacache` | ✓ |
| Gradle caches | `~/.gradle/caches` | ✗ |
| Saved window state | `~/Library/Saved Application State/*` | ✗ |
| Old installers in Downloads | `~/Downloads/*.{dmg,pkg,iso}` older than 14 days | ✗ |
| Trash | `~/.Trash/*` (always permanent) | ✗ |

## 6. Interface
`NavigationSplitView` with a sidebar of SF Symbols, the system accent colour, and full light/dark support. Lists use `Table`, charts use Swift Charts, sizes use `ByteCountFormatter`, and long jobs show determinate or indeterminate progress with a Cancel button. Removal always goes through one **Review sheet**: item count, total size, a scrollable list, a mode picker, and a second alert for permanent deletion.

## 7. Build
A Swift package (`UltaMacCore` library, `UltaMac` executable, Swift Testing tests). `scripts/build-app.sh` wraps the binary into `build/UltaMac.app` with an Info.plist (`LSMinimumSystemVersion 14.0`) and ad-hoc signs it with the hardened runtime. No network entitlements are needed, since the app is unsandboxed so it can read `~/Library`.
