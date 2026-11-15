import Foundation
import IOKit
import IOKit.ps

public struct BatteryStatus: Sendable {
    public let percent: Int
    public let isCharging: Bool
    public let onACPower: Bool
    public let minutesRemaining: Int?
    public let health: String?
    public let cycleCount: Int?
    /// Detailed controller values from the `AppleSmartBattery` IORegistry entry. These keys are
    /// not formally documented, so each is optional and shown as "reported by the battery".
    public var details: BatteryDetails? = nil

    /// Health = full-charge capacity ÷ design capacity (the usual industry definition).
    public var healthPercent: Int? {
        guard let d = details, let full = d.fullChargeCapacity, let design = d.designCapacity, design > 0 else { return nil }
        return Int((Double(full) / Double(design) * 100).rounded())
    }

    /// nil on Macs without a battery.
    public static func current() -> BatteryStatus? {
        guard var status = basic() else { return nil }
        status.details = BatteryDetails.read()
        return status
    }

    static func basic() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let minutes = (desc[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return BatteryStatus(
                percent: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                onACPower: (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                minutesRemaining: minutes,
                health: desc[kIOPSBatteryHealthKey] as? String,
                cycleCount: BatteryStatus.cycleCount())
        }
        return nil
    }

    /// Reads the public IORegistry property of the battery service.
    static func cycleCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Int
    }
}

public struct BatteryDetails: Sendable {
    public let designCapacity: Int?       // mAh
    public let fullChargeCapacity: Int?   // mAh (AppleRawMaxCapacity)
    public let currentCapacity: Int?      // mAh (AppleRawCurrentCapacity)
    public let voltage: Double?           // V
    public let amperage: Int?             // mA, negative while discharging
    public let temperature: Double?       // °C, as reported by the battery controller
    public let adapterWatts: Int?
    public let adapterName: String?
    public let serial: String?

    public var powerWatts: Double? {
        guard let v = voltage, let a = amperage else { return nil }
        return v * Double(a) / 1000
    }

    static func read() -> BatteryDetails? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let top = props?.takeRetainedValue() as? [String: Any] else { return nil }
        // Apple Silicon Macs nest most capacity values in "BatteryData"; Intel Macs keep them top-level.
        var dict = (top["BatteryData"] as? [String: Any]) ?? [:]
        dict.merge(top) { nested, _ in nested }
        func int(_ k: String) -> Int? { (dict[k] as? NSNumber)?.intValue }
        var adapterWatts: Int?, adapterName: String?
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            adapterWatts = (adapter[kIOPSPowerAdapterWattsKey] as? NSNumber)?.intValue
            adapterName = adapter["Name"] as? String
        }
        return BatteryDetails(
            designCapacity: int("DesignCapacity"),
            fullChargeCapacity: int("AppleRawMaxCapacity") ?? int("FullChargeCapacity") ?? int("NominalChargeCapacity"),
            currentCapacity: int("AppleRawCurrentCapacity"),
            voltage: int("Voltage").map { Double($0) / 1000 },
            amperage: (dict["InstantAmperage"] as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
                ?? (dict["Amperage"] as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) },
            temperature: int("Temperature").map { Double($0) / 100 },
            adapterWatts: adapterWatts,
            adapterName: adapterName,
            serial: dict["Serial"] as? String)
    }
}

public struct DiskStatus: Sendable {
    public let name: String
    public let total: Int64
    public let available: Int64       // includes purgeable space macOS can free
    public let availableStrict: Int64 // free right now

    public var used: Int64 { max(0, total - available) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func current(for url: URL = URL(fileURLWithPath: "/")) -> DiskStatus? {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity else { return nil }
        let strict = Int64(v.volumeAvailableCapacity ?? 0)
        return DiskStatus(name: v.volumeLocalizedName ?? "Macintosh HD",
                          total: Int64(total),
                          available: v.volumeAvailableCapacityForImportantUsage ?? strict,
                          availableStrict: strict)
    }
}
