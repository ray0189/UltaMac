import Foundation
import CoreServices

public enum AppArchitecture: String, Sendable {
    case universal = "Universal"
    case appleSilicon = "Apple Silicon"
    case intel = "Intel"
    case unknown = "Unknown"

    /// Reads the Mach-O header of an executable (fat or thin).
    public static func of(executable url: URL) -> AppArchitecture {
        guard let h = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? h.close() }
        guard let header = try? h.read(upToCount: 4096), header.count >= 8 else { return .unknown }
        let bytes = [UInt8](header)
        func be32(_ o: Int) -> UInt32 { bytes[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func le32(_ o: Int) -> UInt32 { bytes[o..<o + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        let arm64: UInt32 = 0x0100_000C, x86_64: UInt32 = 0x0100_0007
        var cpus: [UInt32] = []
        switch be32(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF: // FAT_MAGIC, FAT_MAGIC_64 (big-endian)
            let count = Int(be32(4))
            let stride = be32(0) == 0xCAFE_BABE ? 20 : 32
            for i in 0..<min(count, 16) where 8 + i * stride + 4 <= bytes.count {
                cpus.append(be32(8 + i * stride))
            }
        default:
            if le32(0) == 0xFEED_FACF || le32(0) == 0xFEED_FACE { cpus = [le32(4)] }
        }
        let hasArm = cpus.contains(arm64), hasIntel = cpus.contains(x86_64)
        switch (hasArm, hasIntel) {
        case (true, true): return .universal
        case (true, false): return .appleSilicon
        case (false, true): return .intel
        default: return .unknown
        }
    }
}

public struct InstalledApp: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let isFromAppStore: Bool
    public var size: Int64?
    public var architecture: AppArchitecture = .unknown
    /// From Spotlight (`kMDItemLastUsedDate`); nil if never recorded.
    public var lastUsed: Date?

    public func isUnused(days: Int, now: Date = Date()) -> Bool {
        guard let lastUsed else { return true }
        return now.timeIntervalSince(lastUsed) > Double(days) * 86_400
    }
}

public struct AppInventory: Sendable {
    public let searchFolders: [URL]
    public var excludedBundleIDs: Set<String>

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                searchFolders: [URL]? = nil,
                excludedBundleIDs: Set<String> = []) {
        self.searchFolders = searchFolders ?? [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
        self.excludedBundleIDs = excludedBundleIDs
    }

    /// Lists third-party apps (Apple apps and excluded bundle IDs are skipped).
    public func listApps() -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        let fm = FileManager.default
        for folder in searchFolders {
            guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                var candidates: [URL] = []
                if entry.pathExtension == "app" {
                    candidates = [entry]
                } else if folder.lastPathComponent == "Applications",
                          entry.lastPathComponent != "Utilities",
                          (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // One level of vendor folders, e.g. /Applications/Adobe Photoshop 2026/*.app
                    candidates = ((try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.pathExtension == "app" }
                }
                for appURL in candidates {
                    let key = appURL.resolvingSymlinksInPath().path
                    guard !seen.contains(key), let app = AppInventory.describe(appURL) else { continue }
                    seen.insert(key)
                    if let id = app.bundleID, id.hasPrefix("com.apple.") || excludedBundleIDs.contains(id) { continue }
                    apps.append(app)
                }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func describe(_ url: URL) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        let info = (NSDictionary(contentsOf: plistURL) as? [String: Any]) ?? [:]
        let fallbackName = url.deletingPathExtension().lastPathComponent
        let name = (info["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackName
        let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")
        let executable = (info["CFBundleExecutable"] as? String).map {
            url.appendingPathComponent("Contents/MacOS").appendingPathComponent($0)
        }
        var lastUsed: Date?
        if let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) {
            lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        }
        return InstalledApp(
            url: url,
            name: fallbackName.isEmpty ? name : fallbackName,
            bundleID: info["CFBundleIdentifier"] as? String,
            version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String),
            isFromAppStore: FileManager.default.fileExists(atPath: receipt.path),
            size: nil,
            architecture: executable.map(AppArchitecture.of(executable:)) ?? .unknown,
            lastUsed: lastUsed)
    }
}
