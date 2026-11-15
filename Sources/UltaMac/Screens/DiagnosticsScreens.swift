import SwiftUI
import UltaMacCore
import UniformTypeIdentifiers

// MARK: - Network Inspector

struct NetworkScreen: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @State private var snapshot: NetworkSnapshot?
    @State private var connections: [NetworkConnection] = []
    @State private var loadingConnections = false
    @State private var pingOutput: String?
    @State private var pinging = false

    var body: some View {
        Page(destination: .network, subtitle: "Read from local configuration · nothing is sent unless you start a ping") {
            Button { refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        } content: {
            if let s = snapshot {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        Card(title: "Overview", symbol: "globe") {
                            Grid(alignment: .leading, horizontalSpacing: Theme.Space.xl, verticalSpacing: 6) {
                                row("Host name", s.hostName)
                                row("Primary interface", s.primaryInterface ?? "None")
                                row("Router", s.router ?? "—")
                                row("DNS servers", s.dnsServers.isEmpty ? "—" : s.dnsServers.joined(separator: ", "))
                                if !s.searchDomains.isEmpty { row("Search domains", s.searchDomains.joined(separator: ", ")) }
                            }
                        }
                        Card(title: "Throughput", symbol: "arrow.up.arrow.down") {
                            Metric(value: monitor.network.map { ByteFormat.rate($0.bytesInPerSecond) } ?? "—", caption: "download", size: 20)
                            Metric(value: monitor.network.map { ByteFormat.rate($0.bytesOutPerSecond) } ?? "—", caption: "upload", size: 20)
                        }
                        .frame(width: 220)
                        Card(title: "Diagnostics", symbol: "stethoscope") {
                            Text("Ping your router to check the local connection. This sends 4 packets on your own network only.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(pinging ? "Pinging…" : "Ping Router") { ping(s.router) }.disabled(s.router == nil || pinging)
                            if let pingOutput {
                                Text(pingOutput).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                            }
                        }
                        .frame(width: 260)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    Text("Interfaces").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.Space.l)], spacing: Theme.Space.l) {
                        ForEach(s.interfaces) { i in interfaceCard(i) }
                    }

                    HStack {
                        Text("Active connections (your processes)").font(.headline)
                        Spacer()
                        Button(loadingConnections ? "Reading…" : "Show Connections") { loadConnections() }.disabled(loadingConnections)
                    }
                    if !connections.isEmpty {
                        Table(connections) {
                            TableColumn("Process") { c in Text(c.process) }
                            TableColumn("Protocol") { c in Text(c.proto) }.width(60)
                            TableColumn("Local") { c in Text(c.local).font(.caption.monospaced()) }
                            TableColumn("Remote") { c in Text(c.remote.isEmpty ? "listening" : c.remote).font(.caption.monospaced()) }
                            TableColumn("State") { c in Text(c.state).foregroundStyle(.secondary) }.width(90)
                        }
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .onAppear { refresh(); monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private func interfaceCard(_ i: NetworkInterfaceInfo) -> some View {
        Card {
            HStack {
                IconBadge(symbol: i.kind.contains("IEEE80211") ? "wifi" : i.kind.contains("Ethernet") ? "cable.connector" : "point.3.connected.trianglepath.dotted",
                          tint: i.isPrimary ? .storage : .tools, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(i.displayName).font(.body.weight(.semibold))
                    Text(i.bsdName).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if i.isPrimary { Pill(text: "Primary", tint: .blue) }
                Pill(text: i.isRunning ? "Active" : i.isUp ? "Up" : "Down", tint: i.isRunning ? .green : .secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: 4) {
                if !i.ipv4.isEmpty { row("IPv4", i.ipv4.joined(separator: ", ")) }
                if settings.expertMode, !i.ipv6.isEmpty { row("IPv6", i.ipv6.joined(separator: "\n")) }
                if settings.expertMode, let mac = i.macAddress { row("MAC", mac) }
                if settings.expertMode { row("MTU", "\(i.mtu)") }
                row("Traffic", "↓ \(ByteFormat.string(Int64(i.bytesIn)))  ↑ \(ByteFormat.string(Int64(i.bytesOut)))")
            }
            .font(.callout)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled).monospacedDigit()
        }
    }

    private func refresh() { Task { snapshot = await runInBackground { NetworkSnapshot.current() } } }

    private func loadConnections() {
        loadingConnections = true
        Task {
            connections = await runInBackground { NetworkSnapshot.connections() }
            loadingConnections = false
        }
    }

    private func ping(_ host: String?) {
        guard let host else { return }
        pinging = true
        Task {
            let r = await runInBackground { ProcessRunner.run("/sbin/ping", ["-c", "4", "-t", "6", host], timeout: 10) }
            pingOutput = r.output.split(separator: "\n").suffix(2).joined(separator: "\n")
            if pingOutput?.isEmpty ?? true { pingOutput = "No reply from \(host)." }
            pinging = false
        }
    }
}

// MARK: - Maintenance

struct MaintenanceScreen: View {
    @Environment(AppState.self) private var state
    private var model: MaintenanceModel { state.maintenance }
    @State private var expanded = Set<String>()

    var body: some View {
        Page(destination: .maintenance, subtitle: "Supported tasks only. Each explains its purpose, effect and risk. Speed-up tools are in Optimise.") {
            LazyVStack(spacing: Theme.Space.m) {
                ForEach(MaintenanceTask.all) { task in taskCard(task) }
            }
        }
    }

    private func taskCard(_ task: MaintenanceTask) -> some View {
        let run = model.runs[task.id]
        let open = expanded.contains(task.id)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                IconBadge(symbol: task.symbol, tint: .performance, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(task.title).font(.body.weight(.semibold))
                        if task.needsAdmin { Pill(text: "Admin password", tint: .orange, symbol: "lock") } else { Pill(text: "Read-only", tint: .green) }
                        Text(task.estimatedDuration).font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(task.purpose).font(.callout)
                    Text("Effect: \(task.effect)").font(.caption).foregroundStyle(.secondary)
                    Text("Risk: \(task.risk)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if run?.running == true {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.cancel(task) }
                } else {
                    Button(run == nil ? "Run" : "Run Again") { model.run(task); expanded.insert(task.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let result = run?.result {
                HStack {
                    Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.succeeded ? .green : .orange)
                    Text(result.summary).font(.callout).lineLimit(2)
                    Spacer()
                    Button(open ? "Hide output" : "Show output") { animate { if open { expanded.remove(task.id) } else { expanded.insert(task.id) } } }
                        .buttonStyle(.link)
                }
            }
            if open, let run {
                ScrollView {
                    Text((run.result?.log ?? run.lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.s)
                }
                .frame(maxHeight: 200)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }
        }
        .cardSurface()
    }
}

// MARK: - System Reports

struct ReportsScreen: View {
    @State private var report: SystemReport?
    @State private var includeIdentifiers = false
    @State private var savedTo: URL?

    var body: some View {
        Page(destination: .reports, subtitle: "Generated on this Mac. Saved only where you choose.") {
            Toggle("Include serial number, MAC & host name", isOn: $includeIdentifiers).toggleStyle(.checkbox)
                .onChange(of: includeIdentifiers) { _, _ in generate() }
            Menu {
                Button("Markdown (.md)…") { export(markdown: true) }
                Button("JSON (.json)…") { export(markdown: false) }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .fixedSize()
            .disabled(report == nil)
        } content: {
            if let report {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if let savedTo {
                        Label("Saved to \(relativeHomePath(savedTo))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: Theme.Space.l)], alignment: .leading, spacing: Theme.Space.l) {
                        ForEach(report.sections) { section in
                            Card(title: section.title) {
                                Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: 5) {
                                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                        GridRow {
                                            Text(row[0]).foregroundStyle(.secondary)
                                            Text(row.count > 1 ? row[1] : "").textSelection(.enabled)
                                        }
                                    }
                                }
                                .font(.callout)
                            }
                        }
                    }
                    Text("Generated \(report.generated.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                ProgressView("Collecting system information…").frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .onAppear { if report == nil { generate() } }
    }

    private func generate() {
        let ids = includeIdentifiers
        Task { report = await runInBackground { SystemReport.generate(includeIdentifiers: ids) } }
    }

    private func export(markdown: Bool) {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "UltaMac System Report \(Date().formatted(.iso8601.year().month().day())).\(markdown ? "md" : "json")"
        panel.allowedContentTypes = [markdown ? UTType(filenameExtension: "md") ?? .plainText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (markdown ? Data(report.markdown.utf8) : report.json).write(to: url, options: .atomic)
            savedTo = url
            Sound.play(.success)
        } catch {
            savedTo = nil
            Sound.play(.error)
        }
    }
}
