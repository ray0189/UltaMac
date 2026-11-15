import SwiftUI

enum NavGroup: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case cleaning = "Cleaning & Storage"
    case system = "System & Performance"
    case tools = "Tools & Recovery"
    var id: String { rawValue }
}

/// Every screen in UltaMac. `isAvailable == false` screens are clearly-labelled placeholders.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    // Overview
    case dashboard, activity
    // Cleaning & Storage
    case cleaner, storage, duplicates, largeOld, uninstaller
    // System & Performance
    case optimise, monitor, processes, battery, startup, network, maintenance
    // Tools & Recovery
    case usbToolkit, diskManager, isoLibrary, reports
    // Settings
    case permissions, settings

    var id: String { rawValue }

    var group: NavGroup? {
        switch self {
        case .dashboard, .activity: .overview
        case .cleaner, .storage, .duplicates, .largeOld, .uninstaller: .cleaning
        case .optimise, .monitor, .processes, .battery, .startup, .network, .maintenance: .system
        case .usbToolkit, .diskManager, .isoLibrary, .reports: .tools
        case .settings, .permissions: nil
        }
    }

    var title: String {
        switch self {
        case .dashboard: "Smart Scan"
        case .activity: "Recent Activity"
        case .cleaner: "Smart Cleaner"
        case .storage: "Storage Analyser"
        case .duplicates: "Duplicate Finder"
        case .largeOld: "Large & Old Files"
        case .uninstaller: "App Uninstaller"
        case .optimise: "Optimise"
        case .monitor: "Live Monitor"
        case .processes: "Process Inspector"
        case .battery: "Battery"
        case .startup: "Startup Manager"
        case .network: "Network Inspector"
        case .maintenance: "Maintenance"
        case .usbToolkit: "USB & OS Toolkit"
        case .diskManager: "Disk Manager"
        case .isoLibrary: "ISO Library"
        case .reports: "System Reports"
        case .permissions: "Permissions"
        case .settings: "Settings"
        }
    }

    var summary: String {
        switch self {
        case .dashboard: "Your Mac at a glance, plus a one-click scan."
        case .activity: "Everything UltaMac has removed, kept on this Mac only."
        case .cleaner: "Caches, logs and developer leftovers, found by transparent rules."
        case .storage: "See exactly what fills your disk."
        case .duplicates: "Identical files, confirmed byte-for-byte with SHA-256."
        case .largeOld: "Big files and files you haven't opened in a long time."
        case .uninstaller: "Remove apps together with the files they leave behind."
        case .optimise: "Find and fix what is slowing your Mac."
        case .monitor: "Live CPU, memory and network activity."
        case .processes: "What's running, and what it uses."
        case .battery: "Charge, health and power details from the battery controller."
        case .startup: "Background items that start automatically."
        case .network: "Interfaces, addresses and DNS."
        case .maintenance: "Supported, safe maintenance tasks."
        case .usbToolkit: "Bootable installers for macOS, Windows and Linux."
        case .diskManager: "Inspect, format and image removable drives."
        case .isoLibrary: "Organise and verify your disk images."
        case .reports: "Export detailed system information."
        case .permissions: "What UltaMac can access, and how to change it."
        case .settings: "Appearance, sounds, permissions and rules."
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "sparkles"
        case .activity: "clock.arrow.circlepath"
        case .cleaner: "wand.and.stars"
        case .storage: "square.grid.3x3.fill"
        case .duplicates: "doc.on.doc"
        case .largeOld: "archivebox"
        case .uninstaller: "xmark.app"
        case .optimise: "gauge.with.dots.needle.67percent"
        case .monitor: "waveform.path.ecg"
        case .processes: "list.bullet.rectangle"
        case .battery: "battery.75percent"
        case .startup: "power"
        case .network: "network"
        case .maintenance: "wrench.and.screwdriver"
        case .usbToolkit: "externaldrive.badge.plus"
        case .diskManager: "internaldrive"
        case .isoLibrary: "opticaldisc"
        case .reports: "doc.text.below.ecg"
        case .permissions: "hand.raised.fill"
        case .settings: "gearshape"
        }
    }

    var tint: Theme.Tint {
        switch group {
        case .overview: .brand
        case .cleaning: self == .uninstaller ? .apps : (self == .storage ? .storage : .clean)
        case .system: .performance
        case .tools: .tools
        case nil: .settings
        }
    }

    var isAvailable: Bool { true }

    var plannedPhase: String? {
        switch self {
        case .network: "Phase 4"
        case .maintenance, .diskManager, .reports: "Phase 8"
        case .usbToolkit, .isoLibrary: "Phases 6–7"
        default: nil
        }
    }

    var plannedScope: [String] {
        switch self {
        case .network: ["Active interfaces with local IPv4/IPv6 addresses", "DNS servers and search domains (SystemConfiguration)",
                        "Per-interface traffic counters", "Reachability diagnostics without contacting any server"]
        case .maintenance: ["Verify disks with diskutil (read-only)", "Crash-report and system-log viewer",
                            "Code-signature verification of apps", "Each task explains its purpose, effect and risks"]
        case .usbToolkit: ["Bootable macOS installers via Apple's createinstallmedia", "Linux hybrid ISO and Raspberry Pi image writing",
                           "Windows installer media (GPT/FAT32 with install.wim handling)",
                           "Write → verify with SHA-256; strict protection of internal and system disks"]
        case .diskManager: ["List removable drives with vendor, model, capacity and partitions", "Safe eject, format",
                            "Create and restore raw disk images with verification"]
        case .isoLibrary: ["Import ISO/IMG images", "SHA-256 checksums compared with values you provide",
                           "Detect OS and architecture where reliable"]
        case .reports: ["Hardware, software and storage summary", "Export as Markdown or JSON, locally"]
        default: []
        }
    }

    static func items(in group: NavGroup) -> [Destination] { allCases.filter { $0.group == group } }
}
