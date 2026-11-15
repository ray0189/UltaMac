# Known Limitations

- **USB media creation is untested on physical drives.** The raw writer is verified on scratch disk images only. macOS (`createinstallmedia`) and Windows workflows have never been executed. Nothing about boot compatibility is claimed until real hardware tests are done.
- **Real USB writes need your administrator password** (via Apple's `authopen` or AppleScript prompt). UltaMac never sees or stores it.
- **Windows images with install.wim > 4 GB** need `wimlib-imagex` (`brew install wimlib`, LGPL), which isn't bundled. Legacy-BIOS-only PCs aren't supported.
- **Compressed images** (.xz/.gz/.zip) must be decompressed first. Multiboot (Ventoy-style) isn't implemented.
- **Folder privacy prompts:** scanning Desktop/Documents/Downloads or other apps' data makes macOS ask for permission, and scans wait for your answer. Full Disk Access avoids the prompts.
- **Root-owned items** (some App Store apps, `/Library` launch daemons) can't be removed without admin rights and are reported, never forced.
- **Temperatures and fan speeds** are only available through undocumented interfaces and aren't shown. Battery temperature isn't reported by this M1.
- **APFS clones:** reclaimable space can be overstated for cloned files (planned: `ATTR_CMNEXT_PRIVATESIZE`).
- **Last-opened dates** come from Spotlight and are missing for some apps ("Never opened").
- **Process Inspector** shows only your own processes (others need root).
- **No `.xcodeproj`:** open `Package.swift` in Xcode, or build the app with `scripts/build-app.sh`.
- Tests write to the real `~/Library/Application Support/UltaMac/disk-operations.log` (scratch-image entries only).
- **Signing:** without an Apple developer certificate, the app is ad-hoc signed with a designated requirement of `identifier "local.ultamac.app"`, so privacy permissions survive rebuilds. The trade-off: macOS identifies the app by bundle ID only, not by a developer certificate. Gatekeeper (`spctl`) rejects it as not notarized; locally built copies open normally. Signing with an Apple Development certificate (detected automatically by `build-app.sh`) removes both caveats.
- **Renamed from Sweep:** history and the image library move from `~/Library/Application Support/Sweep` automatically. Preferences (theme, sounds, exclusions) start fresh under the new bundle ID.
