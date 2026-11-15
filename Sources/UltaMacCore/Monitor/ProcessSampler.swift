import Foundation
import Darwin

public struct ProcessSample: Sendable, Identifiable, Hashable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let cpuFraction: Double   // 1.0 = one full core
    public let memory: UInt64        // physical footprint
}

/// Per-process CPU and memory via `proc_pid_rusage`. Only processes owned by the current
/// user are readable without root; others are skipped.
public final class ProcessSampler: @unchecked Sendable {
    private var previousCPU: [Int32: UInt64] = [:]
    private var previousTime: UInt64 = 0
    /// pid → (start time, name). Avoids a proc_pidpath call per process per sample.
    private var names: [Int32: (UInt64, String)] = [:]
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
            let name: String
            if let cached = names[pid], cached.0 == start { name = cached.1 } else {
                name = ProcessSampler.name(of: pid)
                names[pid] = (start, name)
            }
            samples.append(ProcessSample(pid: pid, name: name,
                                         cpuFraction: fraction, memory: usage.ri_phys_footprint))
        }
        previousCPU = nextCPU
        names = names.filter { nextCPU[$0.key] != nil }
        previousTime = now
        return samples
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
