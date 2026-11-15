import Foundation
import Testing
@testable import UltaMacCore

@Suite("Performance advisor")
struct OptimiseTests {
    func p(_ pid: Int32, _ name: String, cpu: Double = 0, mem: UInt64 = 0) -> ProcessSample {
        ProcessSample(pid: pid, name: name, cpuFraction: cpu, memory: mem)
    }

    @Test func runawayNeedsSustainedLoad() {
        var tracker = RunawayTracker(threshold: 0.8, minimumDuration: 60)
        let t0 = Date()
        #expect(tracker.update([p(500, "Busy", cpu: 1.2)], now: t0).isEmpty)
        #expect(tracker.update([p(500, "Busy", cpu: 1.1)], now: t0.addingTimeInterval(30)).isEmpty)
        let found = tracker.update([p(500, "Busy", cpu: 1.0), p(501, "Burst", cpu: 2.0)], now: t0.addingTimeInterval(65))
        #expect(found.map(\.name) == ["Busy"])
        // A dip below the threshold resets the clock.
        _ = tracker.update([p(500, "Busy", cpu: 0.1)], now: t0.addingTimeInterval(70))
        #expect(tracker.update([p(500, "Busy", cpu: 1.0)], now: t0.addingTimeInterval(80)).isEmpty)
    }

    @Test func protectedProcessesAreNeverSuggested() {
        var tracker = RunawayTracker(threshold: 0.5, minimumDuration: 0)
        let found = tracker.update([p(400, "WindowServer", cpu: 3), p(401, "loginwindow", cpu: 3), p(getpid(), "x", cpu: 3)])
        #expect(found.isEmpty)
        #expect(!ProcessControl.terminate(pid: 401, name: "loginwindow"))
        #expect(!ProcessControl.terminate(pid: getpid(), name: "UltaMacCoreTests"))
    }

    func memory(_ pressure: MemoryStats.Pressure, swap: UInt64 = 0) -> MemoryStats {
        MemoryStats(total: 8 << 30, app: 4 << 30, wired: 1 << 30, compressed: 1 << 30, cachedFiles: 1 << 30,
                    free: 0, swapUsed: swap, swapTotal: swap, pressure: pressure)
    }

    @Test func memoryHogsOnlyFlaggedUnderPressure() {
        let procs = [p(10, "Browser", mem: 3_000_000_000), p(11, "Editor", mem: 900_000_000), p(12, "Tiny", mem: 50_000_000)]
        let calm = PerformanceAdvisor.issues(.init(memory: memory(.normal), disk: nil, uptime: 3600, thermal: .nominal,
                                                   processes: procs, runaways: []))
        #expect(calm.isEmpty)
        let stressed = PerformanceAdvisor.issues(.init(memory: memory(.warning, swap: 3 << 30), disk: nil, uptime: 3600,
                                                       thermal: .nominal, processes: procs, runaways: []))
        #expect(stressed.map(\.id) == ["memory-10", "memory-11"])
        #expect(stressed.first?.fix == .quit(pid: 10, name: "Browser"))
    }

    @Test func lowDiskUptimeAndOrdering() {
        let disk = DiskStatus(name: "Macintosh HD", total: 250_000_000_000, available: 8_000_000_000, availableStrict: 8_000_000_000)
        let runaway = RunawayTracker.Runaway(pid: 77, name: "Spinner", cpuFraction: 1.0, seconds: 300)
        let issues = PerformanceAdvisor.issues(.init(memory: memory(.normal), disk: disk, uptime: 20 * 86_400, thermal: .nominal,
                                                     processes: [], runaways: [runaway], autoStartCount: 20))
        #expect(issues.map(\.id) == ["runaway-77", "disk-low", "uptime", "autostart"])
        #expect(issues[1].severity == .critical)   // 3% free
        #expect(issues[0].title.contains("100%"))
    }

    @Test func speedUpTasksUseRealTools() {
        for task in MaintenanceTask.speedUp {
            if case .command(let exe, _) = task.kind {
                #expect(FileManager.default.isExecutableFile(atPath: exe), "\(task.id): \(exe)")
            }
        }
    }
}

@Suite("App grouping")
struct AppGroupingTests {
    @Test func helpersCountTowardsTheirApp() {
        let main = ProcessSampler.identity(path: "/Applications/Claude.app/Contents/MacOS/Claude")
        let helper = ProcessSampler.identity(path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)")
        let daemon = ProcessSampler.identity(path: "/usr/libexec/duetexpertd")
        #expect(main.name == "Claude" && main.app == "Claude")
        #expect(helper.name == "Claude Helper (Renderer)" && helper.app == "Claude")
        #expect(daemon.isSystem && daemon.app == nil)
        let samples = [
            ProcessSample(pid: 10, name: main.name, cpuFraction: 0.1, memory: 400, app: main.app),
            ProcessSample(pid: 11, name: helper.name, cpuFraction: 0.5, memory: 700, app: helper.app),
            ProcessSample(pid: 12, name: "duetexpertd", cpuFraction: 0.7, memory: 10, isSystem: true),
        ]
        let groups = AppUsage.group(samples)
        #expect(groups.count == 1)
        #expect(groups[0].pid == 10 && groups[0].memory == 1100 && groups[0].processCount == 2)
    }
}

extension AppGroupingTests {
    @Test func simulatorProcessesGroupAsSimulator() {
        let sim = ProcessSampler.identity(path: "/private/var/run/com.apple.security.cryptexd/mnt/x/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/backboardd")
        let app = ProcessSampler.identity(path: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator")
        #expect(sim.app == "Simulator" && !sim.isSystem)
        #expect(app.app == "Simulator" && app.name == "Simulator")
    }
}
