import Foundation
import UniformTypeIdentifiers

public struct FileEntry: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case video = "Videos", archive = "Archives", diskImage = "Disk Images", audio = "Audio",
             image = "Images", document = "Documents", other = "Other"

        public var symbol: String {
            switch self {
            case .video: "film"
            case .archive: "doc.zipper"
            case .diskImage: "externaldrive"
            case .audio: "waveform"
            case .image: "photo"
            case .document: "doc.text"
            case .other: "doc"
            }
        }

        public static func of(_ url: URL) -> Kind {
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
            if ["dmg", "iso", "sparseimage", "sparsebundle", "img"].contains(url.pathExtension.lowercased()) { return .diskImage }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .archive) || type.conforms(to: .zip) || type.conforms(to: .gzip) { return .archive }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
                || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) { return .document }
            return .other
        }
    }

    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let modified: Date
    public let lastUsed: Date
    public let kind: Kind
    /// Set when the item can't be removed by your account (shown, never forced).
    public var lock: RemovalLock? = nil

    public init(url: URL, size: Int64, modified: Date, lastUsed: Date, kind: Kind, lock: RemovalLock? = nil) {
        self.url = url; self.size = size; self.modified = modified; self.lastUsed = lastUsed; self.kind = kind; self.lock = lock
    }
}

/// Finds big files and files untouched for a long time in the user's own folders.
/// Skips ~/Library, hidden folders and package contents (apps, Photos libraries…).
public struct LargeOldFinder: Sendable {
    public var roots: [URL]
    public var largeThreshold: Int64
    public var oldThresholdDays: Int
    public var oldMinimumSize: Int64
    public var now: Date

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                roots: [URL]? = nil,
                largeThreshold: Int64 = 100_000_000,
                oldThresholdDays: Int = 365,
                oldMinimumSize: Int64 = 10_000_000,
                now: Date = Date()) {
        self.roots = roots ?? [home]
        self.largeThreshold = largeThreshold
        self.oldThresholdDays = oldThresholdDays
        self.oldMinimumSize = oldMinimumSize
        self.now = now
        self.home = home
    }

    let home: URL

    static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .contentModificationDateKey, .contentAccessDateKey, .isHiddenKey,
    ]

    public func scan(cancel: CancellationFlag, progress: (@Sendable (Int) -> Void)? = nil) -> [FileEntry] {
        // Compare canonical paths (enumerators may report /private/var/… for /var/…).
        func canonical(_ path: String) -> String {
            for prefix in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(prefix) {
                return String(path.dropFirst("/private".count))
            }
            return path
        }
        let skip: Set<String> = Set(["Library", ".Trash", "Applications"].map {
            canonical(home.appendingPathComponent($0).standardizedFileURL.path)
        })
        var results: [FileEntry] = []
        var seen = 0
        let oldCutoff = now.addingTimeInterval(-Double(oldThresholdDays) * 86_400)
        for root in roots {
            guard let e = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: LargeOldFinder.keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in e {
                seen += 1
                if seen & 0x7FF == 0 {
                    if cancel.isCancelled { return results }
                    progress?(seen)
                }
                if skip.contains(canonical(url.path)) { e.skipDescendants(); continue }
                guard let v = try? url.resourceValues(forKeys: Set(LargeOldFinder.keys)) else { continue }
                // Packages (other than plain bundles) count as single items, e.g. .sparsebundle.
                let isFile = v.isRegularFile == true || (v.isPackage == true && v.isDirectory == true)
                guard isFile else { continue }
                if v.isPackage == true, url.pathExtension == "app" || url.pathExtension.hasSuffix("library") { continue }
                let size = v.isPackage == true
                    ? SizeCalculator.allocatedSize(of: url, cancel: cancel)
                    : Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                let modified = v.contentModificationDate ?? now
                let used = max(modified, v.contentAccessDate ?? modified)
                let isLarge = size >= largeThreshold
                let isOld = size >= oldMinimumSize && used < oldCutoff
                guard isLarge || isOld else { continue }
                results.append(FileEntry(url: url, size: size, modified: modified, lastUsed: used, kind: .of(url), lock: RemovalLock.check(url)))
            }
        }
        return results.sorted { $0.size > $1.size }
    }
}
