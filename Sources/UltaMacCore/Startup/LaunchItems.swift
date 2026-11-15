import Foundation

public struct LaunchItem: Sendable, Identifiable, Hashable {
    public enum Domain: String, Sendable, CaseIterable {
        case userAgent = "User agent"
        case systemAgent = "System agent"
        case systemDaemon = "System daemon"

        /// Only user-level items can be removed without administrator rights.
        public var isRemovable: Bool { self == .userAgent }
    }

    public var id: URL { url }
    public let url: URL
    public let label: String
    public let program: String?
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let disabled: Bool
    public let domain: Domain
    public let associatedBundleIDs: [String]
}

public struct LaunchItemsScanner: Sendable {
    public let folders: [(URL, LaunchItem.Domain)]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        folders = [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon),
        ]
    }

    public func scan() -> [LaunchItem] {
        var items: [LaunchItem] = []
        for (folder, domain) in folders {
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.pathExtension == "plist" {
                let plist = (NSDictionary(contentsOf: url) as? [String: Any]) ?? [:]
                let args = plist["ProgramArguments"] as? [String]
                let keepAlive: Bool = {
                    if let b = plist["KeepAlive"] as? Bool { return b }
                    return plist["KeepAlive"] is [String: Any]
                }()
                items.append(LaunchItem(
                    url: url,
                    label: plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent,
                    program: (plist["Program"] as? String) ?? args?.first,
                    runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                    keepAlive: keepAlive,
                    disabled: plist["Disabled"] as? Bool ?? false,
                    domain: domain,
                    associatedBundleIDs: plist["AssociatedBundleIdentifiers"] as? [String] ?? []))
            }
        }
        return items.sorted { ($0.domain.rawValue, $0.label) < ($1.domain.rawValue, $1.label) }
    }
}
