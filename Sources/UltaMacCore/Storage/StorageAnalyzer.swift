import Foundation

/// A node in the storage tree. Built on a background thread, then only read.
public final class StorageNode: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isAggregate: Bool
    public internal(set) var size: Int64
    public internal(set) var itemCount: Int
    public internal(set) var children: [StorageNode]
    public weak var parent: StorageNode?

    init(url: URL, name: String? = nil, isDirectory: Bool, isAggregate: Bool = false,
         size: Int64 = 0, itemCount: Int = 1) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.isAggregate = isAggregate
        self.size = size
        self.itemCount = itemCount
        self.children = []
    }
}

extension StorageNode {
    /// Drops removed items from the tree and subtracts their size from every ancestor.
    /// Returns the bytes freed under this node.
    @discardableResult
    public func prune(removed: Set<URL>) -> Int64 {
        var freed: Int64 = 0
        children.removeAll { child in
            guard !child.isAggregate, removed.contains(child.url) else { return false }
            freed += child.size
            return true
        }
        for child in children where child.isDirectory {
            freed += child.prune(removed: removed)
        }
        size -= freed
        return freed
    }
}

public struct StorageScanProgress: Sendable {
    public let filesScanned: Int
    public let bytesScanned: Int64
    public let currentPath: String
}

/// Builds a size tree for a folder. Directories are kept; for each directory only the
/// largest `filesPerDirectory` files are kept individually, the rest are grouped.
public struct StorageAnalyzer: Sendable {
    public var filesPerDirectory: Int
    public var minimumFileSize: Int64

    public init(filesPerDirectory: Int = 30, minimumFileSize: Int64 = 1_000_000) {
        self.filesPerDirectory = filesPerDirectory
        self.minimumFileSize = minimumFileSize
    }

    /// Cheap per-entry keys only. The volume ID is looked up for directories alone.
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    public func scan(_ root: URL,
                     cancel: CancellationFlag,
                     progress: (@Sendable (StorageScanProgress) -> Void)? = nil) -> StorageNode {
        let rootValues = try? root.resourceValues(forKeys: [.volumeIdentifierKey])
        let volume = rootValues?.volumeIdentifier as? NSObject
        let node = StorageNode(url: root, isDirectory: true, itemCount: 0)
        var state = ScanState(progress: progress)
        scanDirectory(node, volume: volume, cancel: cancel, state: &state)
        state.report(path: root.path, force: true)
        return node
    }

    struct ScanState {
        var files = 0
        var bytes: Int64 = 0
        var lastReport = Date.distantPast
        let progress: (@Sendable (StorageScanProgress) -> Void)?

        mutating func report(path: String, force: Bool = false) {
            guard let progress else { return }
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.15 {
                lastReport = now
                progress(StorageScanProgress(filesScanned: files, bytesScanned: bytes, currentPath: path))
            }
        }
    }

    private func scanDirectory(_ node: StorageNode, volume: NSObject?, cancel: CancellationFlag,
                               state: inout ScanState) {
        guard !cancel.isCancelled else { return }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: node.url, includingPropertiesForKeys: StorageAnalyzer.keys, options: [])
        } catch {
            return // unreadable (permissions): size stays 0
        }
        var files: [StorageNode] = []
        var dirs: [StorageNode] = []
        for url in contents {
            if cancel.isCancelled { return }
            guard let v = try? url.resourceValues(forKeys: Set(StorageAnalyzer.keys)) else { continue }
            let isDir = v.isDirectory == true && v.isSymbolicLink != true
            if isDir {
                // Stay on the same volume (avoids firmlinks / mounted volumes double counting).
                if let volume, let other = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject,
                   !other.isEqual(volume) { continue }
                let child = StorageNode(url: url, isDirectory: true, itemCount: 0)
                child.parent = node
                scanDirectory(child, volume: volume, cancel: cancel, state: &state)
                dirs.append(child)
            } else {
                let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                let child = StorageNode(url: url, isDirectory: false, size: size)
                child.parent = node
                files.append(child)
                state.files += 1
                state.bytes += size
            }
        }
        state.report(path: node.url.path)

        files.sort { $0.size > $1.size }
        var kept = Array(files.prefix(filesPerDirectory).filter { $0.size >= minimumFileSize })
        let rest = files.dropFirst(kept.count)
        if !rest.isEmpty {
            let aggregate = StorageNode(
                url: node.url, name: "\(rest.count) smaller file\(rest.count == 1 ? "" : "s")",
                isDirectory: false, isAggregate: true,
                size: rest.reduce(0) { $0 + $1.size }, itemCount: rest.count)
            aggregate.parent = node
            kept.append(aggregate)
        }
        node.children = (dirs + kept).sorted { $0.size > $1.size }
        node.size = dirs.reduce(0) { $0 + $1.size } + files.reduce(0) { $0 + $1.size }
        node.itemCount = dirs.reduce(0) { $0 + $1.itemCount } + files.count
    }
}
