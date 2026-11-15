import SwiftUI
import UltaMacCore

// MARK: - Large & Old Files

struct LargeOldScreen: View {
    @Bindable var model: LargeOldModel
    @Environment(AppSettings.self) private var settings
    @State private var pending: PendingRemoval?
    @State private var sort = [KeyPathComparator(\FileEntry.size, order: .reverse)]

    var body: some View {
        Page(destination: .largeOld, subtitle: subtitle, scrolls: false) {
            if model.hasScanned && !model.isScanning {
                TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 180)
                Button { model.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }
        } content: {
            VStack(spacing: Theme.Space.m) {
                if let report = model.lastReport { ReportBanner(report: report) { model.lastReport = nil } }
                if model.isScanning {
                    ScanProgress(title: "Looking through your folders…", detail: "\(model.scanned.formatted()) items checked") { model.stop() }
                } else if !model.hasScanned {
                    EmptyHero(symbol: "archivebox", tint: .clean, title: "Find large and forgotten files",
                              message: "Lists files over 100 MB, and files over 10 MB you haven't opened in a year. Skips your Library, apps and hidden folders. These are your own files, so nothing is pre-selected.",
                              buttonTitle: "Scan Home Folder") { model.scan() }
                } else {
                    HStack {
                        ChipPicker(options: LargeOldModel.Filter.allCases.map { ($0, $0.rawValue) }, selection: $model.filter)
                        Spacer()
                        Picker("Kind", selection: $model.kind) {
                            Text("All kinds").tag(FileEntry.Kind?.none)
                            ForEach(FileEntry.Kind.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol).tag(Optional($0)) }
                        }
                        .frame(width: 170)
                    }
                    table
                    SelectionBar(count: model.selectedEntries.count, bytes: model.selectedEntries.reduce(0) { $0 + $1.size }, tint: .clean) {
                        pending = model.removal()
                    }
                }
            }
        }
        .sheet(item: $pending) { removal in
            ReviewSheet(removal: removal) { report in model.didRemove(report.removed); model.lastReport = report }
        }
    }

    private var subtitle: String? {
        model.hasScanned ? "\(model.entries.count) files · \(ByteFormat.string(model.totalSize))" : nil
    }

    private var table: some View {
        let rows = model.visible.sorted(using: sort)
        return Table(rows, selection: $model.selected, sortOrder: $sort) {
            TableColumn("Name", value: \.url.lastPathComponent) { e in
                HStack(spacing: 8) {
                    FileIcon(url: e.url, size: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            Text(e.url.lastPathComponent).lineLimit(1)
                            if let lock = e.lock { LockPill(lock: lock) }
                        }
                        Text(relativeHomePath(e.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            TableColumn("Kind") { e in Label(e.kind.rawValue, systemImage: e.kind.symbol).foregroundStyle(.secondary) }.width(110)
            TableColumn("Last used", value: \.lastUsed) { e in Text(e.lastUsed.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary) }.width(100)
            TableColumn("Size", value: \.size) { e in Text(ByteFormat.string(e.size)).monospacedDigit() }.width(80)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
            Button("Quick Look") { if let u = urls.first { NSWorkspace.shared.open(u) } }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

// MARK: - Duplicates

struct DuplicatesScreen: View {
    @Bindable var model: DuplicatesModel
    @Environment(AppSettings.self) private var settings
    @State private var pending: PendingRemoval?

    var body: some View {
        Page(destination: .duplicates, subtitle: subtitle, scrolls: false) {
            if model.hasScanned && !model.isScanning {
                Button { model.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }
        } content: {
            VStack(spacing: Theme.Space.m) {
                if let report = model.lastReport { ReportBanner(report: report) { model.lastReport = nil } }
                if model.isScanning {
                    let p = model.progress
                    ScanProgress(title: p?.phase ?? "Listing files…",
                                 detail: p.map { $0.total > 0 ? "\($0.done) of \($0.total) candidates" : "\($0.done.formatted()) files listed" } ?? "",
                                 fraction: p.flatMap { $0.total > 0 ? Double($0.done) / Double($0.total) : nil }) { model.stop() }
                } else if !model.hasScanned {
                    EmptyHero(symbol: "doc.on.doc", tint: .clean, title: "Find identical files",
                              message: "Checks Desktop, Documents, Downloads, Movies, Music and Pictures for files over 1 MB. Files are matched by size, then a quick hash, then a full SHA-256, so only byte-identical files are reported.",
                              buttonTitle: "Find Duplicates") { model.scan() }
                } else if model.groups.isEmpty {
                    EmptyHero(symbol: "checkmark.seal", tint: .success, title: "No duplicates found", message: "No byte-identical files over 1 MB in the scanned folders.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: Theme.Space.m) {
                            ForEach(model.groups) { group in groupCard(group) }
                        }
                    }
                    SelectionBar(count: model.selected.count, bytes: model.selectedFiles.reduce(0) { $0 + $1.size }, tint: .clean,
                                 secondary: model.everyGroupKeepsACopy ? nil : AnyView(
                                    Label("Every group must keep one copy", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange))) {
                        pending = model.removal()
                    }
                    .disabled(!model.everyGroupKeepsACopy)
                }
            }
        }
        .sheet(item: $pending) { removal in
            ReviewSheet(removal: removal) { report in model.didRemove(report.removed); model.lastReport = report }
        }
    }

    private var subtitle: String? {
        model.hasScanned ? "\(model.groups.count) groups · \(ByteFormat.string(model.wasted)) in extra copies" : nil
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                FileIcon(url: group.files[0].url, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.files[0].url.lastPathComponent).font(.body.weight(.semibold)).lineLimit(1)
                    Text("\(group.files.count) copies · \(ByteFormat.string(group.size)) each")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if settings.expertMode { Text("SHA-256 \(group.hash.prefix(16))…").font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                Text("\(ByteFormat.string(group.wasted)) extra").font(.callout.monospacedDigit().weight(.medium))
            }
            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                HStack(spacing: Theme.Space.s) {
                    Toggle("", isOn: Binding(
                        get: { model.selected.contains(file.url) },
                        set: { if $0 { model.selected.insert(file.url) } else { model.selected.remove(file.url) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .disabled(file.lock != nil)
                    Text(relativeHomePath(file.url)).lineLimit(1).truncationMode(.middle)
                    if let lock = file.lock { LockPill(lock: lock) }
                    if !model.selected.contains(file.url) { Pill(text: "Keep", tint: .green) }
                    if index == 0 { Pill(text: "Oldest", tint: .secondary) }
                    Spacer()
                    Text(file.modified.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                }
                .padding(.leading, 4)
            }
        }
        .cardSurface(padding: Theme.Space.m)
        .overlay {
            if !model.groupKeepsACopy(group) {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(.orange, lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Recent activity

struct ActivityScreen: View {
    @Environment(AppSettings.self) private var settings
    @State private var entries: [AuditEntry] = []
    @State private var expanded = Set<Date>()

    var body: some View {
        Page(destination: .activity) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([settings.auditLog.url]) } label: {
                Label("Show Log File", systemImage: "doc.text")
            }
            .disabled(entries.isEmpty)
        } content: {
            if entries.isEmpty {
                EmptyHero(symbol: "clock.arrow.circlepath", tint: .brand, title: "No activity yet",
                          message: "Each time UltaMac removes something, the items, sizes, mode and any failures are recorded here and in a local log file.")
                    .frame(minHeight: 420)
            } else {
                LazyVStack(spacing: Theme.Space.m) {
                    ForEach(entries) { entry in
                        let open = expanded.contains(entry.date)
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            HStack {
                                IconBadge(symbol: entry.failures.isEmpty ? "checkmark" : "exclamationmark", tint: entry.failures.isEmpty ? .success : .warning, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.context).font(.body.weight(.semibold))
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(ByteFormat.string(entry.bytes)).monospacedDigit().font(.callout.weight(.medium))
                                    Text("\(entry.items.count) removed\(entry.failures.isEmpty ? "" : " · \(entry.failures.count) failed")").font(.caption).foregroundStyle(.secondary)
                                }
                                Button { animate { if open { expanded.remove(entry.date) } else { expanded.insert(entry.date) } } } label: {
                                    Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0))
                                }
                                .buttonStyle(.borderless)
                            }
                            if open {
                                ForEach(entry.items, id: \.path) { item in
                                    HStack {
                                        Image(systemName: item.permanent ? "flame" : "trash").foregroundStyle(item.permanent ? .red : .secondary)
                                        Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(ByteFormat.string(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.caption)
                                }
                                ForEach(entry.failures) { f in
                                    Text("✕ \(f.url.lastPathComponent): \(f.reason)").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .cardSurface(padding: Theme.Space.m)
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: settings.historyRevision) { _, _ in load() }
    }

    private func load() {
        let log = settings.auditLog
        Task { entries = await runInBackground { log.recent(limit: 200) } }
    }
}
