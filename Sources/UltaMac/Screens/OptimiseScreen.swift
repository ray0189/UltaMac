import SwiftUI
import AppKit
import UltaMacCore

/// Carries out a PerformanceIssue's fix. Quitting always goes through a confirmation first.
@MainActor
enum PerformanceFixer {
    static func quit(pid: Int32, name: String) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.terminate()   // the app can ask to save documents
        }
        return ProcessControl.terminate(pid: pid, name: name)
    }

    /// Shows macOS's own restart dialog; nothing restarts without the user's click there.
    static func restart() {
        Task.detached {
            _ = ProcessRunner.run("/usr/bin/osascript", ["-e", "tell application \"loginwindow\" to «event aevtrrst»"], timeout: 30)
        }
    }

    static func destination(_ name: String) -> Destination? {
        switch name {
        case "cleaner": .cleaner
        case "startup": .startup
        case "processes": .processes
        case "storage": .storage
        default: nil
        }
    }
}

struct OptimiseScreen: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(AppState.self) private var state
    @State private var expanded = Set<String>()
    @State private var pendingQuit: (pid: Int32, name: String)?

    var body: some View {
        Page(destination: .optimise, subtitle: "Finds what's slowing your Mac right now, and fixes it with your OK.") {
            Button { monitor.refreshSlow(); monitor.refreshIssues() } label: { Label("Recheck", systemImage: "arrow.clockwise") }
        } content: {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                statusCard
                if !monitor.issues.isEmpty {
                    SectionTitle("Needs attention")
                    ForEach(monitor.issues) { issue in issueRow(issue) }
                }
                SectionTitle("Heaviest right now")
                heaviest
                SectionTitle("Speed-up tools")
                ForEach(MaintenanceTask.speedUp) { task in taskCard(task) }
            }
        }
        .onAppear { monitor.start(processes: true) }
        .onDisappear { monitor.stop(processes: true) }
        .alert("Quit \(pendingQuit?.name ?? "")?", isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } })) {
            Button("Quit", role: .destructive) {
                if let p = pendingQuit {
                    let ok = PerformanceFixer.quit(pid: p.pid, name: p.name)
                    Sound.play(ok ? .success : .warning)
                }
                pendingQuit = nil
            }
            Button("Cancel", role: .cancel) { pendingQuit = nil }
        } message: {
            Text("Apps are asked to quit normally and may ask you to save. Background processes are stopped; unsaved work in them is lost.")
        }
    }

    // MARK: Status

    private var statusCard: some View {
        let critical = monitor.issues.filter { $0.severity == .critical }.count
        let warnings = monitor.issues.filter { $0.severity == .warning }.count
        let tint: Theme.Tint = critical > 0 ? .danger : warnings > 0 ? .warning : .success
        let title = critical + warnings == 0 ? "Your Mac is running smoothly"
            : "\(critical + warnings) thing\(critical + warnings == 1 ? " is" : "s are") slowing your Mac"
        return Card {
            HStack(spacing: Theme.Space.l) {
                IconBadge(symbol: critical + warnings == 0 ? "checkmark.seal.fill" : "gauge.with.dots.needle.67percent", tint: tint, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold())
                    Text("Measured live: CPU \(Int((monitor.cpu?.total ?? 0) * 100))% · memory pressure \(monitor.memory?.pressure.rawValue.lowercased() ?? "—") · \(monitor.disk.map { ByteFormat.string($0.available) } ?? "—") free · up \(uptime)")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Text("UltaMac keeps watching while it's in the menu bar and flags runaway apps.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    private var uptime: String {
        let days = Int(monitor.system.uptime / 86_400)
        let hours = Int(monitor.system.uptime.truncatingRemainder(dividingBy: 86_400) / 3600)
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
    }

    private func issueRow(_ issue: PerformanceIssue) -> some View {
        let tint: Theme.Tint = issue.severity == .critical ? .danger : issue.severity == .warning ? .warning : .storage
        return HStack(alignment: .top, spacing: Theme.Space.m) {
            IconBadge(symbol: issue.symbol, tint: tint, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).font(.body.weight(.semibold))
                Text(issue.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(issue.fixTitle) { perform(issue.fix) }.buttonStyle(.borderedProminent)
        }
        .cardSurface()
    }

    private func perform(_ fix: PerformanceIssue.Fix) {
        switch fix {
        case .quit(let pid, let name): pendingQuit = (pid, name)
        case .task(let id): if let t = MaintenanceTask.speedUp.first(where: { $0.id == id }) { state.maintenance.run(t) }
        case .open(let name): if let d = PerformanceFixer.destination(name) { state.go(d) }
        case .restart: PerformanceFixer.restart()
        }
    }

    // MARK: Heaviest

    private var heaviest: some View {
        let apps = AppUsage.group(monitor.processes.filter { !PerformanceAdvisor.isProtected($0) })
        let byCPU = Array(apps.sorted { $0.cpuFraction > $1.cpuFraction }.prefix(5))
        let byMemory = Array(apps.sorted { $0.memory > $1.memory }.prefix(5))
        return HStack(alignment: .top, spacing: Theme.Space.m) {
            processList("CPU · apps incl. helpers", symbol: "cpu", rows: byCPU) { String(format: "%.0f%%", $0.cpuFraction * 100) }
            processList("Memory · apps incl. helpers", symbol: "memorychip", rows: byMemory) { ByteFormat.memory($0.memory) }
        }
    }

    private func processList(_ title: String, symbol: String, rows: [AppUsage],
                             value: @escaping (AppUsage) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            if rows.isEmpty { Text("Measuring…").font(.callout).foregroundStyle(.tertiary) }
            ForEach(rows) { p in
                HStack(spacing: 8) {
                    if let icon = NSRunningApplication(processIdentifier: p.pid)?.icon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "gearshape.2").frame(width: 18).foregroundStyle(.secondary)
                    }
                    Text(p.name).lineLimit(1)
                    if p.processCount > 1 { Text("×\(p.processCount)").font(.caption).foregroundStyle(.tertiary) }
                    Spacer()
                    Text(value(p)).monospacedDigit().foregroundStyle(.secondary)
                    Button("Quit") { pendingQuit = (p.pid, p.name) }.controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: Tools

    private func taskCard(_ task: MaintenanceTask) -> some View {
        let run = state.maintenance.runs[task.id]
        let open = expanded.contains(task.id)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                IconBadge(symbol: task.symbol, tint: .performance, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(task.title).font(.body.weight(.semibold))
                        if task.needsAdmin { Pill(text: "Admin password", tint: .orange, symbol: "lock") }
                        Text(task.estimatedDuration).font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(task.effect).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text("Risk: \(task.risk)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if run?.running == true {
                    ProgressView().controlSize(.small)
                } else {
                    Button(run == nil ? "Run" : "Run Again") { state.maintenance.run(task) }
                        .buttonStyle(.bordered)
                }
            }
            if let result = run?.result {
                HStack {
                    Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.succeeded ? .green : .orange)
                    Text(result.summary).font(.callout).lineLimit(2)
                    Spacer()
                    if !result.log.isEmpty {
                        Button(open ? "Hide output" : "Show output") { animate { if open { expanded.remove(task.id) } else { expanded.insert(task.id) } } }
                            .buttonStyle(.link)
                    }
                }
            }
            if open, let log = run?.result?.log {
                Text(log.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption.monospaced()).textSelection(.enabled).lineLimit(20)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.s)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }
        }
        .cardSurface()
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.headline).padding(.top, Theme.Space.xs) }
}
