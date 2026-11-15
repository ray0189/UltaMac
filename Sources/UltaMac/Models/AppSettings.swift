import SwiftUI
import UltaMacCore

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor @Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var removalMode: RemovalMode { didSet { defaults.set(removalMode.rawValue, forKey: "removalMode") } }
    var exclusions: [String] { didSet { defaults.set(exclusions, forKey: "exclusions") } }
    var expertMode: Bool { didSet { defaults.set(expertMode, forKey: "expertMode") } }
    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "soundEnabled") } }
    var soundVolume: Float { didSet { defaults.set(soundVolume, forKey: "soundVolume") } }
    var soundNavigation: Bool { didSet { defaults.set(soundNavigation, forKey: "soundNavigation") } }
    var showMenuBarMonitor: Bool { didSet { defaults.set(showMenuBarMonitor, forKey: "showMenuBarMonitor") } }
    var samplingInterval: Double { didSet { defaults.set(samplingInterval, forKey: "samplingInterval") } }
    var unusedAppDays: Int { didSet { defaults.set(unusedAppDays, forKey: "unusedAppDays") } }
    /// Expert-only: lets attached disk images act as write targets (for testing the USB tools safely).
    var allowDiskImageTargets: Bool { didSet { defaults.set(allowDiskImageTargets, forKey: "allowDiskImageTargets") } }

    /// Bumped after each removal so history views reload.
    var historyRevision = 0

    let auditLog = AuditLog()

    init() {
        AppSettings.migrateLegacyData()
        removalMode = RemovalMode(rawValue: defaults.string(forKey: "removalMode") ?? "") ?? .moveToTrash
        exclusions = defaults.stringArray(forKey: "exclusions") ?? []
        expertMode = defaults.bool(forKey: "expertMode")
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true // on by default
        soundVolume = defaults.object(forKey: "soundVolume") as? Float ?? 0.6
        soundNavigation = defaults.bool(forKey: "soundNavigation")
        showMenuBarMonitor = defaults.object(forKey: "showMenuBarMonitor") as? Bool ?? true
        samplingInterval = defaults.object(forKey: "samplingInterval") as? Double ?? 2
        unusedAppDays = defaults.object(forKey: "unusedAppDays") as? Int ?? 90
        allowDiskImageTargets = defaults.bool(forKey: "allowDiskImageTargets")
    }

    var policy: SafetyPolicy {
        SafetyPolicy(userExclusions: exclusions.map { URL(fileURLWithPath: $0) })
    }

    var remover: FileRemover { FileRemover(policy: policy, auditLog: auditLog) }
    var adminRemover: AdminRemover { AdminRemover(policy: policy, auditLog: auditLog) }

    /// The app was called "Sweep" before; carry its history and library over once.
    static func migrateLegacyData() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("Sweep"), new = support.appendingPathComponent("UltaMac")
        guard fm.fileExists(atPath: old.path) else { return }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] {
            let src = old.appendingPathComponent(name), dst = new.appendingPathComponent(name)
            if !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            } else if ["log", "jsonl"].contains(src.pathExtension),
                      let older = try? Data(contentsOf: src), let newer = try? Data(contentsOf: dst) {
                // Append-only logs: keep both, older entries first.
                if (try? (older + newer).write(to: dst, options: .atomic)) != nil { try? fm.removeItem(at: src) }
            }
        }
        if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).isEmpty { try? fm.removeItem(at: old) }
    }
}

/// Runs blocking work off the main actor.
func runInBackground<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work() }.value
}

func runningBundleIDs() -> Set<String> {
    Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
}
