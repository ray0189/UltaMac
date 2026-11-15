import Foundation
import Darwin

public struct NetworkRate: Sendable {
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double
}

/// Interface byte counters via `getifaddrs` (AF_LINK `if_data`). Local only — no traffic is sent.
public final class NetworkSampler: @unchecked Sendable {
    private var previous: (inBytes: UInt64, outBytes: UInt64, time: Date)?
    private var lastRaw: [String: (UInt32, UInt32)] = [:]
    private var accumulated: [String: (UInt64, UInt64)] = [:]

    public init() {}

    private func totals() -> (UInt64, UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var inTotal: UInt64 = 0, outTotal: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }
            let ifData = data.assumingMemoryBound(to: if_data.self).pointee
            let raw = (ifData.ifi_ibytes, ifData.ifi_obytes)
            // 32-bit counters wrap at 4 GiB; accumulate deltas with wrap handling.
            var acc = accumulated[name] ?? (0, 0)
            if let last = lastRaw[name] {
                acc.0 &+= UInt64(raw.0 &- last.0)
                acc.1 &+= UInt64(raw.1 &- last.1)
            }
            lastRaw[name] = raw
            accumulated[name] = acc
            inTotal &+= acc.0
            outTotal &+= acc.1
        }
        return (inTotal, outTotal)
    }

    /// Returns nil on the first call.
    public func sample() -> NetworkRate? {
        let (i, o) = totals()
        let now = Date()
        defer { previous = (i, o, now) }
        guard let previous else { return nil }
        let dt = now.timeIntervalSince(previous.time)
        guard dt > 0 else { return nil }
        return NetworkRate(bytesInPerSecond: Double(i &- previous.inBytes) / dt,
                           bytesOutPerSecond: Double(o &- previous.outBytes) / dt)
    }
}
