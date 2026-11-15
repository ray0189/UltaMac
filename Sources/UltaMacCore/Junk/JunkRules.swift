import Foundation

public enum JunkCategory: String, CaseIterable, Sendable, Codable {
    case caches, logs, developer, downloads, appState, trash

    public var title: String {
        switch self {
        case .caches: return "Caches"
        case .logs: return "Logs & Crash Reports"
        case .developer: return "Developer Junk"
        case .downloads: return "Old Installers"
        case .appState: return "Saved App State"
        case .trash: return "Trash"
        }
    }

    public var symbol: String {
        switch self {
        case .caches: return "archivebox"
        case .logs: return "doc.text.magnifyingglass"
        case .developer: return "hammer"
        case .downloads: return "arrow.down.circle"
        case .appState: return "macwindow.on.rectangle"
        case .trash: return "trash"
        }
    }
}

/// How cautious to be with a rule's results.
public enum RiskLevel: Int, Sendable, Comparable, CaseIterable, Codable {
    /// Regenerated automatically; no visible effect beyond a slower first launch.
    case safe = 0
    /// Regenerated, but something noticeable happens (a sign-in, a slow rebuild, lost window positions).
    case low = 1
    /// Might be wanted; look at the items before removing.
    case review = 2

    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .safe: "Safe"
        case .low: "Low risk"
        case .review: "Review"
        }
    }
}

/// One cleaning rule. Rules describe *where* junk lives and *what removing it means*.
public struct JunkRule: Sendable, Identifiable, Hashable {
    public enum Target: Sendable, Hashable {
        /// Each top-level item inside the folder is a candidate.
        case contentsOf(String)
        /// The folder itself is a single candidate.
        case folder(String)

        public var relativePath: String {
            switch self {
            case .contentsOf(let p), .folder(let p): p
            }
        }
    }

    public let id: String
    public let title: String
    public let explanation: String
    public let category: JunkCategory
    public let target: Target
    public var risk: RiskLevel
    /// What happens after removal, in plain words.
    public var consequence: String
    /// Only include entries whose name has this prefix.
    public var namePrefix: String? = nil
    /// Exclude entries whose name has any of these prefixes.
    public var excludedPrefixes: [String] = []
    /// Only include entries with one of these extensions (lower-case).
    public var extensions: [String]? = nil
    /// Only include entries not modified for at least this many days.
    public var minimumAgeDays: Int? = nil
    public var selectedByDefault: Bool
    /// Items can only be deleted permanently (e.g. the Trash itself).
    public var permanentOnly: Bool = false
    /// Untick items whose name matches a running app's bundle identifier, and ask to quit it.
    public var protectRunningApps: Bool = false
    /// May be included in Smart Scan's one-click recommendation.
    public var autoCleanAllowed: Bool = false
}

public enum JunkRules {
    /// UltaMac's built-in rule set. Paths are relative to the home folder. Original rules,
    /// written from Apple's documented folder purposes and each tool's documentation.
    public static let builtIn: [JunkRule] = [
        JunkRule(
            id: "user-caches", title: "App caches",
            explanation: "Data apps store to speed things up and rebuild when needed.",
            category: .caches, target: .contentsOf("Library/Caches"),
            risk: .safe, consequence: "Apps may start a little slower once while they rebuild their caches.",
            excludedPrefixes: ["com.apple."], selectedByDefault: true, protectRunningApps: true, autoCleanAllowed: true),
        JunkRule(
            id: "apple-caches", title: "Apple app caches",
            explanation: "Caches from Apple's apps and services.",
            category: .caches, target: .contentsOf("Library/Caches"),
            risk: .low, consequence: "Some Apple services re-download or re-index data, which can take a while.",
            namePrefix: "com.apple.", selectedByDefault: false, protectRunningApps: true),
        JunkRule(
            id: "user-logs", title: "Logs and crash reports",
            explanation: "Diagnostic logs and crash reports written by apps.",
            category: .logs, target: .contentsOf("Library/Logs"),
            risk: .safe, consequence: "Past diagnostics are gone. Only matters if you're troubleshooting.",
            selectedByDefault: true, autoCleanAllowed: true),
        JunkRule(
            id: "xcode-derived-data", title: "Xcode DerivedData",
            explanation: "Build products and indexes for Xcode projects.",
            category: .developer, target: .contentsOf("Library/Developer/Xcode/DerivedData"),
            risk: .safe, consequence: "The next build of each project is a full (slower) build.",
            selectedByDefault: true, autoCleanAllowed: true),
        JunkRule(
            id: "xcode-previews", title: "Xcode Previews data",
            explanation: "Cached SwiftUI preview builds and simulators.",
            category: .developer, target: .folder("Library/Developer/Xcode/UserData/Previews"),
            risk: .safe, consequence: "Previews rebuild the next time they're opened.",
            selectedByDefault: true, autoCleanAllowed: true),
        JunkRule(
            id: "simulator-caches", title: "Simulator caches",
            explanation: "Cached data for iOS simulators.",
            category: .developer, target: .contentsOf("Library/Developer/CoreSimulator/Caches"),
            risk: .safe, consequence: "Simulators rebuild caches on next launch.",
            selectedByDefault: true, autoCleanAllowed: true),
        JunkRule(
            id: "ios-device-support", title: "iOS device support files",
            explanation: "Debug symbols for devices you've connected to Xcode.",
            category: .developer, target: .contentsOf("Library/Developer/Xcode/iOS DeviceSupport"),
            risk: .low, consequence: "Xcode re-copies symbols (slowly) the next time that device connects.",
            selectedByDefault: false),
        JunkRule(
            id: "npm-cache", title: "npm cache",
            explanation: "Downloaded package tarballs.",
            category: .developer, target: .folder(".npm/_cacache"),
            risk: .low, consequence: "npm downloads packages again when needed, which requires internet.",
            selectedByDefault: true),
        JunkRule(
            id: "cargo-cache", title: "Cargo download cache",
            explanation: "Downloaded Rust crate archives.",
            category: .developer, target: .folder(".cargo/registry/cache"),
            risk: .low, consequence: "Cargo downloads crates again when building, which requires internet.",
            selectedByDefault: false),
        JunkRule(
            id: "gradle-caches", title: "Gradle caches",
            explanation: "Downloaded dependencies and build caches for Gradle.",
            category: .developer, target: .folder(".gradle/caches"),
            risk: .low, consequence: "Gradle re-downloads dependencies, which requires internet.",
            selectedByDefault: false),
        JunkRule(
            id: "xdg-cache", title: "Command-line tool caches",
            explanation: "~/.cache, used by many command-line tools.",
            category: .developer, target: .contentsOf(".cache"),
            risk: .review, consequence: "Tools rebuild or re-download what they need. Some keep models or data here; review first.",
            selectedByDefault: false),
        JunkRule(
            id: "saved-app-state", title: "Saved window state",
            explanation: "Lets apps reopen their windows after restarting.",
            category: .appState, target: .contentsOf("Library/Saved Application State"),
            risk: .low, consequence: "Apps forget which windows were open.",
            extensions: ["savedstate"], selectedByDefault: false, protectRunningApps: true),
        JunkRule(
            id: "old-installers", title: "Old installers in Downloads",
            explanation: "Disk images and installer packages untouched for 14 days.",
            category: .downloads, target: .contentsOf("Downloads"),
            risk: .review, consequence: "You'd need to download these installers again to reinstall.",
            extensions: ["dmg", "pkg", "iso", "mpkg"], minimumAgeDays: 14, selectedByDefault: false),
        JunkRule(
            id: "trash", title: "Items in the Trash",
            explanation: "Files you've already moved to the Trash.",
            category: .trash, target: .contentsOf(".Trash"),
            risk: .review, consequence: "Permanently deleted. They can't be recovered.",
            selectedByDefault: false, permanentOnly: true),
    ]
}
