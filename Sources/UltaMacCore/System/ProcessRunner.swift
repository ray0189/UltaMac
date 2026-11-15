import Foundation

/// Runs a system tool with an argument array (never a shell string), with timeout,
/// cancellation and captured output.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
    public let timedOut: Bool

    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var succeeded: Bool { status == 0 && !timedOut }
}

public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String],
                           timeout: TimeInterval = 120,
                           cancel: CancellationFlag? = nil,
                           onLine: (@Sendable (String) -> Void)? = nil) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collected = LockedData()
        let errCollected = LockedData()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            collected.append(d)
            if let onLine { String(decoding: d, as: UTF8.self).split(whereSeparator: \.isNewline).forEach { onLine(String($0)) } }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { errCollected.append(d) }
        }
        do { try process.run() } catch {
            return ProcessResult(status: -1, stdout: Data(), stderr: error.localizedDescription, timedOut: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline { timedOut = true; process.terminate(); break }
            if cancel?.isCancelled == true { process.terminate(); break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collected.append(out.fileHandleForReading.readDataToEndOfFile())
        errCollected.append(err.fileHandleForReading.readDataToEndOfFile())
        return ProcessResult(status: process.terminationStatus, stdout: collected.value,
                             stderr: String(decoding: errCollected.value, as: UTF8.self), timedOut: timedOut)
    }

    /// Runs and parses a property-list result (e.g. `diskutil … -plist`).
    public static func plist(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) -> [String: Any]? {
        let r = run(executable, arguments, timeout: timeout)
        guard r.succeeded else { return nil }
        return (try? PropertyListSerialization.propertyList(from: r.stdout, format: nil)) as? [String: Any]
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
