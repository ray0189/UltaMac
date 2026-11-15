import Foundation

/// One line in the local audit trail (JSON Lines). Never leaves the Mac.
public struct AuditEntry: Codable, Sendable, Identifiable, Hashable {
    public struct Item: Codable, Sendable, Hashable {
        public let path: String
        public let bytes: Int64
        public let permanent: Bool
    }

    public var id: Date { date }
    public let date: Date
    public let context: String
    public let items: [Item]
    public let failures: [RemovalFailure]

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

public final class AuditLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UltaMac", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
    }

    public init(url: URL = AuditLog.defaultURL) {
        self.url = url
    }

    func record(_ report: RemovalReport, sizes: [URL: Int64], context: String) {
        guard !report.removed.isEmpty || !report.failures.isEmpty else { return }
        let deleted = Set(report.deleted)
        let entry = AuditEntry(
            date: Date(), context: context,
            items: report.removed.map { AuditEntry.Item(path: $0.path, bytes: sizes[$0] ?? 0, permanent: deleted.contains($0)) },
            failures: report.failures)
        append(entry)
    }

    public func append(_ entry: AuditEntry) {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Most recent first.
    public func recent(limit: Int = 50) -> [AuditEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: "\n").suffix(limit).reversed().compactMap {
            try? decoder.decode(AuditEntry.self, from: Data($0.utf8))
        }
    }
}
