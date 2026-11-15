import SwiftUI
import UltaMacCore

struct UninstallerScreen: View {
    @Bindable var model: UninstallerModel
    @Environment(AppSettings.self) private var settings
    @State private var pending: PendingRemoval?

    var body: some View {
        Page(destination: .uninstaller, subtitle: subtitle, scrolls: false) {
            TextField("Search apps", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 200)
        } content: {
            VStack(spacing: Theme.Space.m) {
                if let report = model.lastReport { ReportBanner(report: report, onClose: { model.lastReport = nil }, onUpdate: { r in model.didRemove(r.removed); model.lastReport = r }) }
                ChipPicker(options: UninstallerModel.Filter.allCases.map { ($0, "\($0.rawValue) (\(model.filtered($0).count))") },
                           selection: $model.filter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    appList.frame(width: 340)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            model.unusedDays = settings.unusedAppDays
            if !model.hasLoaded { model.load() }
        }
        .onChange(of: model.selectedApp) { _, _ in model.findLeftovers() }
        .sheet(item: $pending) { removal in
            ReviewSheet(removal: removal) { report in model.didRemove(report.removed); model.lastReport = report }
        }
    }

    private var subtitle: String? {
        guard model.hasLoaded else { return nil }
        let total = model.apps.compactMap(\.size).reduce(0, +)
        return "\(model.apps.count) apps · \(ByteFormat.string(total))"
    }

    private var appList: some View {
        Group {
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.visibleApps, selection: $model.selectedApp) { app in
                    HStack(spacing: 10) {
                        FileIcon(url: app.url, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).lineLimit(1)
                            HStack(spacing: 4) {
                                if app.architecture == .intel { Pill(text: "Intel", tint: .orange) }
                                Text(app.lastUsed.map { "Opened \(relativeDate($0))" } ?? "Never opened (per Spotlight)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if let size = app.size {
                            Text(ByteFormat.string(size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(app.id)
                }
                .listStyle(.inset)
            }
        }
        .cardSurface(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    @ViewBuilder private var detail: some View {
        if let app = model.app {
            appDetail(app).cardSurface()
        } else {
            EmptyHero(symbol: "xmark.app", tint: .apps, title: "Select an app",
                      message: "UltaMac shows the app and every support file it left in your Library before anything is removed. Apple's built-in apps aren't listed.")
                .cardSurface()
        }
    }

    private func appDetail(_ app: InstalledApp) -> some View {
        let leftoverSize = model.leftovers.filter { model.selectedLeftovers.contains($0.url) }.reduce(Int64(0)) { $0 + $1.size }
        let running = model.isRunning(app)
        let appLock = RemovalLock.check(app.url)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                FileIcon(url: app.url, size: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.title2.bold())
                    HStack(spacing: 6) {
                        if let v = app.version { Pill(text: "v\(v)") }
                        Pill(text: app.architecture.rawValue, tint: app.architecture == .intel ? .orange : .blue,
                             symbol: app.architecture == .intel ? "exclamationmark.triangle" : "cpu")
                        if app.isFromAppStore { Pill(text: "App Store", tint: .blue, symbol: "bag") }
                    }
                    Text(app.lastUsed.map { "Last opened \($0.formatted(date: .long, time: .omitted))" } ?? "No last-opened date recorded by Spotlight")
                        .font(.caption).foregroundStyle(.secondary)
                    if settings.expertMode {
                        Text([app.bundleID, app.url.path].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
                Spacer()
            }
            if app.architecture == .intel {
                Label("This app is Intel-only and runs on your Mac through Rosetta 2. A newer Apple Silicon version may be available from its developer.",
                      systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            if let appLock {
                Label(appLock.reason, systemImage: "lock.fill").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if running {
                HStack {
                    Label("\(app.name) is running. Quit it before uninstalling.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("Quit \(app.name)") { model.quit(app) }
                }
            }
            HStack {
                Text("Related files").font(.headline)
                if model.isFindingLeftovers { ProgressView().controlSize(.small) }
                Spacer()
                Text("Bundle-ID matches are ticked. Name-only matches need your review.").font(.caption).foregroundStyle(.secondary)
            }
            List(model.leftovers) { leftover in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { model.selectedLeftovers.contains(leftover.url) },
                        set: { if $0 { model.selectedLeftovers.insert(leftover.url) } else { model.selectedLeftovers.remove(leftover.url) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(relativeHomePath(leftover.url)).lineLimit(1).truncationMode(.middle)
                            if let lock = leftover.lock { LockPill(lock: lock) }
                        }
                        HStack(spacing: 4) {
                            Text(leftover.kind).font(.caption).foregroundStyle(.secondary)
                            Pill(text: leftover.match == .bundleID ? "High confidence" : "Name match: review",
                                 tint: leftover.match == .bundleID ? .green : .orange)
                        }
                    }
                    Spacer()
                    Text(ByteFormat.string(leftover.size)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if !model.isFindingLeftovers && model.leftovers.isEmpty {
                    Text("No related files found in your Library.").foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("App \(ByteFormat.string(app.size ?? 0)) + related \(ByteFormat.string(leftoverSize))")
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Remove Related Files Only…") { pending = model.removal(includeApp: false) }
                    .disabled(model.selectedLeftovers.isEmpty)
                Button("Uninstall…") { pending = model.removal(includeApp: true) }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(running)
                    .help(appLock.map { $0.reason + " You'll be asked for your administrator password." } ?? "")
            }
        }
    }
}
