import SwiftUI
import UltaMacCore

/// Menu-bar icon: brand mark plus live CPU. The monitor only samples while this is shown.
struct MenuBarLabel: View {
    @Environment(MonitorModel.self) private var monitor
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
            Text("\(Int((monitor.cpu?.total ?? 0) * 100))%").monospacedDigit()
        }
        .task { monitor.start() }
    }
}

/// One-click cleanup limited to rules marked safe for automatic cleaning. Items always go
/// to the Trash, caches of running apps are skipped, and an inline confirmation is required.
@MainActor @Observable
final class QuickCleanModel {
    enum Phase: Equatable { case idle, scanning, ready, confirming, cleaning, done(String), nothingFound }
    private(set) var phase: Phase = .idle
    private(set) var items: [JunkItem] = []
    private(set) var ruleTitles: [String] = []

    var bytes: Int64 { items.reduce(0) { $0 + $1.size } }

    func scan() {
        phase = .scanning
        let rules = JunkRules.builtIn.filter(\.autoCleanAllowed)
        let scanner = JunkScanner(rules: rules, runningBundleIDs: runningBundleIDs())
        Task {
            let groups = await runInBackground { scanner.scan(cancel: CancellationFlag()) }
            items = groups.flatMap(\.items).filter(\.selectedByDefault)
            ruleTitles = groups.filter { $0.items.contains(where: \.selectedByDefault) }.map(\.rule.title)
            phase = items.isEmpty ? .nothingFound : .ready
            Sound.play(items.isEmpty ? .scanComplete : .found)
        }
    }

    func clean(remover: FileRemover, onDone: @escaping () -> Void) {
        phase = .cleaning
        let requests = items.map { RemovalRequest(url: $0.url, size: $0.size) }
        Task {
            let report = await runInBackground {
                remover.remove(requests, mode: .moveToTrash, purpose: .clean, context: "Menu Bar Quick Clean")
            }
            phase = .done(report.summary)
            items = []
            Sound.play(report.failures.isEmpty ? .success : .warning)
            onDone()
        }
    }

    func reset() { phase = .idle; items = [] }
}

struct MenuBarPanel: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var quick = QuickCleanModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            stats
            quickClean
            shortcuts
            Divider()
            HStack {
                Button { open(.dashboard) } label: { Label("Open UltaMac", systemImage: "macwindow") }
                Spacer()
                Button { open(.settings) } label: { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit UltaMac")
            }
            .buttonStyle(.borderless)
        }
        .padding(Theme.Space.l)
        .frame(width: 330)
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: "sparkles", tint: .brand, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("UltaMac").font(.headline)
                Text("Clean · Monitor · Optimise · Recover").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Pill(text: "Offline", tint: .secondary, symbol: "wifi.slash")
        }
    }

    private var stats: some View {
        Grid(horizontalSpacing: Theme.Space.s, verticalSpacing: Theme.Space.s) {
            GridRow {
                tile("CPU", "\(Int((monitor.cpu?.total ?? 0) * 100))%", "cpu", .performance) {
                    Sparkline(values: monitor.cpuTotals, maxValue: 1, tint: .performance)
                }
                tile("Memory", monitor.memory.map { ByteFormat.memory($0.used) } ?? "—", "memorychip",
                     monitor.memory?.pressure == .normal ? .apps : .warning) {
                    Sparkline(values: monitor.memoryTotals, maxValue: 1, tint: .apps)
                }
            }
            GridRow {
                tile("Disk free", monitor.disk.map { ByteFormat.string($0.available) } ?? "—", "internaldrive", .storage) {
                    SizeBar(fraction: monitor.disk?.usedFraction ?? 0, tint: .storage)
                }
                if let b = monitor.battery {
                    tile("Battery", "\(b.percent)%\(b.isCharging ? " ⚡︎" : "")", "battery.75percent", .success) {
                        SizeBar(fraction: Double(b.percent) / 100, tint: b.percent < 20 ? .danger : .success)
                    }
                } else {
                    tile("Network", monitor.network.map { ByteFormat.rate($0.bytesInPerSecond) } ?? "—", "network", .storage) {
                        Sparkline(values: monitor.networkHistory.filter { $0.series == "Download" }.map(\.value), tint: .storage)
                    }
                }
            }
        }
    }

    private func tile<V: View>(_ title: String, _ value: String, _ symbol: String, _ tint: Theme.Tint,
                               @ViewBuilder visual: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            visual().frame(height: 16)
        }
        .padding(Theme.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private var quickClean: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Label("Quick Clean", systemImage: "wand.and.stars").font(.callout.weight(.semibold))
                Spacer()
                RiskPill(risk: .safe)
            }
            switch quick.phase {
            case .idle:
                Text("Finds app caches, logs and Xcode build data that rebuild automatically.").font(.caption).foregroundStyle(.secondary)
                Button { quick.scan() } label: { Text("Scan for Safe Junk").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            case .scanning:
                HStack { ProgressView().controlSize(.small); Text("Scanning…").font(.callout).foregroundStyle(.secondary) }
            case .ready:
                Text("\(ByteFormat.string(quick.bytes)) in \(quick.items.count) items")
                    .font(.title3.bold().monospacedDigit())
                Text(quick.ruleTitles.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Button("Review in App") { state.junk.scan(); open(.cleaner) }
                    Spacer()
                    Button("Clean…") { quick.phaseConfirm() }.buttonStyle(.borderedProminent)
                }
            case .confirming:
                Text("Move \(quick.items.count) items (\(ByteFormat.string(quick.bytes))) to the Trash? You can restore them until you empty it.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { quick.reset() }
                    Spacer()
                    Button("Move to Trash") { quick.clean(remover: settings.remover) { settings.historyRevision += 1; monitor.refreshSlow() } }
                        .buttonStyle(.borderedProminent)
                }
            case .cleaning:
                HStack { ProgressView().controlSize(.small); Text("Moving to Trash…").font(.callout).foregroundStyle(.secondary) }
            case .done(let summary):
                Label(summary, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                Button("Done") { quick.reset() }
            case .nothingFound:
                Label("Nothing to clean right now.", systemImage: "checkmark.seal").font(.callout).foregroundStyle(.secondary)
                Button("OK") { quick.reset() }
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.Tint.clean.color.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private var shortcuts: some View {
        let items: [Destination] = [.dashboard, .storage, .uninstaller, .monitor, .maintenance, .usbToolkit]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(items) { d in
                Button { open(d) } label: {
                    VStack(spacing: 4) {
                        IconBadge(symbol: d.symbol, tint: d.tint, size: 26)
                        Text(d == .dashboard ? "Smart Scan" : d.title.replacingOccurrences(of: "App ", with: "").replacingOccurrences(of: " Analyser", with: ""))
                            .font(.caption2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverLift())
            }
        }
    }

    private func open(_ d: Destination) {
        state.destination = d
        openWindow(id: "main")
        NSApp.activate()
    }
}

extension QuickCleanModel {
    func phaseConfirm() { if phase == .ready { phase = .confirming } }
}
