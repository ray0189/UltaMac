import SwiftUI
import UltaMacCore

struct ChartPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
    let series: String
}

/// Shared live system state. Sampling runs only while a view (or the menu-bar monitor)
/// is subscribed; per-process sampling only while the process views are visible.
@MainActor @Observable
final class MonitorModel {
    private(set) var cpu: CPULoad?
    private(set) var memory: MemoryStats?
    private(set) var network: NetworkRate?
    private(set) var disk: DiskStatus?
    private(set) var battery: BatteryStatus?
    private(set) var system = SystemInfo.current()
    private(set) var processes: [ProcessSample] = []
    private(set) var cpuHistory: [ChartPoint] = []
    private(set) var networkHistory: [ChartPoint] = []
    private(set) var cpuTotals: [Double] = []
    private(set) var memoryTotals: [Double] = []
    private(set) var fullDiskAccess: FullDiskAccess = .unknown
    private(set) var lastSample = Date()

    private let cpuSampler = CPUSampler()
    private let netSampler = NetworkSampler()
    private let procSampler = ProcessSampler()
    private var timer: Task<Void, Never>?
    private var subscribers = 0
    private var processSubscribers = 0
    private let historyLength = 90

    init() {
        refreshSlow()
        Task { await self.tick() }
    }

    func start(processes: Bool = false) {
        subscribers += 1
        if processes { processSubscribers += 1 }
        guard timer == nil else { return }
        timer = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                await self?.tick()
                if n % 15 == 0 { self?.refreshSlow() }
                n += 1
                let interval = UserDefaults.standard.object(forKey: "samplingInterval") as? Double ?? 2
                try? await Task.sleep(for: .seconds(max(1, interval)))
            }
        }
    }

    func stop(processes: Bool = false) {
        subscribers = max(0, subscribers - 1)
        if processes { processSubscribers = max(0, processSubscribers - 1) }
        if subscribers == 0 {
            timer?.cancel()
            timer = nil
        }
    }

    func refreshSlow() {
        disk = DiskStatus.current()
        battery = BatteryStatus.current()
        system = SystemInfo.current()
        fullDiskAccess = FullDiskAccess.status()
    }

    private func tick() async {
        let cpuSampler = cpuSampler, netSampler = netSampler, procSampler = procSampler
        let wantProcesses = processSubscribers > 0
        let (c, m, n, p) = await runInBackground {
            (cpuSampler.sample(), MemoryStats.current(), netSampler.sample(), wantProcesses ? procSampler.sample() : nil)
        }
        let now = Date()
        lastSample = now
        if let c {
            cpu = c
            cpuHistory.append(ChartPoint(time: now, value: c.user * 100, series: "User"))
            cpuHistory.append(ChartPoint(time: now, value: c.system * 100, series: "System"))
            if cpuHistory.count > historyLength * 2 { cpuHistory.removeFirst(cpuHistory.count - historyLength * 2) }
            cpuTotals = Array((cpuTotals + [c.total]).suffix(historyLength))
        }
        if let m {
            memory = m
            memoryTotals = Array((memoryTotals + [m.usedFraction]).suffix(historyLength))
        }
        if let n {
            network = n
            networkHistory.append(ChartPoint(time: now, value: n.bytesInPerSecond, series: "Download"))
            networkHistory.append(ChartPoint(time: now, value: n.bytesOutPerSecond, series: "Upload"))
            if networkHistory.count > historyLength * 2 { networkHistory.removeFirst(networkHistory.count - historyLength * 2) }
        }
        if let p { processes = p }
    }
}
