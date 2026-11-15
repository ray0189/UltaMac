# USB & OS Toolkit: compatibility research and plan

**Status: research and design only. Nothing in UltaMac writes to disks yet.** No destructive test will run against a real device without explicit approval.

## Privilege strategy (no persistent helper)
| Need | Supported mechanism | Notes |
|---|---|---|
| Write a raw device (`/dev/rdiskN`) | `/usr/libexec/authopen -w` | Apple's tool: shows the admin prompt and passes back an open file descriptor for *that one device*. No root process stays behind. |
| macOS installer media | `sudo createinstallmedia --volume …` via an `AuthorizationServices` prompt or `osascript … with administrator privileges` | Apple's documented process. Needs a full installer app in `/Applications`. |
| Partition/format | `diskutil eraseDisk` / `partitionDisk` (works on removable disks as the user) | Arguments passed as an array, never a shell string. |
| Device discovery | DiskArbitration (`DASessionCreate`, `DARegisterDiskAppearedCallback`), IOKit (`IOMedia`, USB parents) | Read-only, no privileges needed. |

## Workflows by image type
| Image | Detection | Workflow | Verification | Caveats |
|---|---|---|---|---|
| macOS installer `.app` | `Contents/Resources/createinstallmedia`, version | `createinstallmedia` | Installer volume present, `codesign --verify` | Target Mac compatibility. Not a DFU/firmware restore tool. |
| Linux hybrid ISO (Ubuntu, Fedora, Debian, Mint…) | ISO9660 primary volume descriptor + MBR/GPT in the first sectors (isohybrid) | Raw block copy to `rdisk` | Read back and compare SHA-256 | Non-hybrid ISOs are refused |
| Raspberry Pi OS `.img`/`.img.xz` | MBR with a FAT boot partition (`bootcode`/`config.txt`) | Streamed raw write, `.xz` decompressed on the fly (Compression framework, or `xz` only if present) | Hash check of the written range | Customisation only for confirmed image versions |
| Windows 10/11 ISO | UDF + `sources/install.wim` or `.esd` | GPT + FAT32 partition, copy files; **`install.wim` > 4 GB must be split** (wimlib, LGPL: licence review needed) or an NTFS + UEFI:NTFS layout used | File-level comparison | Raw ISO writing does **not** make a bootable Windows USB. Secure Boot depends on the loader. Must be tested on real PCs. |
| Generic `.img`/`.raw` | Partition-table probe | Raw write | Read-back hash | Shown as "unknown OS" |

## Multiboot (Ventoy-style)
Ventoy is GPLv3, and its installer runs on Windows and Linux, not macOS. Options:
1. **Integrate Ventoy's published disk image** by writing its layout directly. That needs GPL compliance (source offer, licence text) and boot tests on real hardware.
2. **Native GRUB2-based multiboot** (GPLv3, same obligations) with loopback ISO entries. Distro-specific, so lower compatibility.

Decision is deferred to Phase 8. Nothing is marked complete without physical boot tests.

## Mandatory safety gate (to be built and unit-tested *before* writes are enabled)
1. Never auto-select a target. 2. Refuse the boot disk and any internal or non-removable media (`DADiskDescriptionDeviceInternalKey`, `MediaRemovable/Ejectable`). 3. The target is chosen explicitly and shown with vendor, model and capacity. 4. A separate typed or explicit erase confirmation. 5. Revalidate BSD name + media UUID + size + removable flag right before opening the device. 6. Abort on a disappear callback. 7. A global single-operation lock. 8. Log every destructive step. 9. Explain that an interrupted write can leave the drive unbootable.
