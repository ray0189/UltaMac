import Foundation
import Darwin

// MARK: - CPU

public struct CPULoad: Sendable {
    public let user: Double
    public let system: Double
    public let idle: Double
    public let perCore: [Double]
    public var total: Double { user + system }
}

/// Samples CPU ticks with `host_processor_info`; load is the difference between two samples.
public final class CPUSampler: @unchecked Sendable {
    private var previous: [[UInt32]]?

    public init() {}

    private func readTicks() -> [[UInt32]]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var result: [[UInt32]] = []
        let states = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            var ticks: [UInt32] = []
            for state in 0..<states {
                ticks.append(UInt32(bitPattern: info[cpu * states + state]))
            }
            result.append(ticks)
        }
        return result
    }

    /// Returns nil on the first call (no previous sample yet).
    public func sample() -> CPULoad? {
        guard let current = readTicks() else { return nil }
        defer { previous = current }
        guard let previous, previous.count == current.count else { return nil }
        var user: Double = 0, system: Double = 0, idle: Double = 0, total: Double = 0
        var perCore: [Double] = []
        for (old, new) in zip(previous, current) {
            func d(_ i: Int32) -> Double { Double(new[Int(i)] &- old[Int(i)]) }
            let u = d(CPU_STATE_USER) + d(CPU_STATE_NICE)
            let s = d(CPU_STATE_SYSTEM)
            let i = d(CPU_STATE_IDLE)
            let t = u + s + i
            user += u; system += s; idle += i; total += t
            perCore.append(t > 0 ? (u + s) / t : 0)
        }
        guard total > 0 else { return nil }
        return CPULoad(user: user / total, system: system / total, idle: idle / total, perCore: perCore)
    }
}

// MARK: - Memory

public struct MemoryStats: Sendable {
    public let total: UInt64
    public let app: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let cachedFiles: UInt64
    public let free: UInt64
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    public let pressure: Pressure

    public enum Pressure: String, Sendable {
        case normal = "Normal", warning = "Warning", critical = "Critical", unknown = "Unknown"
    }

    public var used: UInt64 { app + wired + compressed }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func current() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let total: UInt64 = SysctlReader.value("hw.memsize") ?? 0
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        let free = UInt64(stats.free_count) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let level: Int32 = SysctlReader.value("kern.memorystatus_vm_pressure_level") ?? 0
        let pressure: Pressure = switch level {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: .unknown
        }
        return MemoryStats(total: total, app: app, wired: wired, compressed: compressed,
                           cachedFiles: cached, free: free, swapUsed: swap.xsu_used,
                           swapTotal: swap.xsu_total, pressure: pressure)
    }
}

// MARK: - General system info

public struct SystemInfo: Sendable {
    public let model: String
    public let chip: String
    public let osVersion: String
    public let cores: Int
    public let uptime: TimeInterval
    public let loadAverage: (Double, Double, Double)
    public let thermalState: ProcessInfo.ThermalState

    public static func current() -> SystemInfo {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            uptime = Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
        }
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return SystemInfo(
            model: SysctlReader.string("hw.model") ?? "Mac",
            chip: SysctlReader.string("machdep.cpu.brand_string") ?? "Unknown",
            osVersion: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            cores: ProcessInfo.processInfo.activeProcessorCount,
            uptime: uptime,
            loadAverage: (loads[0], loads[1], loads[2]),
            thermalState: ProcessInfo.processInfo.thermalState)
    }
}

public extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - sysctl helpers

enum SysctlReader {
    static func value<T: FixedWidthInteger>(_ name: String) -> T? {
        var value: T = 0
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
