import SwiftUI
import UltaMacCore

struct StorageScreen: View {
    @Bindable var model: StorageModel
    @Environment(AppSettings.self) private var settings
    @State private var pending: PendingRemoval?

    var body: some View {
        Page(destination: .storage, subtitle: subtitle, scrolls: false) {
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.directoryURL = model.root
                if panel.runModal() == .OK, let url = panel.url { model.root = url; model.scan() }
            } label: { Label(relativeHomePath(model.root), systemImage: "folder") }
            if model.tree != nil && !model.isScanning {
                Picker("", selection: $model.viewMode) {
                    Image(systemName: "square.grid.3x3.fill").tag(StorageModel.ViewMode.map)
                    Image(systemName: "list.bullet").tag(StorageModel.ViewMode.list)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 90)
                Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }.help("Rescan")
            }
        } content: {
            VStack(spacing: Theme.Space.m) {
                if let report = model.lastReport { ReportBanner(report: report, onClose: { model.lastReport = nil }, onUpdate: { r in model.didRemove(r.removed); model.lastReport = r }) }
                if model.isScanning {
                    ScanProgress(title: "Measuring \(relativeHomePath(model.root))",
                                 detail: model.progress.map { "\($0.filesScanned.formatted()) files · \(ByteFormat.string($0.bytesScanned)) · \(relativeHomePath(URL(fileURLWithPath: $0.currentPath)))" } ?? "Starting…") { model.stop() }
                } else if let current = model.current {
                    breadcrumbs(current)
                    if model.viewMode == .map {
                        Treemap(nodes: current.children, selection: $model.selection) { model.open($0) }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    } else {
                        list(current)
                    }
                    if !model.selectedNodes.isEmpty {
                        SelectionBar(count: model.selectedNodes.count, bytes: model.selectedNodes.reduce(0) { $0 + $1.size }, tint: .storage) {
                            pending = PendingRemoval(title: "Remove selected items",
                                                     requests: model.selectedNodes.map { RemovalRequest(url: $0.url, size: $0.size) },
                                                     context: "Storage Analyser")
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                } else {
                    EmptyHero(symbol: "square.grid.3x3.fill", tint: .storage, title: "See what fills your disk",
                              message: "UltaMac measures every folder and shows the result as a map. Click a tile to select it, double-click a folder to open it. Measuring only reads.",
                              buttonTitle: "Scan Home Folder") { model.scan() }
                }
            }
        }
        .onAppear { if CommandLine.arguments.contains("--scan"), model.tree == nil, !model.isScanning { model.scan() } }
        .sheet(item: $pending) { removal in
            ReviewSheet(removal: removal) { report in model.didRemove(report.removed); model.lastReport = report }
        }
    }

    private var subtitle: String? {
        guard let tree = model.tree else { return nil }
        return "\(ByteFormat.string(tree.size)) in \(tree.itemCount.formatted()) files · scanned \(relativeDate(model.scannedAt))"
    }

    private func breadcrumbs(_ current: StorageNode) -> some View {
        HStack(spacing: 4) {
            Button { model.go(to: nil) } label: { Label(model.tree?.name ?? "", systemImage: "house") }.buttonStyle(.link)
            ForEach(model.path) { node in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(node.name) { model.go(to: node) }.buttonStyle(.link)
            }
            Spacer()
            Text("\(ByteFormat.string(current.size)) · \(current.itemCount.formatted()) files")
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
    }

    private func list(_ current: StorageNode) -> some View {
        List(selection: $model.selection) {
            ForEach(current.children) { node in
                HStack(spacing: 10) {
                    if node.isAggregate { Image(systemName: "doc.on.doc").frame(width: 20) } else { FileIcon(url: node.url) }
                    Text(node.name).lineLimit(1).truncationMode(.middle).foregroundStyle(node.isAggregate ? .secondary : .primary)
                    if node.isDirectory && !node.children.isEmpty { Image(systemName: "chevron.right.circle").foregroundStyle(.tertiary) }
                    Spacer()
                    if settings.expertMode { Text("\(node.itemCount.formatted()) files").font(.caption).foregroundStyle(.tertiary) }
                    SizeBar(fraction: current.size > 0 ? Double(node.size) / Double(current.size) : 0, tint: .storage).frame(width: 140)
                    Text(ByteFormat.string(node.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                .tag(node.id)
                .selectionDisabled(node.isAggregate)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let node = current.children.first(where: { $0.id == id }), !node.isAggregate {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let node = current.children.first(where: { $0.id == id }) { model.open(node) }
        }
    }
}

// MARK: - Treemap

/// Squarified treemap (Bruls, Huizing & van Wijk) of a folder's children.
struct Treemap: View {
    let nodes: [StorageNode]
    @Binding var selection: Set<UUID>
    let open: (StorageNode) -> Void
    @State private var hovered: UUID?

    var body: some View {
        GeometryReader { geo in
            let shown = Array(nodes.filter { $0.size > 0 }.prefix(80))
            let rects = TreemapLayout.squarify(shown.map { Double($0.size) }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(shown, rects)), id: \.0.id) { node, rect in
                    tile(node, rect)
                }
            }
        }
        .background(Color.primary.opacity(0.04))
    }

    private func tile(_ node: StorageNode, _ rect: CGRect) -> some View {
        let selected = selection.contains(node.id)
        let tint = Treemap.tint(for: node)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.white : Color.white.opacity(hovered == node.id ? 0.6 : 0), lineWidth: selected ? 3 : 1.5)
            }
            .overlay(alignment: .topLeading) {
                if rect.width > 70 && rect.height > 34 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(ByteFormat.string(node.size)).font(.caption2.monospacedDigit()).opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1)
                    .padding(6)
                }
            }
            .frame(width: max(0, rect.width - 3), height: max(0, rect.height - 3))
            .offset(x: rect.minX + 1.5, y: rect.minY + 1.5)
            .onHover { hovered = $0 ? node.id : (hovered == node.id ? nil : hovered) }
            .onTapGesture(count: 2) { open(node) }
            .onTapGesture {
                guard !node.isAggregate else { return }
                if selection.contains(node.id) { selection.remove(node.id) } else { selection.insert(node.id) }
            }
            .help("\(node.name): \(ByteFormat.string(node.size))\(node.isDirectory ? ". Double-click to open" : "")")
            .contextMenu {
                if !node.isAggregate {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                }
            }
    }

    static func tint(for node: StorageNode) -> Color {
        if node.isAggregate { return .gray }
        if node.isDirectory {
            // Stable hue per folder name within the storage palette range (blue → violet → teal).
            let h = Double(node.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1000 }) / 1000
            return Color(hue: 0.50 + h * 0.28, saturation: 0.55, brightness: 0.82)
        }
        switch FileEntry.Kind.of(node.url) {
        case .video: return Color(hue: 0.95, saturation: 0.55, brightness: 0.85)
        case .image: return Color(hue: 0.08, saturation: 0.6, brightness: 0.9)
        case .archive, .diskImage: return Color(hue: 0.13, saturation: 0.65, brightness: 0.85)
        case .audio: return Color(hue: 0.85, saturation: 0.45, brightness: 0.8)
        case .document: return Color(hue: 0.33, saturation: 0.45, brightness: 0.75)
        case .other: return Color(hue: 0.6, saturation: 0.15, brightness: 0.6)
        }
    }
}
