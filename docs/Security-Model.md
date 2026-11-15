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

## Permissions
| Permission | Used for | Required? |
|---|---|---|
| Full Disk Access | Reading TCC-protected caches, `~/.Trash`, other apps' containers | Optional; scans report what they couldn't read |
| Administrator (per operation, future) | Writing raw USB devices (`authopen`), `createinstallmedia`, root-owned app removal | Asked only at the moment of a destructive operation |
| Removable volumes | Listing, ejecting, imaging USB drives | Prompted by macOS on first access |

## Destructive disk operations (USB toolkit, not yet enabled)
These are mandatory before any write is enabled: never auto-select a target; refuse internal and boot disks; show model and capacity; a separate erase confirmation; revalidate the device identity (BSD name + media UUID + size) right before writing; abort if the device changes; one operation at a time; full logging. Detailed in `USB-Compatibility.md`.

## Audit log
Each removal batch appends one JSON line to `~/Library/Application Support/UltaMac/audit.jsonl`: time, mode, purpose, items removed with sizes, and failures with reasons. It is never sent anywhere.
