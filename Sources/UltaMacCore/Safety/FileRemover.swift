import Foundation

public enum RemovalMode: String, CaseIterable, Sendable, Codable {
    case moveToTrash
    case deletePermanently

    public var title: String {
        switch self {
        case .moveToTrash: return "Move to Trash"
        case .deletePermanently: return "Delete Permanently"
        }
    }
}

public struct RemovalRequest: Sendable, Hashable {
    public let url: URL
    public let size: Int64
    /// Items that can't go to the Trash (e.g. items already in it) are always deleted permanently,
    /// regardless of the batch mode. The review sheet discloses this.
    public let permanentOnly: Bool

    public init(url: URL, size: Int64, permanentOnly: Bool = false) {
        self.url = url
        self.size = size
        self.permanentOnly = permanentOnly
    }
}

public struct RemovalFailure: Sendable, Hashable, Identifiable, Codable {
    public var id: URL { url }
    public let url: URL
    public let reason: String
}

public struct RemovalReport: Sendable {
    public var trashed: [URL] = []
    public var deleted: [URL] = []
    public var failures: [RemovalFailure] = []
    public var bytesRemoved: Int64 = 0
    public var mode: RemovalMode

    public var removed: [URL] { trashed + deleted }

    public var summary: String {
        var parts: [String] = []
        if !trashed.isEmpty { parts.append("Moved \(trashed.count) item\(trashed.count == 1 ? "" : "s") to the Trash") }
        if !deleted.isEmpty { parts.append("permanently deleted \(deleted.count)") }
        var text = parts.isEmpty ? "Nothing was removed" : parts.joined(separator: ", ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        if !removed.isEmpty { text += " (\(ByteFormat.string(bytesRemoved)))" }
        if !failures.isEmpty { text += "; \(failures.count) couldn't be removed" }
        return text + "."
    }
}

/// The only component in UltaMac that removes files.
public struct FileRemover: Sendable {
    public let policy: SafetyPolicy
    public let auditLog: AuditLog?

    public init(policy: SafetyPolicy, auditLog: AuditLog? = nil) {
        self.policy = policy
        self.auditLog = auditLog
    }

    public func remove(_ requests: [RemovalRequest],
                       mode: RemovalMode,
                       purpose: SafetyPolicy.Purpose = .clean,
                       context: String = "Cleanup") -> RemovalReport {
        var report = RemovalReport(mode: mode)
        var sizes: [URL: Int64] = [:]
        let fm = FileManager()
        // Deepest paths first so parents listed alongside children don't fail spuriously.
        let ordered = requests.sorted { $0.url.path.count > $1.url.path.count }
        for request in ordered {
            if case .denied(let reason) = policy.check(request.url, purpose: purpose) {
                report.failures.append(RemovalFailure(url: request.url, reason: reason))
                continue
            }
            let itemMode: RemovalMode = request.permanentOnly ? .deletePermanently : mode
            do {
                switch itemMode {
                case .moveToTrash:
                    try fm.trashItem(at: request.url, resultingItemURL: nil)
                    report.trashed.append(request.url)
                case .deletePermanently:
                    try fm.removeItem(at: request.url)
                    report.deleted.append(request.url)
                }
                report.bytesRemoved += request.size
                sizes[request.url] = request.size
            } catch {
                report.failures.append(RemovalFailure(url: request.url, reason: FileRemover.describe(error)))
            }
        }
        auditLog?.record(report, sizes: sizes, context: context)
        return report
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return "Permission denied. It may belong to another user or need Full Disk Access."
            case NSFileNoSuchFileError:
                return "Item no longer exists."
            default: break
            }
        }
        return ns.localizedDescription
    }
}
