import Foundation
import CryptoKit

public struct WriteProgress: Sendable {
    public let phase: String
    public let done: Int64
    public let total: Int64
    public let bytesPerSecond: Double

    public var fraction: Double? { total > 0 ? min(1, Double(done) / Double(total)) : nil }
    public var secondsRemaining: Double? {
        guard bytesPerSecond > 0, total > done else { return nil }
        return Double(total - done) / bytesPerSecond
    }
}

public struct WriteResult: Sendable {
    public let verified: Bool
    public let summary: String
    public let sha256: String?
    public let log: [String]
}

public enum DiskWriteError: Error, LocalizedError {
    case busy
    case gate(String)
    case tool(String)
    case io(String)
    case cancelled
    case verification(String)

    public var errorDescription: String? {
        switch self {
        case .busy: "Another disk operation is already running."
        case .gate(let m), .tool(let m), .io(let m), .verification(let m): m
        case .cancelled: "Cancelled. The drive was partially written and may not boot. Erase it before reusing it."
        }
    }
}

/// Shared operation log (JSON lines in Application Support/UltaMac/disk-operations.log).
public final class DiskOperationLog: @unchecked Sendable {
    public static let shared = DiskOperationLog()
    private let lock = NSLock()
    public let url: URL = AuditLog.defaultURL.deletingLastPathComponent().appendingPathComponent("disk-operations.log")

    public func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close() }
    }
}

struct OperationContext {
    let gate: DiskSafetyGate
    let cancel: CancellationFlag
    let progress: @Sendable (WriteProgress) -> Void
    var log: [String] = []

    mutating func note(_ s: String) {
        log.append(s)
        DiskOperationLog.shared.write(s)
    }
}

// MARK: - Raw images (Linux hybrid ISOs, Raspberry Pi and other .img files)

public enum RawImageWriter {
    static let chunk = 4 << 20

    public static func write(image: URL, to selected: DiskDevice, gate: DiskSafetyGate, cancel: CancellationFlag,
                             progress: @escaping @Sendable (WriteProgress) -> Void) throws -> WriteResult {
        guard DiskOperationLock.shared.acquire() else { throw DiskWriteError.busy }
        defer { DiskOperationLock.shared.release() }
        var ctx = OperationContext(gate: gate, cancel: cancel, progress: progress)
        let size = Int64((try? image.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard size > 0 else { throw DiskWriteError.io("The image is empty or unreadable.") }

        ctx.note("RAW WRITE start: \(image.lastPathComponent) (\(size) bytes) → \(selected.bsdName) [\(selected.mediaName), \(selected.size) bytes]")
        let disk: DiskDevice
        do { disk = try gate.revalidate(selected, requiredBytes: size) } catch {
            ctx.note("ABORT revalidation: \(error.localizedDescription)")
            throw DiskWriteError.gate(error.localizedDescription)
        }
        let unmount = DiskInventory.unmount(disk)
        guard unmount.succeeded else { throw DiskWriteError.tool("Couldn't unmount \(disk.bsdName): \(unmount.stderr)") }
        ctx.note("Unmounted \(disk.bsdName)")

        let sink = try DeviceSink(path: disk.rawNode)
        ctx.note("Opened \(disk.rawNode) via \(sink.viaAuthopen ? "authopen (administrator prompt)" : "direct access")")
        guard let input = try? FileHandle(forReadingFrom: image) else { throw DiskWriteError.io("Couldn't open the image.") }
        defer { try? input.close() }

        var hasher = SHA256()
        var written: Int64 = 0
        let start = Date()
        do {
            while true {
                if cancel.isCancelled { sink.abort(); ctx.note("CANCELLED at \(written) bytes"); throw DiskWriteError.cancelled }
                guard var data = try input.read(upToCount: chunk), !data.isEmpty else { break }
                // Raw devices need whole sectors: pad the final chunk with zeros.
                let remainder = data.count % 512
                if remainder != 0 { data.append(Data(count: 512 - remainder)) }
                hasher.update(data: data)
                try sink.write(data)
                written += Int64(data.count)
                let elapsed = max(Date().timeIntervalSince(start), 0.001)
                progress(WriteProgress(phase: "Writing", done: written, total: size, bytesPerSecond: Double(written) / elapsed))
            }
            try sink.finish()
        } catch let e as DiskWriteError {
            throw e
        } catch {
            ctx.note("WRITE ERROR at \(written) bytes: \(error.localizedDescription)")
            throw DiskWriteError.io("Writing failed after \(ByteFormat.string(written)): \(error.localizedDescription). The drive may have been removed. Erase it before reusing it.")
        }
        let writtenHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        ctx.note("Wrote \(written) bytes, SHA-256 \(writtenHash)")

        // Verify by reading the same number of bytes back from the device.
        let readHash = try readBack(path: disk.rawNode, bytes: written, cancel: cancel) { done in
            progress(WriteProgress(phase: "Verifying", done: done, total: written, bytesPerSecond: 0))
        }
        let ok = readHash == writtenHash
        ctx.note("VERIFY \(ok ? "PASSED" : "FAILED"): device SHA-256 \(readHash)")
        guard ok else { throw DiskWriteError.verification("Verification failed: the data read back from the drive doesn't match the image. The drive may be faulty.") }
        return WriteResult(verified: true, summary: "Written and verified (\(ByteFormat.string(written))).", sha256: writtenHash, log: ctx.log)
    }

    static func readBack(path: String, bytes: Int64, cancel: CancellationFlag, progress: (Int64) -> Void) throws -> String {
        var hasher = SHA256()
        var remaining = bytes
        var done: Int64 = 0
        if let h = FileHandle(forReadingAtPath: path) {
            defer { try? h.close() }
            while remaining > 0 {
                if cancel.isCancelled { throw DiskWriteError.cancelled }
                guard let d = try h.read(upToCount: Int(min(Int64(chunk), remaining))), !d.isEmpty else { break }
                hasher.update(data: d); remaining -= Int64(d.count); done += Int64(d.count); progress(done)
            }
        } else {
            // Root-owned device: authopen streams it to stdout after an administrator prompt.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
            p.arguments = [path]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            let h = out.fileHandleForReading
            while remaining > 0 {
                if cancel.isCancelled { p.terminate(); throw DiskWriteError.cancelled }
                guard let d = try h.read(upToCount: Int(min(Int64(chunk), remaining))), !d.isEmpty else { break }
                hasher.update(data: d); remaining -= Int64(d.count); done += Int64(d.count); progress(done)
            }
            p.terminate()
        }
        guard remaining == 0 else { throw DiskWriteError.verification("Couldn't read the written data back from the drive.") }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Writes to a raw device directly when permitted (e.g. disk images you attached), otherwise
/// through `/usr/libexec/authopen -w`, Apple's tool that asks for an administrator password
/// for this one device and copies stdin to it. No persistent privileged process is left behind.
final class DeviceSink {
    private var direct: FileHandle?
    private var process: Process?
    private var pipe: Pipe?
    let viaAuthopen: Bool

    init(path: String) throws {
        if let h = FileHandle(forWritingAtPath: path) {
            direct = h
            viaAuthopen = false
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
            p.arguments = ["-w", path]
            let pipe = Pipe()
            p.standardInput = pipe
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            process = p
            self.pipe = pipe
            viaAuthopen = true
        }
    }

    func write(_ data: Data) throws {
        if let direct { try direct.write(contentsOf: data); return }
        guard let process, process.isRunning, let pipe else {
            throw DiskWriteError.io("Administrator authorisation was cancelled or the drive couldn't be opened.")
        }
        try pipe.fileHandleForWriting.write(contentsOf: data)
    }

    func finish() throws {
        if let direct { try direct.synchronize(); try direct.close(); return }
        try pipe?.fileHandleForWriting.close()
        process?.waitUntilExit()
        if let p = process, p.terminationStatus != 0 {
            throw DiskWriteError.io("authopen exited with status \(p.terminationStatus).")
        }
    }

    func abort() {
        try? direct?.close()
        try? pipe?.fileHandleForWriting.close()
        process?.terminate()
    }
}

// MARK: - Erase / format

public enum DiskEraser {
    public enum FileSystem: String, CaseIterable, Sendable {
        case exFAT = "ExFAT", fat32 = "FAT32", apfs = "APFS", hfs = "JHFS+"
        public var title: String {
            switch self {
            case .exFAT: "ExFAT (Mac + Windows, large files)"
            case .fat32: "FAT32 (widest compatibility, 4 GB file limit)"
            case .apfs: "APFS (Mac only)"
            case .hfs: "Mac OS Extended (Journaled)"
            }
        }
    }

    public enum Scheme: String, CaseIterable, Sendable { case gpt = "GPT", mbr = "MBR" }

    /// Volume names: FAT32 allows 11 upper-case characters.
    public static func sanitizedName(_ name: String, for fs: FileSystem) -> String {
        let allowed = name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "_" || $0 == "-" }
        let base = allowed.isEmpty ? "UNTITLED" : allowed
        return fs == .fat32 ? String(base.uppercased().prefix(11)) : String(base.prefix(40))
    }

    public static func erase(_ selected: DiskDevice, fs: FileSystem, name: String, scheme: Scheme,
                             gate: DiskSafetyGate) throws -> ProcessResult {
        guard DiskOperationLock.shared.acquire() else { throw DiskWriteError.busy }
        defer { DiskOperationLock.shared.release() }
        let disk: DiskDevice
        do { disk = try gate.revalidate(selected, requiredBytes: 0) } catch { throw DiskWriteError.gate(error.localizedDescription) }
        let volume = sanitizedName(name, for: fs)
        DiskOperationLog.shared.write("ERASE \(disk.bsdName) [\(disk.mediaName), \(disk.size) bytes] as \(fs.rawValue) \(scheme.rawValue) '\(volume)'")
        let r = ProcessRunner.run("/usr/sbin/diskutil", ["eraseDisk", fs.rawValue, volume, scheme.rawValue, disk.bsdName], timeout: 600)
        DiskOperationLog.shared.write("ERASE \(disk.bsdName) \(r.succeeded ? "OK" : "FAILED: \(r.stderr)")")
        guard r.succeeded else { throw DiskWriteError.tool(r.stderr.isEmpty ? r.output : r.stderr) }
        return r
    }
}

// MARK: - macOS installer (Apple's createinstallmedia)

public enum MacInstallerMedia {
    public static func create(installer: URL, on selected: DiskDevice, gate: DiskSafetyGate, cancel: CancellationFlag,
                              progress: @escaping @Sendable (WriteProgress) -> Void) throws -> WriteResult {
        let cim = installer.appendingPathComponent("Contents/Resources/createinstallmedia")
        guard FileManager.default.isExecutableFile(atPath: cim.path) else { throw DiskWriteError.tool("createinstallmedia wasn't found in this installer.") }
        let needed = SizeCalculator.allocatedSize(of: installer) + 1_000_000_000
        progress(WriteProgress(phase: "Preparing the drive", done: 0, total: 0, bytesPerSecond: 0))
        _ = try DiskEraser.erase(selected, fs: .hfs, name: "ULTAINSTALL", scheme: .gpt,
                                 gate: DiskSafetyGate(allowDiskImages: gate.allowDiskImages))
        guard DiskOperationLock.shared.acquire() else { throw DiskWriteError.busy }
        defer { DiskOperationLock.shared.release() }
        guard selected.size >= needed else { throw DiskWriteError.gate("The drive is too small for this installer.") }
        let volume = "/Volumes/ULTAINSTALL"
        guard FileManager.default.fileExists(atPath: volume) else { throw DiskWriteError.tool("The freshly erased volume didn't mount.") }

        DiskOperationLog.shared.write("CREATEINSTALLMEDIA \(installer.lastPathComponent) → \(selected.bsdName)")
        progress(WriteProgress(phase: "Copying the installer (Apple's tool shows no byte progress)", done: 0, total: 0, bytesPerSecond: 0))
        // Paths are passed as AppleScript arguments and quoted there, never concatenated in Swift.
        let script = ["on run argv",
                      "do shell script (quoted form of item 1 of argv) & \" --volume \" & (quoted form of item 2 of argv) & \" --nointeraction\" with administrator privileges",
                      "end run"]
        var args: [String] = []
        for line in script { args += ["-e", line] }
        args += [cim.path, volume]
        let r = ProcessRunner.run("/usr/bin/osascript", args, timeout: 3600, cancel: cancel)
        DiskOperationLog.shared.write("CREATEINSTALLMEDIA exit \(r.status) \(r.stderr)")
        if r.stderr.contains("-128") { throw DiskWriteError.tool("Cancelled at the administrator prompt. The drive was erased but no installer was written.") }
        guard r.succeeded else { throw DiskWriteError.tool("createinstallmedia failed: \(r.stderr.isEmpty ? r.output : r.stderr)") }

        // Verify: the new volume contains a validly signed installer app.
        progress(WriteProgress(phase: "Verifying", done: 0, total: 0, bytesPerSecond: 0))
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        guard let newVolume = volumes.first(where: { $0.hasPrefix("Install macOS") }) else {
            throw DiskWriteError.verification("The installer volume wasn't found after writing.")
        }
        let app = URL(fileURLWithPath: "/Volumes/\(newVolume)/\(installer.lastPathComponent)")
        let check = ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", app.path], timeout: 600)
        guard check.succeeded else { throw DiskWriteError.verification("The installer on the drive failed signature verification: \(check.stderr)") }
        return WriteResult(verified: true, summary: "Bootable installer created on “\(newVolume)” and its signature verified.", sha256: nil, log: r.output.components(separatedBy: "\n"))
    }
}

// MARK: - Windows installer media

public enum WindowsMedia {
    public static func wimlibPath() -> String? {
        ["/opt/homebrew/bin/wimlib-imagex", "/usr/local/bin/wimlib-imagex"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Blocking problems that must be resolved before erasing anything.
    public static func preflight(_ info: ImageInfo) -> [String] {
        var issues: [String] = []
        if info.os != .windows { issues.append("This image isn't a Windows installer ISO.") }
        if let wim = info.installWimSize, wim > ImageInspector.fat32Limit, wimlibPath() == nil {
            issues.append("install.wim is larger than 4 GB and wimlib-imagex isn't installed to split it (`brew install wimlib`).")
        }
        return issues
    }

    public static func create(iso: URL, info: ImageInfo, on selected: DiskDevice, gate: DiskSafetyGate, cancel: CancellationFlag,
                              progress: @escaping @Sendable (WriteProgress) -> Void) throws -> WriteResult {
        if let issue = preflight(info).first { throw DiskWriteError.gate(issue) }
        progress(WriteProgress(phase: "Erasing the drive (GPT, FAT32)", done: 0, total: 0, bytesPerSecond: 0))
        _ = try DiskEraser.erase(selected, fs: .fat32, name: "WINULTA", scheme: .gpt, gate: gate)
        guard DiskOperationLock.shared.acquire() else { throw DiskWriteError.busy }
        defer { DiskOperationLock.shared.release() }
        let target = URL(fileURLWithPath: "/Volumes/WINULTA")
        guard FileManager.default.fileExists(atPath: target.path) else { throw DiskWriteError.tool("The erased volume didn't mount.") }

        // Mount the ISO read-only.
        let r = ProcessRunner.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-plist", iso.path], timeout: 120)
        guard r.succeeded, let plist = try? PropertyListSerialization.propertyList(from: r.stdout, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw DiskWriteError.tool("The ISO couldn't be mounted.")
        }
        let isoDev = entities.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count }
        defer { if let isoDev { _ = ProcessRunner.run("/usr/bin/hdiutil", ["detach", isoDev, "-force"]) } }
        let source = URL(fileURLWithPath: mount)

        // Copy every file, splitting install.wim if it exceeds FAT32's limit.
        let fm = FileManager.default
        var files: [(URL, String, Int64)] = []
        if let e = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard v?.isRegularFile == true else { continue }
                let rel = String(url.path.dropFirst(source.path.count + 1))
                files.append((url, rel, Int64(v?.fileSize ?? 0)))
            }
        }
        let total = files.reduce(0) { $0 + $1.2 }
        var done: Int64 = 0
        let start = Date()
        var split: [(URL, String)] = []
        for (url, rel, size) in files {
            if cancel.isCancelled { throw DiskWriteError.cancelled }
            if size > ImageInspector.fat32Limit, rel.lowercased().hasSuffix("install.wim") { split.append((url, rel)); continue }
            let dest = target.appendingPathComponent(rel)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.copyItem(at: url, to: dest) } catch {
                throw DiskWriteError.io("Copying \(rel) failed: \(error.localizedDescription)")
            }
            done += size
            progress(WriteProgress(phase: "Copying Windows files", done: done, total: total,
                                   bytesPerSecond: Double(done) / max(Date().timeIntervalSince(start), 0.001)))
        }
        for (url, rel) in split {
            guard let wimlib = wimlibPath() else { throw DiskWriteError.tool("wimlib-imagex is required to split install.wim.") }
            progress(WriteProgress(phase: "Splitting install.wim into FAT32-sized parts", done: done, total: total, bytesPerSecond: 0))
            let swm = target.appendingPathComponent(rel).deletingPathExtension().appendingPathExtension("swm")
            let s = ProcessRunner.run(wimlib, ["split", url.path, swm.path, "3800"], timeout: 3600, cancel: cancel)
            guard s.succeeded else { throw DiskWriteError.tool("Splitting install.wim failed: \(s.stderr)") }
        }

        // Verify: every copied file exists with the same size.
        progress(WriteProgress(phase: "Verifying", done: 0, total: 0, bytesPerSecond: 0))
        let splitSet = Set(split.map(\.1))
        for (_, rel, size) in files where !splitSet.contains(rel) {
            let attrs = try? fm.attributesOfItem(atPath: target.appendingPathComponent(rel).path)
            guard (attrs?[.size] as? NSNumber)?.int64Value == size else {
                throw DiskWriteError.verification("\(rel) is missing or incomplete on the drive.")
            }
        }
        DiskOperationLog.shared.write("WINDOWS media created on \(selected.bsdName): \(files.count) files verified")
        return WriteResult(verified: true, summary: "Windows installer created and \(files.count) files verified\(split.isEmpty ? "" : " (install.wim split)").",
                           sha256: nil, log: [])
    }
}
