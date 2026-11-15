import SwiftUI
import UltaMacCore

struct DashboardScreen: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings
    @State private var history: [AuditEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                hero
                metrics
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    healthCard.frame(maxWidth: .infinity)
                    activityCard.frame(width: 340).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Space.page)
            .padding(.top, Theme.Space.s)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            monitor.start()
            monitor.refreshSlow()
            loadHistory()
            let args = CommandLine.arguments
            let sectionArg = args.firstIndex(of: "--section").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            if args.contains("--scan"), sectionArg == nil || sectionArg == "dashboard", state.smartScan.lastRun == nil {
                state.smartScan.run(junk: state.junk, files: state.largeOld, apps: state.uninstaller)
            }
        }
        .onDisappear { monitor.stop() }
        .onChange(of: settings.historyRevision) { _, _ in loadHistory() }
    }

    private func loadHistory() {
        let log = settings.auditLog
        Task { history = await runInBackground { log.recent(limit: 6) } }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: Theme.Space.xxl) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Presentation.redact ? "MacBook Pro" : (Host.current().localizedName ?? "Your Mac"))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("\(monitor.system.chip) · \(monitor.system.osVersion) · \(ByteFormat.memory(monitor.memory?.total ?? 0)) memory")
                        .foregroundStyle(.secondary)
                    Text("Up \(formatDuration(monitor.system.uptime)) · \(monitor.system.model)")
                        .font(.callout).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                smartScanControl
            }
            Spacer(minLength: 0)
            storageRing
        }
        .padding(Theme.Space.xl)
        .frame(height: 250)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.brand.opacity(0.10))
                // Soft light glows give depth. Radial gradients are static and cheap (no blur pass).
                RadialGradient(colors: [Theme.Tint.brand.colors[1].opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 420)
                RadialGradient(colors: [Theme.Tint.brand.colors[0].opacity(0.14), .clear], center: .bottomLeading, startRadius: 0, endRadius: 360)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.07), radius: 16, y: 6)
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var smartScanControl: some View {
        let scan = state.smartScan
        return HStack(spacing: Theme.Space.l) {
            Button {
                scan.run(junk: state.junk, files: state.largeOld, apps: state.uninstaller)
            } label: {
                HStack(spacing: 8) {
                    if scan.isRunning { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: "sparkles") }
                    Text(scan.isRunning ? "Scanning…" : scan.lastRun == nil ? "Run Smart Scan" : "Scan Again")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(Theme.brand, in: Capsule())
                .shadow(color: Theme.Tint.brand.colors[1].opacity(0.4), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(scan.isRunning)
            .help("Scans junk, large & old files and apps. Read-only: nothing is removed.")

            if !scan.isRunning && scan.lastRun == nil {
                Text("Read-only · checks junk, large files and apps").font(.callout).foregroundStyle(.secondary)
            }
            if scan.isRunning || scan.lastRun != nil {
                HStack(spacing: Theme.Space.m) {
                    stepLabel("Junk", scan.junkState)
                    stepLabel("Files", scan.filesState)
                    stepLabel("Apps", scan.appsState)
                }
                .transition(.opacity)
            }
        }
    }

    private func stepLabel(_ title: String, _ s: SmartScanModel.TaskState) -> some View {
        HStack(spacing: 4) {
            switch s {
            case .running: ProgressView().controlSize(.mini)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .idle: Image(systemName: "circle").foregroundStyle(.tertiary)
            }
            Text(title).font(.callout)
        }
    }

    private var storageRing: some View {
        let d = monitor.disk
        return VStack(spacing: Theme.Space.s) {
            ZStack {
                Ring(fraction: d?.usedFraction ?? 0, tint: (d?.usedFraction ?? 0) > 0.9 ? .danger : .storage, lineWidth: 16)
                VStack(spacing: 0) {
                    Text(d.map { ByteFormat.string($0.available) } ?? "—")
                        .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    Text("available").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 168, height: 168)
            Text(d.map { "\(ByteFormat.string($0.used)) of \(ByteFormat.string($0.total)) used" } ?? "")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onTapGesture { state.go(.storage) }
        .help("Open Storage Analyser")
    }

    // MARK: Metrics

    private var metrics: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 170), spacing: Theme.Space.l), count: monitor.battery == nil ? 3 : 4), spacing: Theme.Space.l) {
            metricCard("CPU", "cpu", .performance, destination: .monitor) {
                Metric(value: "\(Int((monitor.cpu?.total ?? 0) * 100))%", caption: "\(monitor.system.cores) cores · load \(String(format: "%.2f", monitor.system.loadAverage.0))")
            } chart: { Sparkline(values: monitor.cpuTotals, maxValue: 1, tint: .performance) }

            metricCard("Memory", "memorychip", .apps, destination: .processes) {
                HStack(alignment: .firstTextBaseline) {
                    Metric(value: monitor.memory.map { ByteFormat.memory($0.used) } ?? "—", caption: "of \(ByteFormat.memory(monitor.memory?.total ?? 0))")
                    Spacer()
                    if let p = monitor.memory?.pressure {
                        Pill(text: p.rawValue, tint: p == .normal ? .green : p == .warning ? .orange : .red)
                    }
                }
            } chart: { Sparkline(values: monitor.memoryTotals, maxValue: 1, tint: .apps) }

            if let b = monitor.battery {
                metricCard("Battery", b.isCharging ? "battery.100percent.bolt" : "battery.75percent", .success, destination: .battery) {
                    HStack(alignment: .firstTextBaseline) {
                        Metric(value: "\(b.percent)%", caption: b.isCharging ? "Charging" : b.onACPower ? "On power adapter" : "On battery")
                        Spacer()
                        if let h = b.healthPercent { Pill(text: "Health \(h)%", tint: h >= 80 ? .green : .orange) }
                    }
                } chart: {
                    SizeBar(fraction: Double(b.percent) / 100, tint: b.percent < 20 ? .danger : .success)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }

            metricCard("Network", "network", .storage, destination: .monitor) {
                Metric(value: monitor.network.map { ByteFormat.rate($0.bytesInPerSecond) } ?? "—",
                       caption: "down · \(monitor.network.map { ByteFormat.rate($0.bytesOutPerSecond) } ?? "—") up")
            } chart: {
                Sparkline(values: monitor.networkHistory.filter { $0.series == "Download" }.map(\.value), tint: .storage)
            }
        }
    }

    private func metricCard<Top: View, Chart: View>(_ title: String, _ symbol: String, _ tint: Theme.Tint, destination: Destination,
                                                     @ViewBuilder top: () -> Top, @ViewBuilder chart: () -> Chart) -> some View {
        Button { state.go(destination) } label: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: 7) {
                    IconBadge(symbol: symbol, tint: tint, size: 22)
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                top()
                chart().frame(height: 34)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverLift())
    }

    // MARK: Health & activity

    private var healthCard: some View {
        let checks = HealthCheck.evaluate(monitor: monitor, junk: state.junk, files: state.largeOld,
                                          apps: state.uninstaller, unusedDays: settings.unusedAppDays)
        let ok = checks.filter { $0.status == .ok }.count
        return Card(title: "Mac Health", symbol: "heart.text.square") {
            Text("\(ok) of \(checks.count) checks OK. Each check uses a measured value and a stated threshold, not a score.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Image(systemName: check.status.symbol).foregroundStyle(check.status.color).font(.body)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title).font(.callout.weight(.semibold))
                            Text(check.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let action = check.action {
                            Button(action.title) { state.go(action.destination) }.controlSize(.small)
                        }
                    }
                    .padding(.vertical, 8)
                    if check.id != checks.last?.id { Divider() }
                }
            }
            if state.smartScan.lastRun == nil {
                Text("Run Smart Scan to add junk, file and app checks.").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var activityCard: some View {
        Card(title: "Recent Activity", symbol: "clock.arrow.circlepath") {
            if history.isEmpty {
                Text("Nothing removed yet. Every cleanup is logged here, on this Mac only.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(history) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.context).font(.callout.weight(.medium))
                            Text(entry.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(ByteFormat.string(entry.bytes)).font(.callout.monospacedDigit())
                            Text("\(entry.items.count) items").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("View all") { state.go(.activity) }.buttonStyle(.link)
            }
        }
    }
}

/// Subtle lift on hover for clickable cards.
struct HoverLift: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : hovering && !Motion.reduce ? 1.01 : 1)
            .brightness(hovering ? 0.01 : 0)
            .animation(Motion.spring, value: hovering)
            .animation(Motion.spring, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
