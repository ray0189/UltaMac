import Foundation

/// Measures on-disk (allocated) size without following symlinks.
public enum SizeCalculator {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    public static func allocatedSize(of url: URL, cancel: CancellationFlag? = nil) -> Int64 {
        let values = try? url.resourceValues(forKeys: Set(keys))
        if values?.isSymbolicLink == true {
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        guard values?.isDirectory == true else {
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var counter = 0
        for case let child as URL in enumerator {
            counter += 1
            if counter & 0x3FF == 0, cancel?.isCancelled == true { break }
            guard let v = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true && v.isSymbolicLink != true { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }
}
