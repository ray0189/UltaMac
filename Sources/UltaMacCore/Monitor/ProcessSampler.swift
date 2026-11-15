import Foundation
import Darwin

public struct ProcessSample: Sendable, Identifiable, Hashable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let cpuFraction: Double   // 1.0 = one full core
    public let memory: UInt64        // physical footprint
    /// The outermost app bundle this process belongs to (helpers report their parent app), if any.
    public var app: String? = nil
    /// Part of macOS (in /System, /usr, /sbin…): macOS restarts these, so they're never offered for quitting.
    public var isSystem: Bool = false

    public init(pid: Int32, name: String, cpuFraction: Double, memory: UInt64, app: String? = nil, isSystem: Bool = false) {
        self.pid = pid
        self.name = name
        self.cpuFraction = cpuFraction
        self.memory = memory
        self.app = app
        self.isSystem = isSystem
    }

    /// The name to show when grouping by app.
    public var groupName: String { app ?? name }
}

/// Live usage of one app including all of its helper processes.
public struct AppUsage: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    /// The process to quit (the app's main process, or the only process).
    public let pid: Int32
    public let cpuFraction: Double
    public let memory: UInt64
    public let processCount: Int

    /// Groups samples by app; system processes are left out.
    public static func group(_ samples: [ProcessSample]) -> [AppUsage] {
        Dictionary(grouping: samples.filter { !$0.isSystem }, by: \.groupName).compactMap { name, procs in
            let main = procs.first { $0.name == name } ?? (procs.count == 1 ? procs[0] : nil)
            guard let main else { return nil }   // helpers whose app isn't running as a process
            return AppUsage(name: name, pid: main.pid, cpuFraction: procs.reduce(0) { $0 + $1.cpuFraction },
                            memory: procs.reduce(0) { $0 + $1.memory }, processCount: procs.count)
        }
    }
}

/// Per-process CPU and memory via `proc_pid_rusage`. Only processes owned by the current
/// user are readable without root; others are skipped.
public final class ProcessSampler: @unchecked Sendable {
    private var previousCPU: [Int32: UInt64] = [:]
    private var previousTime: UInt64 = 0
    /// pid → (start time, name). Avoids a proc_pidpath call per process per sample.
    private var names: [Int32: (UInt64, Identity)] = [:]
    struct Identity { let name: String; let app: String?; let isSystem: Bool }
    private let timebase: (numer: UInt64, denom: UInt64)

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }

    private func nanoseconds(_ machTicks: UInt64) -> UInt64 {
        machTicks &* timebase.numer / timebase.denom
    }

    public func sample() -> [ProcessSample] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [Int32](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))
        let now = mach_absolute_time()
        let elapsed = previousTime == 0 ? 0 : nanoseconds(now - previousTime)
        var nextCPU: [Int32: UInt64] = [:]
        var samples: [ProcessSample] = []

        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var usage = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard rc == 0 else { continue }
            // On Apple Silicon these are in mach ticks; convert to nanoseconds.
            let cpu = nanoseconds(usage.ri_user_time &+ usage.ri_system_time)
            nextCPU[pid] = cpu
            var fraction = 0.0
            if elapsed > 0, let old = previousCPU[pid], cpu >= old {
                fraction = Double(cpu - old) / Double(elapsed)
            }
            let start = usage.ri_proc_start_abstime
            let identity: Identity
            if let cached = names[pid], cached.0 == start { identity = cached.1 } else {
                identity = ProcessSampler.identity(of: pid)
                names[pid] = (start, identity)
            }
            samples.append(ProcessSample(pid: pid, name: identity.name, cpuFraction: fraction, memory: usage.ri_phys_footprint,
                                         app: identity.app, isSystem: identity.isSystem))
        }
        previousCPU = nextCPU
        names = names.filter { nextCPU[$0.key] != nil }
        previousTime = now
        return samples
    }

    static func identity(of pid: Int32) -> Identity {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return Identity(name: name(of: pid), app: nil, isSystem: true) }
        return identity(path: String(cString: path))
    }

    static func identity(path full: String) -> Identity {
        let inner = full.range(of: ".app/Contents/MacOS/", options: .backwards).map {
            ((String(full[..<$0.lowerBound])) as NSString).lastPathComponent
        }
        // iOS Simulator devices and their runtimes count as the Simulator app.
        if full.contains("CoreSimulator") || full.contains("/Simulator.app/") {
            return Identity(name: inner ?? (full as NSString).lastPathComponent, app: "Simulator", isSystem: false)
        }
        let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/", "/Library/Apple/"]
        let isSystem = systemPrefixes.contains { full.hasPrefix($0) }
        // Outermost bundle: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/…" → "Claude".
        let app = full.range(of: ".app/").map { ((String(full[..<$0.lowerBound])) as NSString).lastPathComponent }
        return Identity(name: inner ?? (full as NSString).lastPathComponent, app: app, isSystem: isSystem)
    }

    static func name(of pid: Int32) -> String {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let full = String(cString: path)
            // Prefer the app name for executables inside bundles.
            if let range = full.range(of: ".app/Contents/MacOS/") {
                let appPath = String(full[..<range.lowerBound])
                return (appPath as NSString).lastPathComponent
            }
            return (full as NSString).lastPathComponent
        }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "pid \(pid)" : name
    }
}
