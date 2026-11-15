# Security Model

## Principles
- **Least privilege:** UltaMac runs as the logged-in user. No persistent root helper, no `sudo`, no SMJobBless/SMAppService daemon.
- **Never weaken macOS:** no changes to SIP, TCC, Gatekeeper, quarantine attributes, file flags (`chflags`) or other apps' code signatures.
- **Offline:** no networking code. Preferences, history and reports stay in `~/Library/Application Support/UltaMac` and `UserDefaults`.

## Removal pipeline (the only way files are removed)
```
UI selection → Review sheet (list, size, mode) → [permanent? second alert] → FileRemover → SafetyPolicy.check (each item) → trashItem / removeItem → AuditLog
```
`SafetyPolicy` refuses an item when it:
- is not absolute, contains `..`, or no longer exists
- **is** a protected container (home, Library, the standard folders, cache/log roots…)
- lies **inside** `/System`, `/usr`, `/bin`, `/sbin`, `/private`, `/Library/Apple`, Keychains, Mail, Messages, iCloud Drive, CloudStorage, MobileSync, TCC, Accounts, Photos, `~/.ssh` or `~/.gnupg`, or inside any `.photoslibrary`
- has the `SF_RESTRICTED`, `SF_IMMUTABLE`, `UF_IMMUTABLE` or `SF_NOUNLINK` flag (reported, never cleared)
- is in your exclusions, or is UltaMac itself
- is outside the allowed roots: home, `/Volumes/<name>/…`, or for uninstalls only, `.app` bundles in `/Applications` and `~/Applications`

Symlinks are judged by where the link lives; removing one removes the link, never its target.

## Locked items and the administrator path
`RemovalLock` diagnoses *before* removal why an item can't be removed by you: an ACL "deny delete" rule on the item, a "deny delete_child" rule on its folder, a folder you can't write, or another owner in a sticky folder. Locked items get a badge and are never pre-selected.

If you select them anyway, the review sheet marks them **Password** and offers an opt-in checkbox. `AdminRemover` then:
1. re-runs `SafetyPolicy` on every item (system folders, SIP, immutable flags and exclusions are still refused);
2. asks macOS for your administrator password once per batch (`do shell script … with administrator privileges`), with every path passed as an AppleScript argument and quoted by `quoted form of`, never joined into a shell string in Swift;
3. moves each item into your Trash, then clears its ACL and gives it back to your account so you can restore or empty it normally (or, in permanent mode, deletes it);
4. records the result in the audit log, marked "(administrator)".

UltaMac never sees or stores the password, and never changes the locks on folders such as `~/Pictures`. Failures that come from permission errors (not safety rules) can also be retried from the result banner's **Remove with Password…** button.

## Optimise (live performance fixes)
`PerformanceAdvisor` turns live measurements into issues with fixed thresholds: an app (including its helpers) holding ≥ 80% of a core for 60 s; apps over 700 MB when memory pressure is raised or ≥ 2 GB is swapped; < 10% or < 15 GB free disk; a serious thermal state; more than 14 days of uptime; more than 12 auto-starting items. Fixes always need a click: quitting asks first (apps quit normally and can ask to save; background processes get `SIGTERM`); macOS processes, `loginwindow`, `WindowServer`, the Dock and UltaMac are never offered. Restart opens macOS's own Restart dialog. Speed-up tools are fixed commands (`purge`, `lsregister -gc`, `killall Finder Dock`, `atsutil databases -removeUser`, `mdutil -E /`, DNS flush); the ones that need an administrator use the same macOS prompt.

## Permissions
| Permission | Used for | Required? |
|---|---|---|
| Full Disk Access | Reading TCC-protected caches, `~/.Trash`, other apps' containers | Optional; scans report what they couldn't read |
| Administrator (per operation) | Writing raw USB devices (`authopen`), `createinstallmedia`, removing locked or root-owned items you selected, `purge`, Spotlight rebuild, DNS flush | Asked by macOS at the moment of the operation; never stored |
| Removable volumes | Listing, ejecting, imaging USB drives | Prompted by macOS on first access |

## Destructive disk operations (USB toolkit, not yet enabled)
These are mandatory before any write is enabled: never auto-select a target; refuse internal and boot disks; show model and capacity; a separate erase confirmation; revalidate the device identity (BSD name + media UUID + size) right before writing; abort if the device changes; one operation at a time; full logging. Detailed in `USB-Compatibility.md`.

## Audit log
Each removal batch appends one JSON line to `~/Library/Application Support/UltaMac/audit.jsonl`: time, mode, purpose, items removed with sizes, and failures with reasons. It is never sent anywhere.
