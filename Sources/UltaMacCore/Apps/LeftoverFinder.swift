import Foundation

public struct Leftover: Sendable, Identifiable, Hashable {
    public enum Match: String, Sendable {
        case bundleID = "Bundle ID"
        case name = "App name"
    }

    public var id: URL { url }
    public let url: URL
    public let kind: String
    public let match: Match
    public let size: Int64

    /// Bundle-ID matches are reliable; name matches are shown unticked.
    public var selectedByDefault: Bool { match == .bundleID }
}

/// Finds an app's support files in the user's Library by bundle identifier (and, less
/// reliably, by exact app name).
public struct LeftoverFinder: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Names too generic to match on their own.
    static let genericNames: Set<String> = [
        "app", "apps", "data", "cache", "caches", "logs", "settings", "preferences", "support",
        "update", "updater", "helper", "notes", "mail", "music", "photos", "safari", "google",
        "microsoft", "adobe", "apple", "temp", "tmp", "default", "shared",
    ]

    struct Location {
        let relative: String
        let kind: String
        let allowNameMatch: Bool
    }

    static let locations: [Location] = [
        Location(relative: "Library/Application Support", kind: "Application Support", allowNameMatch: true),
        Location(relative: "Library/Caches", kind: "Cache", allowNameMatch: true),
        Location(relative: "Library/Logs", kind: "Logs", allowNameMatch: true),
        Location(relative: "Library/Preferences", kind: "Preferences", allowNameMatch: false),
        Location(relative: "Library/Containers", kind: "Container", allowNameMatch: false),
        Location(relative: "Library/Group Containers", kind: "Group Container", allowNameMatch: false),
        Location(relative: "Library/Saved Application State", kind: "Saved State", allowNameMatch: false),
        Location(relative: "Library/HTTPStorages", kind: "Web Storage", allowNameMatch: false),
        Location(relative: "Library/WebKit", kind: "WebKit Data", allowNameMatch: false),
        Location(relative: "Library/Cookies", kind: "Cookies", allowNameMatch: false),
        Location(relative: "Library/Application Scripts", kind: "Scripts", allowNameMatch: false),
        Location(relative: "Library/LaunchAgents", kind: "Launch Agent", allowNameMatch: false),
    ]

    /// - Parameter otherBundleIDs: bundle IDs of other installed apps. Entries belonging to an
    ///   app whose ID extends this one (e.g. `com.vendor.app.beta`) are not attributed to it.
    public func leftovers(for app: InstalledApp,
                          otherBundleIDs: Set<String> = [],
                          cancel: CancellationFlag? = nil) -> [Leftover] {
        let fm = FileManager.default
        let bundleID = app.bundleID?.lowercased()
        let longerSiblings = bundleID.map { id in
            otherBundleIDs.map { $0.lowercased() }.filter { $0 != id && $0.hasPrefix(id + ".") }
        } ?? []
        let name = app.name.lowercased()
        let nameUsable = name.count >= 4 && !LeftoverFinder.genericNames.contains(name)
        var results: [Leftover] = []
        var seen = Set<String>()

        for location in LeftoverFinder.locations {
            if cancel?.isCancelled == true { break }
            let folder = home.appendingPathComponent(location.relative)
            guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                let entryName = entry.lastPathComponent.lowercased()
                var match: Leftover.Match?
                if let bundleID, LeftoverFinder.matches(entryName: entryName, bundleID: bundleID,
                                                        location: location, entry: entry) {
                    match = .bundleID
                } else if location.allowNameMatch, nameUsable, entryName == name {
                    match = .name
                }
                guard let match, !seen.contains(entry.path) else { continue }
                if match == .bundleID,
                   longerSiblings.contains(where: { entryName == $0 || entryName.hasPrefix($0 + ".") }) {
                    continue
                }
                seen.insert(entry.path)
                results.append(Leftover(url: entry, kind: location.kind, match: match,
                                        size: SizeCalculator.allocatedSize(of: entry, cancel: cancel)))
            }
        }
        return results.sorted { ($0.match == .bundleID ? 0 : 1, -$0.size) < ($1.match == .bundleID ? 0 : 1, -$1.size) }
    }

    static func matches(entryName: String, bundleID: String, location: Location, entry: URL) -> Bool {
        switch location.kind {
        case "Group Container":
            // e.g. "TEAMID.com.vendor.app" or "group.com.vendor.app"
            return entryName.hasSuffix("." + bundleID) || entryName == bundleID
        case "Launch Agent":
            guard entryName.hasSuffix(".plist") else { return false }
            if entryName.hasPrefix(bundleID + ".") { return true }
            if let plist = NSDictionary(contentsOf: entry) as? [String: Any] {
                let label = (plist["Label"] as? String)?.lowercased() ?? ""
                let associated = (plist["AssociatedBundleIdentifiers"] as? [String])?.map { $0.lowercased() } ?? []
                return label == bundleID || label.hasPrefix(bundleID + ".") || associated.contains(bundleID)
            }
            return false
        default:
            if entryName == bundleID { return true }
            // com.vendor.app.plist, com.vendor.app.savedState, com.vendor.app.binarycookies, com.vendor.app.helper
            return entryName.hasPrefix(bundleID + ".")
        }
    }
}
