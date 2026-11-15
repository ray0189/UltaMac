import Foundation
import Darwin

/// Something measurable that is slowing the Mac down, with a concrete fix.
/// Issues come only from live measurements against stated thresholds: there is no invented score.
public struct PerformanceIssue: Sendable, Identifiable, Hashable {
    public enum Severity: Int, Sendable, Comparable {
        case info = 0, warning = 1, critical = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public enum Fix: Sendable, Hashable {
        /// Quit a process you own (apps are asked to quit politely).
        case quit(pid: Int32, name: String)
        /// Run a speed-up task by id (see `MaintenanceTask.speedUp`).
        case task(String)
        /// Open a screen in the app ("cleaner", "startup", "storage"…).
        case open(String)
        case restart
    }

    public let id: String
    public let severity: Severity
    public let symbol: String
    public let title: String
    public let detail: String
    public let fix: Fix
    public let fixTitle: String
}

/// Tracks how long each process has stayed busy, to tell a runaway process from a short burst.
public struct RunawayTracker: Sendable {
    public struct Runaway: Sendable, Hashable {
        public let pid: Int32
        public let name: String
        public let cpuFraction: Double
        public let seconds: TimeInterval
        public init(pid: Int32, name: String, cpuFraction: Double, seconds: TimeInterval) {
            self.pid = pid; self.name = name; self.cpuFraction = cpuFraction; self.seconds = seconds
        }
    }

    /// One full core (1.0) or more, sustained for this long, counts as runaway.
    public var threshold: Double = 0.8
    public var minimumDuration: TimeInterval = 60
    private var busySince: [Int32: (start: Date, name: String, cpu: Double)] = [:]

    public init(threshold: Double = 0.8, minimumDuration: TimeInterval = 60) {
        self.threshold = threshold
        self.minimumDuration = minimumDuration
    }

    public mutating func update(_ samples: [ProcessSample], now: Date = Date()) -> [Runaway] {
        var next: [Int32: (start: Date, name: String, cpu: Double)] = [:]
        for s in AppUsage.group(samples.filter { !PerformanceAdvisor.isProtected($0) }) where s.cpuFraction >= threshold {
            let start = busySince[s.pid].map { $0.name == s.name ? $0.start : now } ?? now
            next[s.pid] = (start, s.name, s.cpuFraction)
        }
        busySince = next
        return next.compactMap { pid, v in
            let seconds = now.timeIntervalSince(v.start)
            return seconds >= minimumDuration ? Runaway(pid: pid, name: v.name, cpuFraction: v.cpu, seconds: seconds) : nil
        }
        .sorted { $0.cpuFraction > $1.cpuFraction }
    }
}

public enum PerformanceAdvisor {
    /// Processes UltaMac never suggests quitting: quitting them logs you out or breaks the desktop.
    static let protectedNames: Set<String> = ["loginwindow", "WindowServer", "launchd", "kernel_task", "UltaMac",
                                              "SystemUIServer", "ControlCenter", "Dock", "coreaudiod", "UserEventAgent"]

    public static func isProtected(_ p: ProcessSample) -> Bool {
        p.pid <= 1 || p.pid == getpid() || p.isSystem || protectedNames.contains(p.name) || protectedNames.contains(p.groupName)
    }

    public struct Input: Sendable {
        public var memory: MemoryStats?
        public var disk: DiskStatus?
        public var uptime: TimeInterval
        public var thermal: ProcessInfo.ThermalState
        public var processes: [ProcessSample]
        public var runaways: [RunawayTracker.Runaway]
        public var autoStartCount: Int?

        public init(memory: MemoryStats?, disk: DiskStatus?, uptime: TimeInterval, thermal: ProcessInfo.ThermalState,
                    processes: [ProcessSample], runaways: [RunawayTracker.Runaway], autoStartCount: Int? = nil) {
            self.memory = memory
            self.disk = disk
            self.uptime = uptime
            self.thermal = thermal
            self.processes = processes
            self.runaways = runaways
            self.autoStartCount = autoStartCount
        }
    }

    public static func issues(_ input: Input) -> [PerformanceIssue] {
        var issues: [PerformanceIssue] = []

        for r in input.runaways.prefix(3) {
            issues.append(PerformanceIssue(
                id: "runaway-\(r.pid)", severity: .critical, symbol: "flame",
                title: "\(r.name) is using \(Int(r.cpuFraction * 100))% CPU",
                detail: "It has kept at least one core busy for \(minutes(r.seconds)). That drains the battery, heats the Mac and slows everything else. Quitting it usually fixes it; unsaved work in it may be lost.",
                fix: .quit(pid: r.pid, name: r.name), fixTitle: "Quit \(r.name)"))
        }

        if let m = input.memory {
            let swapGB = Double(m.swapUsed) / 1_073_741_824
            let stressed = m.pressure == .warning || m.pressure == .critical || swapGB >= 2
            if stressed {
                let hogs = AppUsage.group(input.processes.filter { !isProtected($0) })
                    .filter { $0.memory >= 700_000_000 }
                    .sorted { $0.memory > $1.memory }
                    .prefix(3)
                let why = m.pressure == .warning || m.pressure == .critical
                    ? "Memory pressure is \(m.pressure.rawValue.lowercased()) and \(String(format: "%.1f", swapGB)) GB is swapped to disk"
                    : "\(String(format: "%.1f", swapGB)) GB of memory has been swapped to disk"
                for p in hogs {
                    issues.append(PerformanceIssue(
                        id: "memory-\(p.pid)", severity: m.pressure == .critical ? .critical : .warning, symbol: "memorychip",
                        title: "\(p.name) is using \(ByteFormat.memory(p.memory)) of memory" + (p.processCount > 1 ? " (\(p.processCount) processes)" : ""),
                        detail: "\(why), which makes apps stutter. Quitting big apps you aren't using frees memory immediately.",
                        fix: .quit(pid: p.pid, name: p.name), fixTitle: "Quit \(p.name)"))
                }
                if hogs.isEmpty {
                    issues.append(PerformanceIssue(
                        id: "memory-pressure", severity: .warning, symbol: "memorychip",
                        title: "Memory is under pressure",
                        detail: "\(String(format: "%.1f", swapGB)) GB is swapped to disk. Close apps or browser tabs you aren't using.",
                        fix: .open("processes"), fixTitle: "See Processes"))
                }
            }
        }

        if let d = input.disk, d.total > 0 {
            let freeFraction = Double(d.available) / Double(d.total)
            if freeFraction < 0.10 || d.available < 15_000_000_000 {
                issues.append(PerformanceIssue(
                    id: "disk-low", severity: freeFraction < 0.05 ? .critical : .warning, symbol: "internaldrive",
                    title: "Only \(ByteFormat.string(d.available)) free on \(d.name)",
                    detail: "macOS needs free space for swap, updates and caches. Below about 10% free, the whole Mac slows down. Clean junk or remove large files.",
                    fix: .open("cleaner"), fixTitle: "Clean Junk"))
            }
        }

        switch input.thermal {
        case .serious, .critical:
            issues.append(PerformanceIssue(
                id: "thermal", severity: input.thermal == .critical ? .critical : .warning, symbol: "thermometer.high",
                title: "Your Mac is running hot",
                detail: "macOS reports a \(input.thermal == .critical ? "critical" : "serious") thermal state and is slowing the processor to cool down. Quit busy apps and keep the vents clear.",
                fix: .open("processes"), fixTitle: "See Busy Processes"))
        default: break
        }

        if input.uptime > 14 * 86_400 {
            issues.append(PerformanceIssue(
                id: "uptime", severity: .info, symbol: "arrow.clockwise.circle",
                title: "Not restarted for \(Int(input.uptime / 86_400)) days",
                detail: "A restart clears leaked memory, finishes pending updates and resets stuck background services.",
                fix: .restart, fixTitle: "Restart…"))
        }

        if let n = input.autoStartCount, n > 12 {
            issues.append(PerformanceIssue(
                id: "autostart", severity: .info, symbol: "power",
                title: "\(n) items start automatically",
                detail: "Each background agent uses memory and CPU from login onwards. Remove the ones you don't need.",
                fix: .open("startup"), fixTitle: "Review Startup Items"))
        }

        return issues.sorted { $0.severity > $1.severity }
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        seconds < 120 ? "over a minute" : "\(Int(seconds / 60)) minutes"
    }
}

/// Ends a process you own. Apps should be asked to quit through AppKit first; this is for
/// background processes, and refuses protected ones.
public enum ProcessControl {
    public static func terminate(pid: Int32, name: String) -> Bool {
        guard pid > 1, pid != getpid(), !PerformanceAdvisor.protectedNames.contains(name) else { return false }
        return kill(pid, SIGTERM) == 0
    }
}

extension MaintenanceTask {
    /// Supported tasks that fix common slowdowns. Each explains what it really does.
    public static let speedUp: [MaintenanceTask] = [
        MaintenanceTask(id: "free-memory", title: "Free up memory", symbol: "memorychip",
                        purpose: "Empties the disk cache macOS keeps in memory (Apple's `purge`).",
                        effect: "Gives apps room straight away when memory pressure is high. macOS refills the cache over time, so this is a short-term fix; quitting heavy apps lasts longer.",
                        risk: "Low. The Mac may pause for a few seconds. Requires your administrator password.",
                        kind: .adminCommand("/usr/sbin/purge"), estimatedDuration: "~10 s"),
        MaintenanceTask(id: "rebuild-launchservices", title: "Rebuild app database", symbol: "square.stack.3d.up",
                        purpose: "Rebuilds the Launch Services database that maps files to apps.",
                        effect: "Fixes duplicate or missing apps in “Open With”, wrong default apps and slow right-click menus.",
                        risk: "Low. Default-app choices are kept. The first right-click afterwards may be slow.",
                        kind: .command("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                                       ["-gc", "-r", "-f", "-all", "local,system,user"]),
                        estimatedDuration: "~30 s"),
        MaintenanceTask(id: "relaunch-finder", title: "Relaunch Finder and Dock", symbol: "dock.rectangle",
                        purpose: "Restarts Finder and the Dock.",
                        effect: "Fixes a frozen Finder, stuck file copies display, missing Dock icons or a slow Desktop.",
                        risk: "Low. Finder windows close and reopen. Copies in progress in Finder are cancelled.",
                        kind: .command("/usr/bin/killall", ["Finder", "Dock"]), estimatedDuration: "instant"),
        MaintenanceTask(id: "font-cache", title: "Reset font caches", symbol: "textformat",
                        purpose: "Removes your account's font caches (Apple's `atsutil`).",
                        effect: "Fixes garbled text, missing fonts and apps that hang while loading fonts. Takes effect after you log out and in.",
                        risk: "Low. Caches rebuild automatically; the first launch of apps afterwards is slower.",
                        kind: .command("/usr/bin/atsutil", ["databases", "-removeUser"]), estimatedDuration: "instant"),
        MaintenanceTask(id: "reindex-spotlight", title: "Rebuild Spotlight index", symbol: "magnifyingglass",
                        purpose: "Erases and rebuilds the Spotlight index of your startup disk.",
                        effect: "Fixes Spotlight search that misses files, or `mds_stores` using lots of CPU for days.",
                        risk: "Medium. Spotlight results are incomplete and the Mac is busier for a few hours while it re-indexes. Requires your administrator password.",
                        kind: .adminCommand("/usr/bin/mdutil -E /"), estimatedDuration: "hours (in the background)"),
        MaintenanceTask(id: "flush-dns", title: "Flush DNS cache", symbol: "arrow.triangle.2.circlepath",
                        purpose: "Clears cached DNS answers.",
                        effect: "Fixes sites that won't load after a network or DNS change.",
                        risk: "Low. Requires your administrator password.",
                        kind: .adminCommand("dscacheutil -flushcache; killall -HUP mDNSResponder"), estimatedDuration: "instant"),
    ]
}
