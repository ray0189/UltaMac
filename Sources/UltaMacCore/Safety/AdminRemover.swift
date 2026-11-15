import Foundation

/// Removes items that the normal remover couldn't (access-rule locks, items owned by another
/// account), using macOS's own administrator prompt. It runs only when the user explicitly asks,
/// one prompt per batch, and still refuses anything the SafetyPolicy denies (system folders,
/// SIP-protected or immutable items). UltaMac never sees or stores the password.
///
/// Trash mode moves each item into your Trash, then gives it back to your account and clears
/// its access rules so it can be restored or emptied normally.
public struct AdminRemover: Sendable {
    public let policy: SafetyPolicy
    public let auditLog: AuditLog?
    /// Tests run the same script without the administrator prompt.
    let useAdministratorPrivileges: Bool
    let trashDirectory: URL

    public init(policy: SafetyPolicy, auditLog: AuditLog? = nil) {
        self.init(policy: policy, auditLog: auditLog, useAdministratorPrivileges: true,
                  trashDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }

    init(policy: SafetyPolicy, auditLog: AuditLog?, useAdministratorPrivileges: Bool, trashDirectory: URL) {
        self.policy = policy
        self.auditLog = auditLog
        self.useAdministratorPrivileges = useAdministratorPrivileges
        self.trashDirectory = trashDirectory
    }

    /// The AppleScript receives paths as arguments and quotes them with `quoted form of`,
    /// so file names are never interpreted by the shell.
    static let script = [
        "on run argv",
        "set userID to item 1 of argv",
        "set useAdmin to item 2 of argv",
        "set cmd to \"\"",
        "repeat with i from 3 to (count of argv) by 2",
        "set src to quoted form of (item i of argv)",
        "set dst to item (i + 1) of argv",
        "if dst is \"-\" then",
        "set cmd to cmd & \"/bin/chmod -RN \" & src & \" 2>/dev/null; /bin/rm -rf -- \" & src & \"; \"",
        "else",
        "set dst to quoted form of dst",
        "set cmd to cmd & \"/bin/mv -n -- \" & src & \" \" & dst & \" && { /bin/chmod -RN \" & dst & \" 2>/dev/null; /usr/sbin/chown -R \" & userID & \" \" & dst & \"; }; \"",
        "end if",
        "end repeat",
        "set cmd to cmd & \"exit 0\"",
        "if useAdmin is \"1\" then",
        "do shell script cmd with administrator privileges",
        "else",
        "do shell script cmd",
        "end if",
        "end run",
    ]

    public func remove(_ requests: [RemovalRequest], mode: RemovalMode,
                       purpose: SafetyPolicy.Purpose = .clean, context: String = "Cleanup") -> RemovalReport {
        var report = RemovalReport(mode: mode, purpose: purpose)
        var arguments: [String] = ["\(getuid()):\(getgid())", useAdministratorPrivileges ? "1" : "0"]
        var planned: [(request: RemovalRequest, destination: URL?)] = []
        let trash = trashDirectory
        var usedNames = Set<String>()

        for request in requests.sorted(by: { $0.url.path.count > $1.url.path.count }) {
            if case .denied(let reason) = policy.check(request.url, purpose: purpose) {
                report.failures.append(RemovalFailure(url: request.url, reason: reason))
                continue
            }
            let permanent = mode == .deletePermanently || request.permanentOnly
            let destination = permanent ? nil : AdminRemover.trashDestination(for: request.url, in: trash, avoiding: &usedNames)
            arguments += [request.url.path, destination?.path ?? "-"]
            planned.append((request, destination))
        }
        guard !planned.isEmpty else { return report }

        var args: [String] = []
        for line in AdminRemover.script { args += ["-e", line] }
        args += arguments
        let result = ProcessRunner.run("/usr/bin/osascript", args, timeout: 600)
        let cancelled = result.stderr.contains("-128")

        var sizes: [URL: Int64] = [:]
        for (request, destination) in planned {
            let gone = !FileManager.default.fileExists(atPath: request.url.path) && !isSymlink(request.url)
            if gone {
                if destination != nil { report.trashed.append(request.url) } else { report.deleted.append(request.url) }
                report.bytesRemoved += request.size
                sizes[request.url] = request.size
            } else {
                let reason = cancelled ? "Cancelled at the administrator prompt."
                    : result.succeeded ? "Still locked after the administrator removal (it may have a system flag)."
                    : "Administrator removal failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                report.failures.append(RemovalFailure(url: request.url, reason: reason))
            }
        }
        auditLog?.record(report, sizes: sizes, context: context + " (administrator)")
        return report
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// A Trash path that doesn't exist yet: "name", then "name 2", "name 3"…
    static func trashDestination(for url: URL, in trash: URL, avoiding used: inout Set<String>) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        while true {
            let name = (n == 1 ? base : "\(base) \(n)") + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = trash.appendingPathComponent(name)
            if !used.contains(name), !FileManager.default.fileExists(atPath: candidate.path) {
                used.insert(name)
                return candidate
            }
            n += 1
        }
    }
}
