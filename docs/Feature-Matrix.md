# Feature Matrix

Last updated: **2026-11-15** (end of Phase 2). Evidence = automated test name, screenshot, or measurement. See `Test-Results.md`.

**Status key:** ✅ Working & tested · 🟡 Implemented, partly verified · 🟠 Partial · ❌ Missing · 🔒 Blocked/limited by macOS · 🧪 Engine tested on a scratch disk image only (no physical device yet)

| Area | Feature | Status | Evidence / notes |
|---|---|---|---|
| **Safety** | SafetyPolicy (deny-lists, SIP/immutable flags, allowed roots, exclusions) | ✅ | `SafetyTests` (9) |
| | Trash-first removal; per-item permanent only for items already in the Trash | ✅ | `permanentOnlyAppliesPerItemNotToWholeBatch` (regression for an audit bug) |
| | Audit trail (JSON lines), Recent Activity screen | ✅ | `AuditTests`; screen screenshotted (empty state) |
| **Dashboard** | Mac info, storage ring, CPU/memory/battery/network cards, health checks (no invented score), Smart Scan | ✅ | Screenshots before and after Smart Scan (11.01 GB junk, 76 large/old files, 13 unused apps, 2 Intel apps) |
| **Smart Cleaner** | 14 rules with risk, consequence, auto-clean flag; search; Expert paths/rule IDs/dates | ✅ | `JunkScannerTests`, `everyBuiltInRuleIsDocumented`; screenshots (Basic and Expert) |
| **Storage Analyser** | Size tree, treemap (squarified), list view, drill-down, removal | 🟡 | `StorageAnalyzerTests`, `TreemapTests`, performance test (5,000 files < 2 s). **Treemap screen not yet screenshotted with results**: the scan was waiting on macOS folder-access prompts |
| **Duplicate Finder** | Size → partial hash → SHA-256, hard links excluded, keeps one copy per group | ✅ engine / 🟡 UI | `DuplicateTests`; empty-state screenshot |
| **Large & Old Files** | >100 MB or >10 MB unused for a year; kind and age filters | ✅ engine / 🟡 UI | `LargeOldTests`; found 76 files in Smart Scan |
| **App Uninstaller** | Inventory, sizes, architecture, last opened, leftovers with confidence, filters | ✅ | `UninstallerTests`, `AppInsightTests`; screenshot |
| | Root-owned apps | 🔒 | Removal fails without admin and is reported, never forced |
| **Live Monitor** | CPU (user/system/per-core, P+E split), memory breakdown, pressure, swap, network charts | ✅ | `MonitorTests`; screenshot; 5.1% CPU while visible |
| **Process Inspector** | Own-user processes, CPU/memory, sort/filter, quit apps | ✅ | Screenshot (350 processes) |
| **Battery** | %, charging watts, adapter, health % (full ÷ design), cycles, controller readings | ✅ | `BatteryTests`; screenshot (91% health, 4628/5103 mAh) |
| | Temperature | 🔒 | Not reported by this M1's battery controller; shown as "Not reported" |
| **Startup Manager** | Launch agents/daemons; remove user agents | 🟡 | Scanner smoke test; screen not screenshotted this phase |
| **Network Inspector** | Interfaces, IPv4/IPv6, MAC, MTU, traffic, DNS, router, connections (lsof), router ping | ✅ | `networkSnapshotReadsLocalConfig`; screenshot. A `getnameinfo` hang was found and fixed |
| **Maintenance** | Verify disk, verify app signatures, crash summary, Spotlight status, snapshots, flush DNS (admin) | ✅ / 🟡 | `readOnlyMaintenanceTaskRuns`; verifyVolume run manually (OK, 20 s); flush DNS not run (needs your password) |
| **System Reports** | Hardware/software/memory/storage/power/network; Markdown and JSON export; identifiers off by default | ✅ | `reportExcludesIdentifiersByDefault`; screenshot. Export dialog not exercised |
| **Disk Manager** | List disks (diskutil plist), partitions map, mount/unmount/eject, erase with typed confirmation | ✅ list / 🧪 erase | `realBootDiskIsProtected`, gate tests; screenshot (boot SSD locked). **Erase never run on a real drive** |
| **ISO Library** | Import, OS/arch/format detection, SHA-256, compare with publisher hash, duplicates, persisted | ✅ engine / 🟡 UI | `ImageInspectorTests`, `sha256MatchesShasum`; empty-state screenshot |
| **USB & OS Toolkit** | 7-step wizard; never auto-selects a target; typed erase confirmation; revalidation; single-operation lock; log | 🟡 UI | Image step screenshotted |
| | Raw / Linux hybrid ISO / Raspberry Pi `.img` write + SHA-256 read-back | 🧪 | `writesAndVerifiesOnScratchImageAndGateBlocksByDefault`; real USB uses `authopen` (admin prompt): **not physically tested** |
| | macOS `createinstallmedia` | 🧪❌ | Implemented; not run (no installer app on this Mac; needs admin) |
| | Windows 10/11 (GPT + FAT32 copy, install.wim split via wimlib) | 🧪❌ | Implemented; not run; **needs a real PC boot test** |
| | Compressed images (.xz/.gz/.zip) | ❌ | Detected; you must decompress first |
| | Multiboot (Ventoy-style) | ❌ | Research only (`USB-Compatibility.md`) |
| | Disk image backup/restore, benchmark | ❌ | Phase 8 |
| **Sounds** | 14 original synthesised sounds, SoundManager, previews, volume, off by default, respects the system UI-sound setting | ✅ | Files generated and bundled; preview UI present. Audio output not verified by ear |
| **Motion** | Ring/number transitions, hover lift, Reduce Motion honoured, no continuous animations | ✅ | Steady CPU measured (dashboard 1.8%) |
| **Modes** | Basic / Expert (paths, rule IDs, hashes, MAC/IPv6/MTU, device nodes, disk-image targets) | ✅ | Screenshots in both modes |
| **Menu bar monitor** | Optional (off by default) | 🟡 | Builds; not screenshotted |
| **Offline** | No networking frameworks linked | ✅ (static) | `nm -u` shows no URLSession/CFNetwork/socket-connect symbols. A network-blocked runtime test is still pending |
| **Build** | SwiftPM + `build-app.sh` → arm64 `.app`, ad-hoc signed | ✅ | Built and launched on an M1 MacBook Pro, 8 GB |
| | `.xcodeproj` | 🟠 | Open `Package.swift` in Xcode; no generated project |
