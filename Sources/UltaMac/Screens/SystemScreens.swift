import SwiftUI
import Charts
import UltaMacCore

// MARK: - Live Monitor

struct MonitorScreen: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Page(destination: .monitor, subtitle: "Sampling every \(Int(settings.samplingInterval)) s · real values from Mach and BSD APIs") {
            VStack(spacing: Theme.Space.l) {
                HStack(spacing: Theme.Space.l) {
                    cpuCard
                    coresCard.frame(width: 300)
                }
                .frame(height: 250)
                memoryCard
                networkCard.frame(height: 230)
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private var cpuCard: some View {
        Card(title: "CPU", symbol: "cpu") {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xl) {
                Metric(value: "\(Int((monitor.cpu?.total ?? 0) * 100))%", caption: "total")
                Metric(value: "\(Int((monitor.cpu?.user ?? 0) * 100))%", caption: "user", size: 18)
                Metric(value: "\(Int((monitor.cpu?.system ?? 0) * 100))%", caption: "system", size: 18)
                let l = monitor.system.loadAverage
                Metric(value: String(format: "%.2f", l.0), caption: String(format: "load · %.2f · %.2f", l.1, l.2), size: 18)
            }
            Chart(monitor.cpuHistory) { p in
                AreaMark(x: .value("Time", p.time), y: .value("%", p.value), stacking: .standard)
                    .foregroundStyle(by: .value("Type", p.series))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartForegroundStyleScale(["User": Theme.Tint.performance.colors[0], "System": Theme.Tint.performance.colors[1]])
            .chartLegend(position: .top, alignment: .trailing)
        }
    }

    private var coresCard: some View {
        Card(title: "Cores", symbol: "square.grid.2x2") {
            let cores = monitor.cpu?.perCore ?? []
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07))
                            RoundedRectangle(cornerRadius: 5).fill(Theme.gradient(.performance))
                                .frame(height: max(3, 70 * v))
                        }
                        .frame(height: 70)
                        .animation(Motion.standard, value: v)
                        Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Text(SystemInfo.coreLayoutDescription).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var memoryCard: some View {
        Card(title: "Memory", symbol: "memorychip") {
            if let m = monitor.memory {
                let parts: [(String, UInt64, Color)] = [
                    ("App", m.app, Theme.Tint.storage.colors[0]), ("Wired", m.wired, Theme.Tint.warning.colors[1]),
                    ("Compressed", m.compressed, Theme.Tint.apps.colors[0]), ("Cached files", m.cachedFiles, .gray.opacity(0.6)),
                ]
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xl) {
                    Metric(value: ByteFormat.memory(m.used), caption: "used of \(ByteFormat.memory(m.total))")
                    Metric(value: m.pressure.rawValue, caption: "memory pressure", tint: m.pressure == .normal ? .green : .orange, size: 18)
                    Metric(value: ByteFormat.memory(m.swapUsed), caption: "swap used", size: 18)
                    Spacer()
                }
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(parts, id: \.0) { part in
                            RoundedRectangle(cornerRadius: 4).fill(part.2)
                                .frame(width: max(0, geo.size.width * CGFloat(Double(part.1) / Double(max(m.total, 1))) - 2))
                        }
                        Spacer(minLength: 0)
                    }
                    .animation(Motion.standard, value: m.used)
                }
                .frame(height: 16)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                HStack(spacing: Theme.Space.l) {
                    ForEach(parts, id: \.0) { part in
                        HStack(spacing: 5) {
                            Circle().fill(part.2).frame(width: 8, height: 8)
                            Text("\(part.0) \(ByteFormat.memory(part.1))").monospacedDigit()
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    private var networkCard: some View {
        Card(title: "Network", symbol: "network") {
            HStack(spacing: Theme.Space.xl) {
                Metric(value: monitor.network.map { ByteFormat.rate($0.bytesInPerSecond) } ?? "—", caption: "download", size: 18)
                Metric(value: monitor.network.map { ByteFormat.rate($0.bytesOutPerSecond) } ?? "—", caption: "upload", size: 18)
                Spacer()
            }
            Chart(monitor.networkHistory) { p in
                LineMark(x: .value("Time", p.time), y: .value("Bytes/s", p.value))
                    .foregroundStyle(by: .value("Direction", p.series))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartForegroundStyleScale(["Download": Theme.Tint.storage.colors[0], "Upload": Theme.Tint.clean.colors[0]])
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text(ByteFormat.rate(v.as(Double.self) ?? 0)) } } }
        }
    }
}

extension SystemInfo {
    /// Performance/efficiency core split from `hw.perflevel*` sysctls (Apple Silicon).
    static var coreLayoutDescription: String {
        func value(_ name: String) -> Int? {
            var v: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        }
        if let p = value("hw.perflevel0.logicalcpu"), let e = value("hw.perflevel1.logicalcpu") {
            return "\(p) performance + \(e) efficiency cores"
        }
        return "\(ProcessInfo.processInfo.activeProcessorCount) cores"
    }
}

// MARK: - Process Inspector

struct ProcessScreen: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @State private var sort = [KeyPathComparator(\ProcessSample.cpuFraction, order: .reverse)]
    @State private var search = ""

    var body: some View {
        let rows = monitor.processes
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted(using: sort)
        Page(destination: .processes, subtitle: "\(monitor.processes.count) processes you own · CPU 100% = one full core", scrolls: false) {
            TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
        } content: {
            Table(rows, sortOrder: $sort) {
                TableColumn("Process", value: \.name) { p in
                    HStack(spacing: 8) {
                        if let app = NSRunningApplication(processIdentifier: p.pid), let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "terminal").frame(width: 16).foregroundStyle(.secondary)
                        }
                        Text(p.name).lineLimit(1)
                    }
                }
                TableColumn("CPU", value: \.cpuFraction) { p in
                    HStack {
                        SizeBar(fraction: min(1, p.cpuFraction), tint: .performance).frame(width: 50)
                        Text(String(format: "%.1f%%", p.cpuFraction * 100)).monospacedDigit()
                    }
                }.width(120)
                TableColumn("Memory", value: \.memory) { p in Text(ByteFormat.memory(p.memory)).monospacedDigit() }.width(90)
                TableColumn("PID", value: \.pid) { p in Text(verbatim: String(p.pid)).monospacedDigit().foregroundStyle(.secondary) }.width(60)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .contextMenu(forSelectionType: Int32.self) { pids in
                if let pid = pids.first, let app = NSRunningApplication(processIdentifier: pid) {
                    Button("Quit \(app.localizedName ?? "App")") { app.terminate() }
                }
            }
        }
        .onAppear { monitor.start(processes: true) }
        .onDisappear { monitor.stop(processes: true) }
    }
}

// MARK: - Battery

struct BatteryScreen: View {
    @Environment(MonitorModel.self) private var monitor

    var body: some View {
        Page(destination: .battery) {
            if let b = monitor.battery {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    HStack(spacing: Theme.Space.l) {
                        Card {
                            HStack(spacing: Theme.Space.xl) {
                                ZStack {
                                    Ring(fraction: Double(b.percent) / 100, tint: b.percent < 20 ? .danger : .success, lineWidth: 14)
                                    VStack(spacing: 0) {
                                        Text("\(b.percent)%").font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                                        Image(systemName: b.isCharging ? "bolt.fill" : b.onACPower ? "powerplug.fill" : "battery.75percent")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 150, height: 150)
                                VStack(alignment: .leading, spacing: Theme.Space.s) {
                                    Text(b.isCharging ? "Charging" : b.onACPower ? "On power adapter, not charging" : "On battery").font(.title3.bold())
                                    if let m = b.minutesRemaining, !b.onACPower { Text("About \(m / 60) h \(m % 60) min remaining").foregroundStyle(.secondary) }
                                    if let w = b.details?.powerWatts { Text(String(format: "%@ %.1f W", w >= 0 ? "Charging at" : "Drawing", abs(w))).foregroundStyle(.secondary) }
                                    if let a = b.details?.adapterWatts { Text("\(a) W adapter\(b.details?.adapterName.map { " · \($0)" } ?? "")").foregroundStyle(.secondary) }
                                }
                            }
                        }
                        Card(title: "Health", symbol: "heart") {
                            Metric(value: b.healthPercent.map { "\($0)%" } ?? "—", caption: "full-charge capacity vs design capacity",
                                   tint: (b.healthPercent ?? 100) >= 80 ? .green : .orange)
                            if let h = b.health { Text("Condition reported by macOS: \(h)").font(.callout) }
                            if let c = b.cycleCount { Text("\(c) charge cycles").font(.callout).foregroundStyle(.secondary) }
                        }
                        .frame(width: 300)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Card(title: "Battery controller readings", symbol: "list.bullet.rectangle") {
                        let d = b.details
                        Grid(alignment: .leading, horizontalSpacing: Theme.Space.xxl, verticalSpacing: 8) {
                            row("Design capacity", d?.designCapacity.map { "\($0) mAh" })
                            row("Full-charge capacity", d?.fullChargeCapacity.map { "\($0) mAh" })
                            row("Current charge", d?.currentCapacity.map { "\($0) mAh" })
                            row("Voltage", d?.voltage.map { String(format: "%.2f V", $0) })
                            row("Current", d?.amperage.map { "\($0) mA" })
                            row("Temperature", d?.temperature.map { String(format: "%.1f °C", $0) })
                            row("Serial", d?.serial)
                        }
                        Text("Read from the AppleSmartBattery IORegistry entry. These keys aren't formally documented by Apple, so treat the values as reported by the battery controller.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            } else {
                EmptyHero(symbol: "powerplug", tint: .success, title: "No battery", message: "This Mac runs on mains power only.")
            }
        }
        .onAppear { monitor.start(); monitor.refreshSlow() }
        .onDisappear { monitor.stop() }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "Not reported").monospacedDigit().foregroundStyle(value == nil ? .tertiary : .primary)
        }
    }
}

// MARK: - Startup Manager

struct StartupScreen: View {
    @Bindable var model: StartupModel
    @Environment(AppSettings.self) private var settings
    @State private var pending: PendingRemoval?

    private var selectedRemovable: [LaunchItem] {
        model.items.filter { model.selection.contains($0.url) && $0.domain.isRemovable }
    }

    var body: some View {
        Page(destination: .startup, subtitle: "\(model.items.count) launch items · only your own agents can be removed without an administrator", scrolls: false) {
            Button("Login Items Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            }
            Button("Remove \(selectedRemovable.count)…") {
                pending = PendingRemoval(title: "Remove launch agents",
                                         requests: selectedRemovable.map { RemovalRequest(url: $0.url, size: SizeCalculator.allocatedSize(of: $0.url)) },
                                         context: "Startup Manager",
                                         note: "Agents that are already running stop after you log out or restart.")
            }
            .disabled(selectedRemovable.isEmpty)
        } content: {
            VStack(spacing: Theme.Space.m) {
                if let report = model.lastReport { ReportBanner(report: report) { model.lastReport = nil } }
                Table(model.items, selection: $model.selection) {
                    TableColumn("Label") { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.domain == .userAgent ? "person" : "lock").foregroundStyle(.secondary).frame(width: 14)
                            Text(item.label).lineLimit(1).foregroundStyle(item.disabled ? .secondary : .primary)
                        }
                    }
                    TableColumn("Type") { item in Text(item.domain.rawValue).foregroundStyle(.secondary) }.width(110)
                    TableColumn("Program") { item in
                        Text(settings.expertMode ? (item.program ?? "—") : (item.program.map { ($0 as NSString).lastPathComponent } ?? "—"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }
                    TableColumn("Starts") { item in
                        Pill(text: item.disabled ? "Disabled" : item.keepAlive ? "Always" : item.runAtLoad ? "At login" : "On demand",
                             tint: item.disabled ? .secondary : item.keepAlive ? .orange : .blue)
                    }.width(90)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .contextMenu(forSelectionType: URL.self) { urls in
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
                }
            }
        }
        .onAppear { model.load() }
        .sheet(item: $pending) { removal in
            ReviewSheet(removal: removal) { report in model.didRemove(report.removed); model.lastReport = report }
        }
    }
}

// MARK: - Menu bar

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

struct MenuBarPanel: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                IconBadge(symbol: "sparkles", tint: .brand, size: 26)
                Text("UltaMac").font(.headline)
                Spacer()
                Text("Offline").font(.caption).foregroundStyle(.secondary)
            }
            row("CPU", "\(Int((monitor.cpu?.total ?? 0) * 100))%", Sparkline(values: monitor.cpuTotals, maxValue: 1, tint: .performance))
            row("Memory", monitor.memory.map { "\(ByteFormat.memory($0.used)) · \($0.pressure.rawValue)" } ?? "—",
                Sparkline(values: monitor.memoryTotals, maxValue: 1, tint: .apps))
            if let d = monitor.disk { row("Disk", "\(ByteFormat.string(d.available)) free", SizeBar(fraction: d.usedFraction, tint: .storage)) }
            if let n = monitor.network { row("Network", "↓ \(ByteFormat.rate(n.bytesInPerSecond))  ↑ \(ByteFormat.rate(n.bytesOutPerSecond))", EmptyView()) }
            if let b = monitor.battery { row("Battery", "\(b.percent)%\(b.isCharging ? " · charging" : "")", SizeBar(fraction: Double(b.percent) / 100, tint: .success)) }
            Divider()
            HStack {
                Button("Open UltaMac") { openWindow(id: "main"); NSApp.activate() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 300)
    }

    private func row<V: View>(_ title: String, _ value: String, _ visual: V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(.callout)
            visual.frame(height: 18)
        }
    }
}
