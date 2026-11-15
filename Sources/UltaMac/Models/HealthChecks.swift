import SwiftUI
import UltaMacCore

/// Transparent health checks. No combined "score" is computed: each check reports its
/// measured value against a documented threshold (see docs/Architecture.md › Health checks).
struct HealthCheck: Identifiable {
    enum Status: Int, Comparable {
        case ok = 0, info = 1, attention = 2, critical = 3
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }

        var symbol: String {
            switch self {
            case .ok: "checkmark.circle.fill"
            case .info: "info.circle.fill"
            case .attention: "exclamationmark.triangle.fill"
            case .critical: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .ok: .green
            case .info: .blue
            case .attention: .orange
            case .critical: .red
            }
        }
    }

    var id: String { title }
    let title: String
    let detail: String
    let status: Status
    var action: (title: String, destination: Destination)? = nil

    @MainActor
    static func evaluate(monitor: MonitorModel, junk: JunkModel, files: LargeOldModel,
                         apps: UninstallerModel, unusedDays: Int) -> [HealthCheck] {
        var checks: [HealthCheck] = []

        if let d = monitor.disk {
            let freeRatio = Double(d.available) / Double(max(d.total, 1))
            let status: Status = freeRatio < 0.05 ? .critical : freeRatio < 0.15 ? .attention : .ok
            checks.append(HealthCheck(
                title: "Disk space",
                detail: "\(ByteFormat.string(d.available)) available (\(Int(freeRatio * 100))%). Below 15% free, macOS has less room for updates and swap.",
                status: status, action: status == .ok ? nil : ("Analyse storage", .storage)))
        }
        if let m = monitor.memory {
            let status: Status = switch m.pressure {
            case .normal: .ok
            case .warning: .attention
            case .critical: .critical
            case .unknown: .info
            }
            checks.append(HealthCheck(title: "Memory pressure", detail: "\(m.pressure.rawValue). \(ByteFormat.memory(m.used)) of \(ByteFormat.memory(m.total)) in use.",
                                      status: status, action: status == .ok ? nil : ("Open Process Inspector", .processes)))
            let swapHeavy = m.swapUsed > m.total / 2
            checks.append(HealthCheck(title: "Swap", detail: "\(ByteFormat.memory(m.swapUsed)) swapped to disk. Above half of RAM suggests memory is regularly short.",
                                      status: swapHeavy ? .attention : .ok))
        }
        if let b = monitor.battery {
            var status: Status = .ok
            var detail = b.health.map { "Condition: \($0)" } ?? "\(b.cycleCount ?? 0) cycles"
            if let h = b.healthPercent {
                detail += " · \(h)% of design capacity"
                if h < 80 { status = .attention }
            }
            if let health = b.health, health != "Good" { status = .attention }
            checks.append(HealthCheck(title: "Battery", detail: detail, status: status, action: ("Battery details", .battery)))
        }
        let thermal = monitor.system.thermalState
        checks.append(HealthCheck(title: "Thermal state", detail: thermal.title,
                                  status: thermal == .serious ? .attention : thermal == .critical ? .critical : .ok))
        if monitor.fullDiskAccess == .notGranted {
            checks.append(HealthCheck(title: "Full Disk Access", detail: "Off. Some caches and the Trash can't be scanned.",
                                      status: .info, action: ("Set up", .permissions)))
        }
        if junk.hasScanned {
            let selected = junk.selectedSize
            checks.append(HealthCheck(title: "Junk", detail: "\(ByteFormat.string(junk.totalSize)) found, \(ByteFormat.string(selected)) recommended.",
                                      status: selected > 1_000_000_000 ? .attention : .ok, action: ("Review", .cleaner)))
        }
        if files.hasScanned, !files.entries.isEmpty {
            checks.append(HealthCheck(title: "Large & old files", detail: "\(files.entries.count) files, \(ByteFormat.string(files.totalSize)). Your own files, so review them.",
                                      status: .info, action: ("Review", .largeOld)))
        }
        if apps.hasLoaded {
            let intel = apps.filtered(.intel).count
            if intel > 0 {
                checks.append(HealthCheck(title: "Intel-only apps", detail: "\(intel) app\(intel == 1 ? "" : "s") run through Rosetta 2 on this Mac, which uses more energy.",
                                          status: .info, action: ("Show apps", .uninstaller)))
            }
            let unused = apps.filtered(.unused).count
            if unused > 0 {
                checks.append(HealthCheck(title: "Unused apps", detail: "\(unused) app\(unused == 1 ? "" : "s") not opened in \(unusedDays)+ days (per Spotlight).",
                                          status: .info, action: ("Show apps", .uninstaller)))
            }
        }
        return checks.sorted { $0.status > $1.status }
    }
}
