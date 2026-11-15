# Test Results — 2026-11-15 (M1 MacBook Pro, 8 GB, macOS 27.2, Xcode 27.1 / Swift 6.4)

## Automated: `swift test`: **57 tests, 17 suites, all passing** (≈9 s)
| Suite | Covers |
|---|---|
| Safety policy (9), File remover (2), Audit (3) | Protected paths, flags, symlinks, exclusions, per-item permanent mode, audit lines, rule documentation |
| Junk scanner (2), Storage analyzer (3), Treemap (2) | Rules, running-app protection, every result passes the policy; size roll-up, cancellation, **5,000 files < 2 s**; areas proportional, no overlap |
| Large & old (1), Duplicates (1), Uninstaller (3), App insights (2) | Library/hidden skipped; identical-content only, hard links excluded; leftovers by bundle ID, sibling-ID guard, generic names |
| System monitor (1), Battery (2) | Live CPU/memory/process/disk; battery health from nested `BatteryData` |
| Disk safety gate (11) | Boot/internal/non-removable/read-only/too-small/disk-image refusals; revalidation detects removal and replacement; exclusive lock; **this Mac's boot disk is refused** |
| Image inspector (4) | Hybrid ISO, plain ISO refused, GPT, compressed Pi image; SHA-256 equals `shasum` |
| Raw writer (2) | **Real write → read-back → SHA-256 verify on a scratch 8 MB disk image**; default gate blocks it; cancellation |
| Removal locks (5) | Real ACL-locked files and folders detected; remover gives a precise reason (never blames Full Disk Access) and leaves the lock untouched; scanners mark locked items unselected |
| Network/maintenance/reports (4) | Local config only; identifiers excluded; read-only task runs; ProcessRunner passes `;`/`$()` literally |

## Manual / measured
| Check | Result |
|---|---|
| `diskutil verifyVolume /` (Maintenance) | OK in 20 s, no admin needed |
| Steady CPU (CPU-time delta over 20 s) | Dashboard **1.8%** (was 32.5% before fixes), Monitor **5.1%**, Settings 0.4% |
| Memory (RSS) | 112–148 MB depending on screen |
| App size | 7.9 MB (5.9 MB binary + icons + sounds) |
| Networking symbols | None linked (`nm -u`) |
| Screenshots inspected | Dashboard (light, dark, after Smart Scan), Cleaner (Basic, Expert), Uninstaller, Monitor, Processes, Battery, Network, Maintenance, Reports, Disk Manager, USB Toolkit, Settings, Duplicates |

## Bugs found and fixed during testing
1. `--section` ignored after window restoration (two screens were never verified).
2. Selecting the Trash forced the whole batch to permanent deletion.
3. Network Inspector and Reports hung in `getnameinfo`; replaced with `inet_ntop`.
4. Battery health missing on Apple Silicon (values nested in `BatteryData`).
5. Storage scan prefetched expensive keys for every file.
6. Continuous pulse and blur effects cost 30% CPU.
7. External volumes showed "Zero KB free".

## Not yet tested
- **Physical USB writes and erases** (raw, macOS, Windows). Needs your approval and a spare drive.
- Booting any created media on real hardware.
- Network-blocked runtime test (Phase 10).
- Storage treemap with a full home-folder result (blocked by pending macOS privacy prompts).
- Flush DNS (needs your password), export dialogs, menu-bar monitor, audio output by ear.
