import Foundation
import Security

/// A supported, explained maintenance task. Every task is read-only unless `needsAdmin`
/// says otherwise, and none of them "boost performance" by deleting system data.
public struct MaintenanceTask: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        case command(String, [String])
        case verifyAppSignatures
        case crashReports
        /// Runs through macOS's own administrator prompt (AppleScript), with a fixed command.
        case adminCommand(String)
    }

    public let id: String
    public let title: String
    public let symbol: String
    public let purpose: String
    public let effect: String
    public let risk: String
    public let kind: Kind
    public var needsAdmin: Bool { if case .adminCommand = kind { return true } else { return false } }
    public var estimatedDuration: String

    public static let all: [MaintenanceTask] = [
        MaintenanceTask(id: "verify-disk", title: "Verify startup disk", symbol: "internaldrive",
                        purpose: "Checks the APFS file system of your startup volume for errors.",
                        effect: "Read-only check using diskutil. If it reports problems, use Disk Utility's First Aid from macOS Recovery.",
                        risk: "None. The volume isn't modified; the Mac may feel slow for a few seconds.",
                        kind: .command("/usr/sbin/diskutil", ["verifyVolume", "/"]), estimatedDuration: "~20 s"),
        MaintenanceTask(id: "verify-apps", title: "Verify app signatures", symbol: "checkmark.seal",
                        purpose: "Checks every app in /Applications with macOS's code-signing framework.",
                        effect: "Lists apps whose signature is invalid or broken, which can mean a damaged or tampered app.",
                        risk: "None. Read-only.", kind: .verifyAppSignatures, estimatedDuration: "~1 min"),
        MaintenanceTask(id: "crash-reports", title: "Recent crash reports", symbol: "exclamationmark.bubble",
                        purpose: "Summarises crash and hang reports written in the last 30 days.",
                        effect: "Shows which apps crash most often, so you know what to update or report.",
                        risk: "None. Read-only.", kind: .crashReports, estimatedDuration: "instant"),
        MaintenanceTask(id: "spotlight-status", title: "Spotlight index status", symbol: "magnifyingglass",
                        purpose: "Shows whether Spotlight indexing is enabled for each volume.",
                        effect: "Read-only report from mdutil.", risk: "None.",
                        kind: .command("/usr/bin/mdutil", ["-sa"]), estimatedDuration: "instant"),
        MaintenanceTask(id: "local-snapshots", title: "Local snapshots", symbol: "clock.badge.checkmark",
                        purpose: "Lists APFS snapshots kept on the startup disk (Time Machine and system updates).",
                        effect: "Explains space that macOS reclaims automatically when needed.",
                        risk: "None. Read-only. UltaMac never deletes snapshots.",
                        kind: .command("/usr/bin/tmutil", ["listlocalsnapshots", "/"]), estimatedDuration: "instant"),
        MaintenanceTask(id: "flush-dns", title: "Flush DNS cache", symbol: "arrow.triangle.2.circlepath",
                        purpose: "Clears cached DNS answers so new network settings take effect.",
                        effect: "Useful after changing DNS servers or if a site resolves to an old address. It doesn't speed up your Mac.",
                        risk: "Low. Requires your administrator password via macOS's own prompt. Name lookups are repeated once.",
                        kind: .adminCommand("dscacheutil -flushcache; killall -HUP mDNSResponder"), estimatedDuration: "instant"),
    ]
}

public struct MaintenanceResult: Sendable {
    public let succeeded: Bool
    public let summary: String
    public let log: String
}

public enum MaintenanceRunner {
    public static func run(_ task: MaintenanceTask, cancel: CancellationFlag,
                           onLine: (@Sendable (String) -> Void)? = nil) -> MaintenanceResult {
        switch task.kind {
        case .command(let exe, let args):
            let r = ProcessRunner.run(exe, args, timeout: 600, cancel: cancel, onLine: onLine)
            let log = r.output + (r.stderr.isEmpty ? "" : "\n" + r.stderr)
            let lastLine = log.split(separator: "\n").last.map(String.init) ?? ""
            return MaintenanceResult(succeeded: r.succeeded,
                                     summary: r.timedOut ? "Timed out." : r.succeeded ? (lastLine.isEmpty ? "Completed." : lastLine) : "Failed (exit \(r.status)).",
                                     log: log)
        case .adminCommand(let command):
            // Fixed command string from the task table, never user input.
            let script = "do shell script \"\(command)\" with administrator privileges"
            let r = ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 120, cancel: cancel)
            let cancelled = r.stderr.contains("-128")
            return MaintenanceResult(succeeded: r.succeeded,
                                     summary: r.succeeded ? "Done." : cancelled ? "Cancelled at the password prompt." : "Failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                                     log: r.output + r.stderr)
        case .verifyAppSignatures:
            return verifyApps(cancel: cancel, onLine: onLine)
        case .crashReports:
            return crashSummary()
        }
    }

    static func verifyApps(cancel: CancellationFlag, onLine: (@Sendable (String) -> Void)?) -> MaintenanceResult {
        let apps = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var problems: [String] = []
        var log = ""
        for app in apps {
            if cancel.isCancelled { break }
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { continue }
            var err: Unmanaged<CFError>?
            let status = SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil, &err)
            let line: String
            if status == errSecSuccess {
                line = "✓ \(app.lastPathComponent)"
            } else {
                let reason = (err?.takeRetainedValue() as Error?)?.localizedDescription ?? "OSStatus \(status)"
                line = "✕ \(app.lastPathComponent): \(reason)"
                problems.append(app.lastPathComponent)
            }
            log += line + "\n"
            onLine?(line)
        }
        return MaintenanceResult(succeeded: true,
                                 summary: problems.isEmpty ? "All \(apps.count) apps have valid signatures." : "\(problems.count) of \(apps.count) apps failed: \(problems.joined(separator: ", "))",
                                 log: log)
    }

    public struct CrashCount: Sendable, Hashable { public let app: String; public let count: Int; public let latest: Date }

    public static func crashCounts(days: Int = 30) -> [CrashCount] {
        let folders = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                       URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var map: [String: (Int, Date)] = [:]
        for folder in folders {
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                guard ["ips", "crash", "hang", "diag"].contains(url.pathExtension) else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard date > cutoff else { continue }
                // File names look like "AppName-2026-11-15-101010.ips".
                let name = url.deletingPathExtension().lastPathComponent
                let app = name.range(of: #"-\d{4}-\d{2}-\d{2}"#, options: .regularExpression).map { String(name[..<$0.lowerBound]) } ?? name
                let cur = map[app] ?? (0, .distantPast)
                map[app] = (cur.0 + 1, max(cur.1, date))
            }
        }
        return map.map { CrashCount(app: $0.key, count: $0.value.0, latest: $0.value.1) }.sorted { $0.count > $1.count }
    }

    static func crashSummary() -> MaintenanceResult {
        let counts = crashCounts()
        let log = counts.map { "\($0.count)× \($0.app) (latest \($0.latest.formatted(date: .abbreviated, time: .shortened)))" }.joined(separator: "\n")
        return MaintenanceResult(succeeded: true,
                                 summary: counts.isEmpty ? "No crash reports in the last 30 days." : "\(counts.reduce(0) { $0 + $1.count }) reports from \(counts.count) apps in 30 days.",
                                 log: log.isEmpty ? "No reports." : log)
    }
}
