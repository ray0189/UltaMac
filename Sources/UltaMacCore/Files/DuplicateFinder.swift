import Foundation
import CryptoKit

public struct DuplicateGroup: Sendable, Identifiable, Hashable {
    public var id: String { hash }
    public let hash: String
    public let size: Int64
    /// Oldest first; the first file is the suggested one to keep.
    public let files: [FileEntry]
    public var wasted: Int64 { size * Int64(files.count - 1) }

    public init(hash: String, size: Int64, files: [FileEntry]) {
        self.hash = hash
        self.size = size
        self.files = files
    }
}

public struct DuplicateScanProgress: Sendable {
    public let phase: String
    public let done: Int
    public let total: Int
}

/// Finds identical files: group by size, then a quick hash of the first and last 64 KB,
/// then a full SHA-256. Hard links to the same file are not reported as duplicates.
public struct DuplicateFinder: Sendable {
    public var roots: [URL]
    public var minimumSize: Int64

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                roots: [URL]? = nil,
                minimumSize: Int64 = 1_000_000) {
        self.roots = roots ?? ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { home.appendingPathComponent($0) }
        self.minimumSize = minimumSize
    }

    static let keys: [URLResourceKey] = [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .contentAccessDateKey,
        .creationDateKey, .fileResourceIdentifierKey,
    ]

    public func scan(cancel: CancellationFlag,
                     progress: (@Sendable (DuplicateScanProgress) -> Void)? = nil) -> [DuplicateGroup] {
        // 1. Collect candidates by exact byte size.
        var bySize: [Int64: [(URL, URLResourceValues)]] = [:]
        var seenIDs = Set<NSObject>()
        var counted = 0
        for root in roots {
            guard let e = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: DuplicateFinder.keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in e {
                counted += 1
                if counted & 0x3FF == 0 {
                    if cancel.isCancelled { return [] }
                    progress?(DuplicateScanProgress(phase: "Listing files", done: counted, total: 0))
                }
                guard let v = try? url.resourceValues(forKeys: Set(DuplicateFinder.keys)),
                      v.isRegularFile == true, let size = v.fileSize, Int64(size) >= minimumSize else { continue }
                if let id = v.fileResourceIdentifier as? NSObject {
                    if seenIDs.contains(id) { continue } // hard link to a file already listed
                    seenIDs.insert(id)
                }
                bySize[Int64(size), default: []].append((url, v))
            }
        }
        let sizeGroups = bySize.filter { $0.value.count > 1 }

        // 2. Quick hash, 3. full hash.
        let totalFiles = sizeGroups.values.reduce(0) { $0 + $1.count }
        var done = 0
        var groups: [DuplicateGroup] = []
        for (size, files) in sizeGroups {
            if cancel.isCancelled { return [] }
            var byQuick: [String: [(URL, URLResourceValues)]] = [:]
            for file in files {
                if let h = DuplicateFinder.quickHash(file.0, size: size) { byQuick[h, default: []].append(file) }
                done += 1
                progress?(DuplicateScanProgress(phase: "Comparing contents", done: done, total: totalFiles))
            }
            for candidates in byQuick.values where candidates.count > 1 {
                var byFull: [String: [(URL, URLResourceValues)]] = [:]
                for file in candidates {
                    if cancel.isCancelled { return [] }
                    if let h = DuplicateFinder.fullHash(file.0, cancel: cancel) { byFull[h, default: []].append(file) }
                }
                for (hash, same) in byFull where same.count > 1 {
                    let entries = same.map { url, v in
                        FileEntry(url: url, size: size,
                                  modified: v.contentModificationDate ?? .distantPast,
                                  lastUsed: v.contentAccessDate ?? v.contentModificationDate ?? .distantPast,
                                  kind: FileEntry.Kind.of(url), lock: RemovalLock.check(url))
                    }
                    let created = Dictionary(uniqueKeysWithValues: same.map { ($0.0, $0.1.creationDate ?? .distantFuture) })
                    let sorted = entries.sorted {
                        let a = created[$0.url]!, b = created[$1.url]!
                        return a != b ? a < b : $0.url.path.count < $1.url.path.count
                    }
                    groups.append(DuplicateGroup(hash: hash, size: size, files: sorted))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    static func quickHash(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let chunk = 65_536
        var hasher = SHA256()
        guard let head = try? h.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if size > Int64(chunk * 2) {
            try? h.seek(toOffset: UInt64(size) - UInt64(chunk))
            if let tail = try? h.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ url: URL, cancel: CancellationFlag) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            if cancel.isCancelled { return nil }
            guard let data = try? h.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
