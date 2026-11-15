import Foundation
import IOKit

/// A local, exportable system summary. Serial numbers and MAC addresses are excluded unless
/// the caller opts in.
public struct SystemReport: Sendable, Codable {
    public struct Section: Sendable, Codable, Identifiable {
        public var id: String { title }
        public let title: String
        public let rows: [[String]] // [label, value]
    }

    public let generated: Date
    public let sections: [Section]

    public static func generate(includeIdentifiers: Bool = false) -> SystemReport {
        let info = SystemInfo.current()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let build = SysctlReader.string("kern.osversion") ?? "?"
        var hardware: [[String]] = [
            ["Model", info.model],
            ["Chip", info.chip],
            ["CPU cores", "\(info.cores)"],
            ["Memory", ByteFormat.memory(ProcessInfo.processInfo.physicalMemory)],
            ["Architecture", SysctlReader.string("hw.machine") ?? "?"],
        ]
        if includeIdentifiers, let serial = platformSerial() { hardware.append(["Serial number", serial]) }

        let software: [[String]] = [
            ["macOS", "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(build))"],
            ["Kernel", SysctlReader.string("kern.version")?.components(separatedBy: ":").first ?? "?"],
            ["Uptime", Self.duration(info.uptime)],
            ["Thermal state", info.thermalState.title],
            ["Third-party apps", "\(AppInventory().listApps().count)"],
            ["Launch agents & daemons", "\(LaunchItemsScanner().scan().count)"],
        ]

        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
                                         .volumeIsLocalKey, .volumeIsInternalKey]
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [])
            .compactMap { url -> [String]? in
                guard let r = try? url.resourceValues(forKeys: keys), let total = r.volumeTotalCapacity else { return nil }
                let free = max(r.volumeAvailableCapacityForImportantUsage ?? 0, Int64(r.volumeAvailableCapacity ?? 0))
                return [r.volumeLocalizedName ?? url.path,
                        "\(ByteFormat.string(free)) free of \(ByteFormat.string(Int64(total)))\(r.volumeIsInternal == true ? " · internal" : " · external")"]
            }

        var power: [[String]] = []
        if let b = BatteryStatus.current() {
            power = [["Charge", "\(b.percent)%\(b.isCharging ? " (charging)" : "")"],
                     ["Cycle count", b.cycleCount.map(String.init) ?? "—"],
                     ["Health", b.healthPercent.map { "\($0)% of design capacity" } ?? "—"]]
        } else {
            power = [["Battery", "None"]]
        }

        let net = NetworkSnapshot.current()
        var network: [[String]] = [["Host name", includeIdentifiers ? net.hostName : "(hidden)"],
                                   ["DNS servers", net.dnsServers.joined(separator: ", ")]]
        for i in net.interfaces where !i.ipv4.isEmpty {
            network.append(["\(i.displayName) (\(i.bsdName))", i.ipv4.joined(separator: ", ") + (includeIdentifiers ? " · \(i.macAddress ?? "")" : "")])
        }

        let memory = MemoryStats.current()
        let mem: [[String]] = memory.map { m in
            [["Used", ByteFormat.memory(m.used)], ["Pressure", m.pressure.rawValue], ["Swap used", ByteFormat.memory(m.swapUsed)]]
        } ?? []

        return SystemReport(generated: Date(), sections: [
            Section(title: "Hardware", rows: hardware),
            Section(title: "Software", rows: software),
            Section(title: "Memory", rows: mem),
            Section(title: "Storage", rows: volumes),
            Section(title: "Power", rows: power),
            Section(title: "Network", rows: network),
        ])
    }

    public var markdown: String {
        var s = "# UltaMac System Report\n\nGenerated \(generated.formatted(date: .long, time: .standard)) — created locally, never uploaded.\n"
        for section in sections {
            s += "\n## \(section.title)\n\n| Item | Value |\n|---|---|\n"
            for row in section.rows { s += "| \(row[0]) | \(row.count > 1 ? row[1] : "") |\n" }
        }
        return s
    }

    public var json: Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return (try? e.encode(self)) ?? Data()
    }

    static func platformSerial() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    static func duration(_ s: TimeInterval) -> String {
        let d = Int(s) / 86_400, h = (Int(s) % 86_400) / 3600, m = (Int(s) % 3600) / 60
        return d > 0 ? "\(d)d \(h)h" : "\(h)h \(m)m"
    }
}
