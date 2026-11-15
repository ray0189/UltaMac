# UltaMac — The Ultimate Mac Toolkit

**Clean. Monitor. Optimise. Recover.**

A native, fully offline macOS utility suite written in Swift and SwiftUI, built for Apple Silicon. No accounts, no subscriptions, no telemetry, no network code.

## Download
1. Go to **[Releases](https://github.com/ray0189/UltaMac/releases/latest)** and download `UltaMac.zip`.
2. Unzip it and drag **UltaMac** into your **Applications** folder.
3. The first time, **right-click UltaMac → Open → Open**. UltaMac is free and isn't notarised by Apple, so macOS asks once. On macOS 15 and later, if there's no Open button, go to **System Settings › Privacy & Security** and click **Open Anyway**.
4. Optional: in UltaMac, open **Permissions** and grant Full Disk Access for complete scans.

Requires macOS 14 Sonoma or later. Runs natively on Apple Silicon and Intel.

Each release lists the zip's SHA-256 so you can verify the download: `shasum -a 256 UltaMac.zip`.

## Features
| Area | What it does |
|---|---|
| **Smart Scan** | One read-only scan for junk, large/old files and apps, with transparent health checks (no invented scores) |
| **Smart Cleaner** | 14 documented rules (caches, logs, Xcode, npm, Gradle, Downloads installers, Trash), each with a risk level and consequences |
| **Storage Analyser** | Interactive squarified treemap and list with drill-down |
| **Duplicate Finder** | Size → partial hash → SHA-256; hard links excluded; always keeps one copy |
| **Large & Old Files** | Files over 100 MB, or untouched for a year |
| **App Uninstaller** | Leftovers by bundle ID (high confidence) or name (review); flags Intel-only and unused apps |
| **Live Monitor & Process Inspector** | CPU (P/E cores), memory pressure, swap, network, per-process usage |
| **Battery** | Health vs design capacity, cycles, charge rate, adapter |
| **Startup Manager, Network Inspector, Maintenance, System Reports** | Launch items, interfaces/DNS, safe diagnostics, Markdown/JSON export |
| **Disk Manager, ISO Library, USB & OS Toolkit** | Drive inspection and erase, image detection and SHA-256 checks, bootable USB wizard (Linux/Raspberry Pi raw, macOS `createinstallmedia`, Windows) |

## Safety
- Scanning is read-only. Removal always goes through a review sheet; the Trash is the default; permanent deletion asks twice.
- A safety policy refuses system paths, SIP-protected or locked files, keychains, mail, iCloud, Photos libraries and your exclusions, and never unlocks or force-deletes anything.
- Disk tools refuse the boot disk and internal disks, never auto-select a target, need a typed confirmation, and re-verify the device right before writing.
- Every removal and disk operation is logged locally.

See [`docs/Security-Model.md`](docs/Security-Model.md).

## Status
Early development. See [`docs/Feature-Matrix.md`](docs/Feature-Matrix.md), [`docs/Test-Results.md`](docs/Test-Results.md) and [`docs/Known-Limitations.md`](docs/Known-Limitations.md).
**USB writing has only been verified on scratch disk images, not physical drives.**

## Build
Requires macOS 14+, Xcode 16+ (Swift 6).

```bash
swift test                      # 52 tests
scripts/build-app.sh            # → build/UltaMac.app
scripts/build-app.sh --install  # also copies to /Applications
```

Or open `Package.swift` in Xcode. For full scanning, grant Full Disk Access in System Settings › Privacy & Security (the app's Permissions screen walks you through it).

## Contributing
UltaMac is open source under the [MIT licence](LICENSE): anyone can use, copy, modify and share it. To propose changes, fork the repo and open a pull request; see [CONTRIBUTING.md](CONTRIBUTING.md).

## Originality
All code, the icon and the sound effects are original (the sounds are synthesised by `scripts/make-sounds.swift`, the icon is drawn by `scripts/make-icon.swift`). No third-party dependencies.
