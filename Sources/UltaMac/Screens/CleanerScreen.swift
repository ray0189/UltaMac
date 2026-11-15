import SwiftUI
import UltaMacCore

struct CleanerScreen: View {
    @Bindable var model: JunkModel
    @Environment(AppSettings.self) private var settings
    @State private var pending: PendingRemoval?
    @State private var expanded = Set<String>()

    var body: some View {
        Page(destination: .cleaner, subtitle: subtitle, scrolls: false) {
            if model.hasScanned && !model.isScanning {
                TextField("Search paths", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 200)
                Button { model.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }
        } content: {
            VStack(spacing: Theme.Space.m) {
                if let report = model.lastReport { ReportBanner(report: report) { model.lastReport = nil } }
                if model.isScanning {
                    ScanProgress(title: "Scanning…", detail: model.status, fraction: model.fraction) { model.stop() }
                } else if !model.hasScanned {
                    EmptyHero(symbol: "wand.and.stars", tint: .clean, title: "Find junk safely",
                              message: "UltaMac checks \(JunkRules.builtIn.count) documented locations in your Library and developer folders. Scanning only reads; you review everything before it's removed.",
                              buttonTitle: "Scan Now") { model.scan() }
                } else {
                    results
                    SelectionBar(count: model.selected.count, bytes: model.selectedSize, actionTitle: "Review & Clean…", tint: .clean) {
                        pending = model.removal()
                    }
                }
            }
        }
        .onAppear { if CommandLine.arguments.contains("--scan"), !model.hasScanned, !model.isScanning { model.scan() } }
        .sheet(item: $pending) { removal in
            ReviewSheet(removal: removal) { report in model.didRemove(report.removed); model.lastReport = report }
        }
    }

    private var subtitle: String? {
        model.hasScanned ? "\(ByteFormat.string(model.totalSize)) found in \(model.allItems.count) items · \(ByteFormat.string(model.selectedSize)) selected" : nil
    }

    private var results: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                // Category summary chips
                let cats = JunkCategory.allCases.filter { model.size(of: $0) > 0 }
                HStack(spacing: Theme.Space.s) {
                    ForEach(cats, id: \.self) { c in
                        HStack(spacing: 6) {
                            Image(systemName: c.symbol).foregroundStyle(Theme.Tint.clean.color)
                            Text(c.title).font(.callout)
                            Text(ByteFormat.string(model.size(of: c))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                    Spacer()
                }
                ForEach(model.groups.filter { !$0.items.isEmpty || $0.accessProblem != nil }) { group in
                    groupCard(group)
                }
            }
            .padding(.bottom, Theme.Space.s)
        }
    }

    private func groupCard(_ group: JunkGroup) -> some View {
        let items = model.visibleItems(in: group)
        let selectedCount = group.items.filter { model.selected.contains($0.url) }.count
        let isOpen = expanded.contains(group.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Toggle("", isOn: Binding(
                    get: { selectedCount > 0 },
                    set: { on in animate { model.setGroup(group, selected: on) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(group.items.isEmpty)
                IconBadge(symbol: group.rule.category.symbol, tint: .clean, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.rule.title).font(.body.weight(.semibold))
                        RiskPill(risk: group.rule.risk)
                        if selectedCount > 0 && selectedCount < group.items.count {
                            Text("\(selectedCount) of \(group.items.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(group.accessProblem ?? group.rule.explanation).font(.caption)
                        .foregroundStyle(group.accessProblem == nil ? Color.secondary : Color.orange)
                    if settings.expertMode {
                        Text("Rule \(group.rule.id) · ~/\(group.rule.target.relativePath) · after removal: \(group.rule.consequence)")
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                Spacer()
                Text(ByteFormat.string(group.totalSize)).font(.body.monospacedDigit().weight(.medium))
                Button { animate { if isOpen { expanded.remove(group.id) } else { expanded.insert(group.id) } } } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(group.items.isEmpty)
            }
            .padding(Theme.Space.m)

            if isOpen {
                Divider().padding(.horizontal, Theme.Space.m)
                if !settings.expertMode {
                    Text(group.rule.consequence).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.s)
                }
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in itemRow(item) }
                }
                .padding(.vertical, Theme.Space.xs)
            }
        }
        .cardSurface(padding: 0)
    }

    private func itemRow(_ item: JunkItem) -> some View {
        HStack(spacing: Theme.Space.s) {
            Toggle("", isOn: Binding(
                get: { model.selected.contains(item.url) },
                set: { if $0 { model.selected.insert(item.url) } else { model.selected.remove(item.url) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(item.note == "Locked" || item.note == "Needs admin")
            FileIcon(url: item.url, size: 16)
            Text(settings.expertMode ? relativeHomePath(item.url) : item.url.lastPathComponent)
                .lineLimit(1).truncationMode(.middle)
            if let note = item.note {
                if let lock = RemovalLock.check(item.url), note == lock.shortLabel { LockPill(lock: lock) }
                else { Pill(text: note, tint: .orange, symbol: "app.badge") }
            }
            Spacer()
            if settings.expertMode, let m = item.modified {
                Text(m.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.tertiary)
            }
            Text(ByteFormat.string(item.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Reveal in Finder")
        }
        .padding(.horizontal, Theme.Space.m + 4).padding(.vertical, 5)
    }
}
