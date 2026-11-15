import SwiftUI
import UltaMacCore

// MARK: - Storage

@MainActor @Observable
final class StorageModel {
    enum ViewMode: String { case map, list }

    var root: URL = FileManager.default.homeDirectoryForCurrentUser
    private(set) var tree: StorageNode?
    var path: [StorageNode] = []
    var selection = Set<UUID>()
    var viewMode: ViewMode = .map
    private(set) var isScanning = false
    private(set) var progress: StorageScanProgress?
    private(set) var scannedAt: Date?
    var lastReport: RemovalReport?
    private var cancel = CancellationFlag()

    var current: StorageNode? { path.last ?? tree }

    func scan() {
        cancel.cancel()
        cancel = CancellationFlag()
        let flag = cancel, root = root
        isScanning = true
        tree = nil; path = []; selection = []; progress = nil
        Sound.play(.scanStart)
        Task {
            let result = await runInBackground {
                StorageAnalyzer().scan(root, cancel: flag) { p in
                    Task { @MainActor in self.progress = p }
                }
            }
            guard !flag.isCancelled else { return }
            animate { tree = result; isScanning = false }
            scannedAt = Date()
            Sound.play(.scanComplete)
        }
    }

    func stop() { cancel.cancel(); isScanning = false }

    func open(_ node: StorageNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        animate { path.append(node); selection = [] }
    }

    func go(to node: StorageNode?) {
        animate {
            if let node, let index = path.firstIndex(where: { $0.id == node.id }) {
                path = Array(path.prefix(through: index))
            } else {
                path = []
            }
            selection = []
        }
    }

    var selectedNodes: [StorageNode] {
        (current?.children ?? []).filter { selection.contains($0.id) && !$0.isAggregate }
    }

    func didRemove(_ urls: [URL]) {
        tree?.prune(removed: Set(urls))
        tree = tree; path = path; selection = []
    }
}

// MARK: - Junk

@MainActor @Observable
final class JunkModel {
    private(set) var groups: [JunkGroup] = []
    var selected = Set<URL>()
    private(set) var isScanning = false
    private(set) var status = ""
    private(set) var fraction = 0.0
    private(set) var hasScanned = false
    private(set) var scannedAt: Date?
    var search = ""
    var lastReport: RemovalReport?
    private var cancel = CancellationFlag()

    func scan() {
        cancel.cancel()
        cancel = CancellationFlag()
        let flag = cancel
        let scanner = JunkScanner(runningBundleIDs: runningBundleIDs())
        let total = Double(scanner.rules.count)
        isScanning = true
        status = "Starting…"
        fraction = 0
        Sound.play(.scanStart)
        Task {
            let result = await runInBackground {
                let counter = Counter()
                return scanner.scan(cancel: flag) { title in
                    let done = counter.next()
                    Task { @MainActor in
                        self.status = title
                        animate { self.fraction = Double(done - 1) / total }
                    }
                }
            }
            guard !flag.isCancelled else { return }
            animate {
                groups = result
                selected = Set(result.flatMap(\.items).filter(\.selectedByDefault).map(\.url))
                fraction = 1
                isScanning = false
                hasScanned = true
            }
            scannedAt = Date()
            Sound.play(totalSize > 0 ? .found : .scanComplete)
        }
    }

    func stop() { cancel.cancel(); isScanning = false }

    var allItems: [JunkItem] { groups.flatMap(\.items) }
    var selectedItems: [JunkItem] { allItems.filter { selected.contains($0.url) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }

    func rule(for item: JunkItem) -> JunkRule? { groups.first { $0.rule.id == item.ruleID }?.rule }

    func size(of category: JunkCategory) -> Int64 {
        groups.filter { $0.rule.category == category }.reduce(0) { $0 + $1.totalSize }
    }

    func visibleItems(in group: JunkGroup) -> [JunkItem] {
        guard !search.isEmpty else { return group.items }
        return group.items.filter { $0.url.path.localizedCaseInsensitiveContains(search) }
    }

    func setGroup(_ group: JunkGroup, selected on: Bool) {
        for item in group.items {
            if on { selected.insert(item.url) } else { selected.remove(item.url) }
        }
    }

    func removal() -> PendingRemoval {
        let items = selectedItems
        let permanentRules = Set(groups.filter(\.rule.permanentOnly).map(\.rule.id))
        return PendingRemoval(
            title: "Clean \(items.count) item\(items.count == 1 ? "" : "s")",
            requests: items.map { RemovalRequest(url: $0.url, size: $0.size, permanentOnly: permanentRules.contains($0.ruleID)) },
            context: "Smart Cleaner")
    }

    func didRemove(_ urls: [URL]) {
        let removed = Set(urls)
        animate {
            for i in groups.indices { groups[i].items.removeAll { removed.contains($0.url) } }
            selected.subtract(removed)
        }
    }
}

/// Thread-safe counter for progress callbacks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

// MARK: - Large & Old

@MainActor @Observable
final class LargeOldModel {
    enum Filter: String, CaseIterable { case all = "All", large = "Large", old = "Not opened in a year" }

    private(set) var entries: [FileEntry] = []
    var selected = Set<URL>()
    var filter: Filter = .all
    var kind: FileEntry.Kind? = nil
    var search = ""
    private(set) var isScanning = false
    private(set) var scanned = 0
    private(set) var hasScanned = false
    var lastReport: RemovalReport?
    private var cancel = CancellationFlag()
    let largeThreshold: Int64 = 100_000_000

    func scan() {
        cancel.cancel()
        cancel = CancellationFlag()
        let flag = cancel
        isScanning = true
        scanned = 0
        Sound.play(.scanStart)
        Task {
            let result = await runInBackground {
                LargeOldFinder().scan(cancel: flag) { n in Task { @MainActor in self.scanned = n } }
            }
            guard !flag.isCancelled else { return }
            animate { entries = result; isScanning = false; hasScanned = true; selected = [] }
            Sound.play(.scanComplete)
        }
    }

    func stop() { cancel.cancel(); isScanning = false }

    var oldCutoff: Date { Date().addingTimeInterval(-365 * 86_400) }

    var visible: [FileEntry] {
        entries.filter { e in
            switch filter {
            case .all: true
            case .large: e.size >= largeThreshold
            case .old: e.lastUsed < oldCutoff
            }
        }
        .filter { kind == nil || $0.kind == kind }
        .filter { search.isEmpty || $0.url.path.localizedCaseInsensitiveContains(search) }
    }

    var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    var selectedEntries: [FileEntry] { entries.filter { selected.contains($0.url) } }

    func removal() -> PendingRemoval {
        PendingRemoval(title: "Remove \(selectedEntries.count) file\(selectedEntries.count == 1 ? "" : "s")",
                       requests: selectedEntries.map { RemovalRequest(url: $0.url, size: $0.size) },
                       context: "Large & Old Files",
                       note: "These are your own files. Check each one; nothing here is junk by definition.")
    }

    func didRemove(_ urls: [URL]) {
        let removed = Set(urls)
        animate { entries.removeAll { removed.contains($0.url) }; selected.subtract(removed) }
    }
}

// MARK: - Duplicates

@MainActor @Observable
final class DuplicatesModel {
    private(set) var groups: [DuplicateGroup] = []
    var selected = Set<URL>()
    private(set) var isScanning = false
    private(set) var progress: DuplicateScanProgress?
    private(set) var hasScanned = false
    var lastReport: RemovalReport?
    private var cancel = CancellationFlag()

    func scan() {
        cancel.cancel()
        cancel = CancellationFlag()
        let flag = cancel
        isScanning = true
        progress = nil
        Sound.play(.scanStart)
        Task {
            let result = await runInBackground {
                DuplicateFinder().scan(cancel: flag) { p in Task { @MainActor in self.progress = p } }
            }
            guard !flag.isCancelled else { return }
            animate {
                groups = result
                // Suggest keeping the oldest copy in each group; select the rest. Nothing is removed yet.
                selected = Set(result.flatMap { $0.files.dropFirst().map(\.url) })
                isScanning = false
                hasScanned = true
            }
            Sound.play(result.isEmpty ? .scanComplete : .found)
        }
    }

    func stop() { cancel.cancel(); isScanning = false }

    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }
    var selectedFiles: [FileEntry] { groups.flatMap(\.files).filter { selected.contains($0.url) } }

    /// Every group must keep at least one copy.
    func groupKeepsACopy(_ g: DuplicateGroup) -> Bool { g.files.contains { !selected.contains($0.url) } }
    var everyGroupKeepsACopy: Bool { groups.allSatisfy(groupKeepsACopy) }

    func removal() -> PendingRemoval {
        PendingRemoval(title: "Remove \(selectedFiles.count) duplicate\(selectedFiles.count == 1 ? "" : "s")",
                       requests: selectedFiles.map { RemovalRequest(url: $0.url, size: $0.size) },
                       context: "Duplicate Finder",
                       note: "Each group keeps at least one copy. Contents were verified identical with SHA-256.")
    }

    func didRemove(_ urls: [URL]) {
        let removed = Set(urls)
        animate {
            groups = groups.compactMap { g in
                let files = g.files.filter { !removed.contains($0.url) }
                return files.count > 1 ? DuplicateGroup(hash: g.hash, size: g.size, files: files) : nil
            }
            selected.subtract(removed)
        }
    }
}

// MARK: - Uninstaller

@MainActor @Observable
final class UninstallerModel {
    enum Filter: String, CaseIterable { case all = "All", unused = "Unused", intel = "Intel only", appStore = "App Store" }

    private(set) var apps: [InstalledApp] = []
    var search = ""
    var filter: Filter = .all
    var selectedApp: InstalledApp.ID?
    private(set) var leftovers: [Leftover] = []
    var selectedLeftovers = Set<URL>()
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var isFindingLeftovers = false
    var lastReport: RemovalReport?
    var unusedDays = 90

    func filtered(_ f: Filter) -> [InstalledApp] {
        apps.filter { app in
            switch f {
            case .all: true
            case .unused: app.isUnused(days: unusedDays)
            case .intel: app.architecture == .intel
            case .appStore: app.isFromAppStore
            }
        }
    }

    var visibleApps: [InstalledApp] {
        let list = filtered(filter).sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        guard !search.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(search) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(search) }
    }

    var app: InstalledApp? { apps.first { $0.id == selectedApp } }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        let own = Bundle.main.bundleIdentifier.map { Set([$0]) } ?? []
        Task {
            let list = await runInBackground { AppInventory(excludedBundleIDs: own).listApps() }
            animate { apps = list; isLoading = false; hasLoaded = true }
            for app in list {
                let size = await runInBackground { SizeCalculator.allocatedSize(of: app.url) }
                if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].size = size }
            }
        }
    }

    func findLeftovers() {
        guard let app else { leftovers = []; return }
        isFindingLeftovers = true
        leftovers = []
        let others = Set(apps.compactMap(\.bundleID))
        Task {
            let found = await runInBackground { LeftoverFinder().leftovers(for: app, otherBundleIDs: others) }
            guard app.id == selectedApp else { return }
            animate {
                leftovers = found
                selectedLeftovers = Set(found.filter(\.selectedByDefault).map(\.url))
                isFindingLeftovers = false
            }
        }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        guard let id = app.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    func quit(_ app: InstalledApp) {
        guard let id = app.bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
    }

    func removal(includeApp: Bool) -> PendingRemoval? {
        guard let app else { return nil }
        var requests = leftovers.filter { selectedLeftovers.contains($0.url) }.map { RemovalRequest(url: $0.url, size: $0.size) }
        if includeApp { requests.insert(RemovalRequest(url: app.url, size: app.size ?? 0), at: 0) }
        return PendingRemoval(
            title: includeApp ? "Uninstall \(app.name)" : "Remove \(app.name) leftovers",
            requests: requests, purpose: .uninstallApp, context: "App Uninstaller",
            note: app.isFromAppStore ? "App Store apps can be reinstalled from the App Store." : nil)
    }

    func didRemove(_ urls: [URL]) {
        let removed = Set(urls)
        animate {
            if let app, removed.contains(app.url) {
                apps.removeAll { $0.id == app.id }
                selectedApp = nil
                leftovers = []
            } else {
                leftovers.removeAll { removed.contains($0.url) }
            }
            selectedLeftovers.subtract(removed)
        }
    }
}

// MARK: - Startup items

@MainActor @Observable
final class StartupModel {
    private(set) var items: [LaunchItem] = []
    var selection = Set<URL>()
    var lastReport: RemovalReport?

    func load() {
        Task { let list = await runInBackground { LaunchItemsScanner().scan() }; animate { items = list } }
    }

    func didRemove(_ urls: [URL]) {
        let removed = Set(urls)
        animate { items.removeAll { removed.contains($0.url) }; selection.subtract(removed) }
    }
}

// MARK: - Smart Scan (orchestrates the other models)

@MainActor @Observable
final class SmartScanModel {
    enum TaskState { case idle, running, done }

    private(set) var junkState: TaskState = .idle
    private(set) var filesState: TaskState = .idle
    private(set) var appsState: TaskState = .idle
    private(set) var lastRun: Date?

    var isRunning: Bool { [junkState, filesState, appsState].contains(.running) }

    func run(junk: JunkModel, files: LargeOldModel, apps: UninstallerModel) {
        guard !isRunning else { return }
        junkState = .running; filesState = .running; appsState = .running
        Sound.play(.scanStart)
        junk.scan()
        files.scan()
        apps.load()
        Task {
            while junk.isScanning || files.isScanning || apps.isLoading {
                if !junk.isScanning, junkState == .running { animate { junkState = .done }; Sound.play(.milestone) }
                if !files.isScanning, filesState == .running { animate { filesState = .done }; Sound.play(.milestone) }
                if !apps.isLoading, appsState == .running { animate { appsState = .done }; Sound.play(.milestone) }
                try? await Task.sleep(for: .milliseconds(150))
            }
            animate { junkState = .done; filesState = .done; appsState = .done }
            lastRun = Date()
            Sound.play(.scanComplete)
        }
    }
}
