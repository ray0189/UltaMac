import Foundation
import Darwin
import SystemConfiguration

public struct NetworkInterfaceInfo: Sendable, Identifiable, Hashable {
    public var id: String { bsdName }
    public let bsdName: String
    public let displayName: String
    public let kind: String
    public let macAddress: String?
    public let ipv4: [String]
    public let ipv6: [String]
    public let isUp: Bool
    public let isRunning: Bool
    public let mtu: Int
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let isPrimary: Bool
}

public struct NetworkConnection: Sendable, Identifiable, Hashable {
    public var id: String { "\(pid)-\(proto)-\(local)-\(remote)" }
    public let process: String
    public let pid: Int32
    public let proto: String
    public let local: String
    public let remote: String
    public let state: String
}

public struct NetworkSnapshot: Sendable {
    public let hostName: String
    public let interfaces: [NetworkInterfaceInfo]
    public let dnsServers: [String]
    public let searchDomains: [String]
    public let router: String?
    public let primaryInterface: String?

    /// Reads local configuration only. Nothing is sent on the network.
    public static func current() -> NetworkSnapshot {
        let store = SCDynamicStoreCreate(nil, "UltaMac" as CFString, nil, nil)
        let dns = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/DNS" as CFString) as? [String: Any] } ?? [:]
        let ipv4 = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] } ?? [:]
        let primary = ipv4["PrimaryInterface"] as? String

        var names: [String: (String, String)] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all {
                if let bsd = SCNetworkInterfaceGetBSDName(i) as String? {
                    names[bsd] = ((SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd,
                                  (SCNetworkInterfaceGetInterfaceType(i) as String?) ?? "")
                }
            }
        }

        struct Acc { var mac: String?; var v4: [String] = []; var v6: [String] = []; var up = false; var running = false
            var mtu = 0; var inB: UInt64 = 0; var outB: UInt64 = 0 }
        var acc: [String: Acc] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&head) == 0, let first = head {
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let ifa = cursor {
                defer { cursor = ifa.pointee.ifa_next }
                let name = String(cString: ifa.pointee.ifa_name)
                var a = acc[name] ?? Acc()
                let flags = Int32(ifa.pointee.ifa_flags)
                a.up = a.up || flags & IFF_UP != 0
                a.running = a.running || flags & IFF_RUNNING != 0
                if let addr = ifa.pointee.ifa_addr {
                    switch Int32(addr.pointee.sa_family) {
                    case AF_INET:
                        // inet_ntop is a pure conversion; getnameinfo can block on resolver services.
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                        if inet_ntop(AF_INET, &sin, &buf, socklen_t(buf.count)) != nil { a.v4.append(String(cString: buf)) }
                    case AF_INET6:
                        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        var sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                        if inet_ntop(AF_INET6, &sin6, &buf, socklen_t(buf.count)) != nil { a.v6.append(String(cString: buf)) }
                    case AF_LINK:
                        addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                            let len = Int(dl.pointee.sdl_alen)
                            if len == 6 {
                                let bytes = withUnsafeBytes(of: dl.pointee.sdl_data) { Array($0) }
                                let start = Int(dl.pointee.sdl_nlen)
                                if bytes.count >= start + 6 {
                                    a.mac = bytes[start..<start + 6].map { String(format: "%02x", $0) }.joined(separator: ":")
                                }
                            }
                        }
                        if let data = ifa.pointee.ifa_data {
                            let d = data.assumingMemoryBound(to: if_data.self).pointee
                            a.mtu = Int(d.ifi_mtu); a.inB = UInt64(d.ifi_ibytes); a.outB = UInt64(d.ifi_obytes)
                        }
                    default: break
                    }
                }
                acc[name] = a
            }
            freeifaddrs(head)
        }

        let interfaces = acc.compactMap { name, a -> NetworkInterfaceInfo? in
            // Hide internal plumbing interfaces unless they carry an address.
            let internalPrefixes = ["lo", "gif", "stf", "anpi", "ap", "awdl", "llw", "utun", "bridge"]
            if internalPrefixes.contains(where: { name.hasPrefix($0) }) && a.v4.isEmpty { return nil }
            let (display, type) = names[name] ?? (name, "")
            return NetworkInterfaceInfo(bsdName: name, displayName: display, kind: type.isEmpty ? "Virtual" : type,
                                        macAddress: a.mac, ipv4: a.v4, ipv6: a.v6, isUp: a.up, isRunning: a.running,
                                        mtu: a.mtu, bytesIn: a.inB, bytesOut: a.outB, isPrimary: name == primary)
        }
        .sorted { ($0.isPrimary ? 0 : 1, $0.ipv4.isEmpty ? 1 : 0, $0.bsdName) < ($1.isPrimary ? 0 : 1, $1.ipv4.isEmpty ? 1 : 0, $1.bsdName) }

        return NetworkSnapshot(
            hostName: (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" } ?? "Unknown",
            interfaces: interfaces,
            dnsServers: dns["ServerAddresses"] as? [String] ?? [],
            searchDomains: dns["SearchDomains"] as? [String] ?? [],
            router: ipv4["Router"] as? String,
            primaryInterface: primary)
    }

    /// Open internet sockets of the current user's processes (via `lsof`, read-only).
    public static func connections() -> [NetworkConnection] {
        let r = ProcessRunner.run("/usr/sbin/lsof", ["-nP", "-i", "-F", "pcPnT"], timeout: 15)
        var result: [NetworkConnection] = []
        var pid: Int32 = 0, command = "", proto = ""
        for line in r.output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "P": proto = value
            case "n":
                let parts = value.components(separatedBy: "->")
                result.append(NetworkConnection(process: command, pid: pid, proto: proto, local: parts[0],
                                                remote: parts.count > 1 ? parts[1] : "", state: ""))
            case "T":
                if value.hasPrefix("ST="), let last = result.popLast() {
                    result.append(NetworkConnection(process: last.process, pid: last.pid, proto: last.proto,
                                                    local: last.local, remote: last.remote, state: String(value.dropFirst(3))))
                }
            default: break
            }
        }
        return Array(Set(result)).sorted { ($0.process, $0.local) < ($1.process, $1.local) }
    }
}
