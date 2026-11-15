import Foundation

public struct PartitionInfo: Sendable, Hashable, Identifiable {
    public var id: String { bsdName }
    public let bsdName: String
    public let name: String
    public let content: String     // partition type / file system personality
    public let size: Int64
    public let mountPoint: String?
}

public struct DiskDevice: Sendable, Hashable, Identifiable {
    public var id: String { bsdName }
    public let bsdName: String          // disk4
    public let mediaName: String        // vendor/model as reported
    public let size: Int64
    public let busProtocol: String      // USB, PCI-Express, Apple Fabric, Disk Image, SD…
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isWritable: Bool
    public let isVirtual: Bool
    public let scheme: String           // GUID_partition_scheme, FDisk_partition_scheme…
    public let partitions: [PartitionInfo]
    public let isBootDisk: Bool
    /// Identity used to detect that a device was removed or replaced before a write.
    public let fingerprint: String

    public var deviceNode: String { "/dev/\(bsdName)" }
    public var rawNode: String { "/dev/r\(bsdName)" }
    public var schemeTitle: String {
        switch scheme {
        case "GUID_partition_scheme": "GPT"
        case "FDisk_partition_scheme": "MBR"
        case "Apple_partition_scheme": "APM"
        case "": "None"
        default: scheme
        }
    }
    public var mountPoints: [String] { partitions.compactMap(\.mountPoint) }
}

/// Lists disks using `diskutil … -plist` (Apple's supported, stable plist interface).
public enum DiskInventory {
    public static func list() -> [DiskDevice] {
        guard let all = ProcessRunner.plist("/usr/sbin/diskutil", ["list", "-plist"]),
              let disks = all["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        let boot = bootPhysicalDisks()
        return disks.compactMap { entry -> DiskDevice? in
            guard let id = entry["DeviceIdentifier"] as? String else { return nil }
            return device(id, listEntry: entry, bootDisks: boot)
        }
        // Synthesized APFS containers duplicate their physical store; keep physical + images.
        .filter { !$0.mediaName.isEmpty || $0.isVirtual }
    }

    public static func device(_ bsd: String, listEntry: [String: Any]? = nil, bootDisks: Set<String>? = nil) -> DiskDevice? {
        guard let info = ProcessRunner.plist("/usr/sbin/diskutil", ["info", "-plist", bsd]) else { return nil }
        if (info["VirtualOrPhysical"] as? String) == "Virtual", (info["BusProtocol"] as? String) != "Disk Image" {
            // APFS synthesized container: not a physical target.
            return nil
        }
        let entry = listEntry ?? listEntryFor(bsd) ?? [:]
        let parts = (entry["Partitions"] as? [[String: Any]] ?? []).map { p in
            PartitionInfo(bsdName: p["DeviceIdentifier"] as? String ?? "?",
                          name: p["VolumeName"] as? String ?? "",
                          content: p["Content"] as? String ?? "",
                          size: (p["Size"] as? NSNumber)?.int64Value ?? 0,
                          mountPoint: p["MountPoint"] as? String)
        }
        let size = (info["TotalSize"] as? NSNumber ?? info["Size"] as? NSNumber)?.int64Value ?? 0
        let media = (info["MediaName"] as? String) ?? (info["IORegistryEntryName"] as? String) ?? ""
        let bus = info["BusProtocol"] as? String ?? "Unknown"
        let boots = bootDisks ?? bootPhysicalDisks()
        let fingerprint = [bsd, "\(size)", media, info["IORegistryEntryName"] as? String ?? "", bus,
                           info["DiskUUID"] as? String ?? "", info["MediaUUID"] as? String ?? ""].joined(separator: "|")
        return DiskDevice(
            bsdName: bsd, mediaName: media, size: size, busProtocol: bus,
            isInternal: info["Internal"] as? Bool ?? true,
            isRemovable: (info["RemovableMedia"] as? Bool ?? false) || (info["Removable"] as? Bool ?? false),
            isEjectable: info["Ejectable"] as? Bool ?? false,
            isWritable: info["WritableMedia"] as? Bool ?? false,
            isVirtual: (info["VirtualOrPhysical"] as? String) == "Virtual" || bus == "Disk Image",
            scheme: entry["Content"] as? String ?? info["Content"] as? String ?? "",
            partitions: parts,
            isBootDisk: boots.contains(bsd),
            fingerprint: fingerprint)
    }

    static func listEntryFor(_ bsd: String) -> [String: Any]? {
        let all = ProcessRunner.plist("/usr/sbin/diskutil", ["list", "-plist", bsd])
        return (all?["AllDisksAndPartitions"] as? [[String: Any]])?.first
    }

    /// Whole physical disks backing the running system (the boot volume's APFS physical stores).
    public static func bootPhysicalDisks() -> Set<String> {
        var result = Set<String>()
        guard let root = ProcessRunner.plist("/usr/sbin/diskutil", ["info", "-plist", "/"]) else { return ["disk0"] }
        if let parent = root["ParentWholeDisk"] as? String {
            result.insert(parent)
            if let container = ProcessRunner.plist("/usr/sbin/diskutil", ["info", "-plist", parent]),
               let stores = container["APFSPhysicalStores"] as? [[String: Any]] {
                for s in stores {
                    if let store = s["APFSPhysicalStore"] as? String { result.insert(wholeDisk(of: store)) }
                }
            }
        }
        if result.isEmpty { result.insert("disk0") }
        return result
    }

    static func wholeDisk(of bsd: String) -> String {
        // disk0s2 → disk0
        if let r = bsd.range(of: #"^disk\d+"#, options: .regularExpression) { return String(bsd[r]) }
        return bsd
    }

    // MARK: Non-destructive actions

    public static func eject(_ disk: DiskDevice) -> ProcessResult {
        ProcessRunner.run("/usr/sbin/diskutil", ["eject", disk.bsdName], timeout: 60)
    }

    public static func unmount(_ disk: DiskDevice) -> ProcessResult {
        ProcessRunner.run("/usr/sbin/diskutil", ["unmountDisk", disk.bsdName], timeout: 60)
    }

    public static func mount(_ disk: DiskDevice) -> ProcessResult {
        ProcessRunner.run("/usr/sbin/diskutil", ["mountDisk", disk.bsdName], timeout: 60)
    }
}
