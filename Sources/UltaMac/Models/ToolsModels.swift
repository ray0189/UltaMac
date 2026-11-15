import SwiftUI
import UltaMacCore

// MARK: - Disks (shared by Disk Manager and the USB Toolkit)

@MainActor @Observable
final class DisksModel {
    private(set) var disks: [DiskDevice] = []
    private(set) var isLoading = false
    var message: String?
    private var poller: Task<Void, Never>?
    private var watchers = 0

    var external: [DiskDevice] { disks.filter { !$0.isInternal && !$0.isBootDisk && (!$0.isVirtual || UserDefaults.standard.bool(forKey: "allowDiskImageTargets")) } }

    func refresh() {
        isLoading = true
        Task {
            let list = await runInBackground { DiskInventory.list() }
            let newExternal = Set(list.filter { !$0.isInternal && !$0.isVirtual }.map(\.fingerprint))
            let oldExternal = Set(disks.filter { !$0.isInternal && !$0.isVirtual }.map(\.fingerprint))
            if !disks.isEmpty, !newExternal.subtracting(oldExternal).isEmpty { Sound.play(.usbConnect) }
            animate { disks = list; isLoading = false }
        }
    }

    /// Polls while a disk screen is visible (cheap: two diskutil calls every 3 s).
    func watch() {
        watchers += 1
        guard poller == nil else { return }
        refresh()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.refresh()
            }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { poller?.cancel(); poller = nil }
    }

    func run(_ title: String, _ op: @escaping @Sendable () -> ProcessResult) {
        Task {
            let r = await runInBackground(op)
            message = r.succeeded ? "\(title): done." : "\(title) failed: \(r.stderr.isEmpty ? r.output : r.stderr)"
            Sound.play(r.succeeded ? .success : .error)
            refresh()
        }
    }
}

// MARK: - ISO Library

struct LibraryEntry: Codable, Identifiable, Hashable {
    var id: String { path }
    var path: String
    var info: ImageInfo
    var sha256: String?
    var expectedSHA256: String?
    var added: Date

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var checksumMatches: Bool? {
        guard let sha256, let expected = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !expected.isEmpty else { return nil }
        return sha256 == expected
    }
}

@MainActor @Observable
final class ImageLibraryModel {
    private(set) var entries: [LibraryEntry] = []
    var selection: LibraryEntry.ID?
    var search = ""
    private(set) var hashing: [String: Double] = [:]
    private(set) var inspecting = Set<String>()
    private var cancels: [String: CancellationFlag] = [:]

    private let storeURL = AuditLog.defaultURL.deletingLastPathComponent().appendingPathComponent("image-library.json")

    init() { load() }

    var visible: [LibraryEntry] {
        entries.filter { search.isEmpty || $0.info.url.lastPathComponent.localizedCaseInsensitiveContains(search) || $0.info.os.rawValue.localizedCaseInsensitiveContains(search) }
    }

    func duplicates(of e: LibraryEntry) -> [LibraryEntry] {
        guard let h = e.sha256 else { return [] }
        return entries.filter { $0.id != e.id && $0.sha256 == h }
    }

    func importImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = []
        panel.message = "Choose ISO, IMG or macOS installer files"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url) }
    }

    func add(_ url: URL) {
        guard !entries.contains(where: { $0.path == url.path }) else { selection = url.path; return }
        inspecting.insert(url.path)
        Task {
            let info = await runInBackground { ImageInspector.inspect(url) }
            animate {
                entries.append(LibraryEntry(path: url.path, info: info, sha256: nil, expectedSHA256: nil, added: Date()))
                inspecting.remove(url.path)
                selection = url.path
            }
            save()
        }
    }

    func remove(_ e: LibraryEntry) {
        animate { entries.removeAll { $0.id == e.id } }
        save()
    }

    func computeHash(_ e: LibraryEntry) {
        guard hashing[e.id] == nil, e.info.format != .macInstaller else { return }
        let flag = CancellationFlag()
        cancels[e.id] = flag
        hashing[e.id] = 0
        let id = e.id, url = e.url
        Task {
            let hash = await runInBackground {
                ImageInspector.sha256(url, cancel: flag) { f in Task { @MainActor in self.hashing[id] = f } }
            }
            hashing[id] = nil
            if let hash, let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].sha256 = hash
                Sound.play(entries[i].checksumMatches == false ? .warning : .verifySuccess)
                save()
            }
        }
    }

    func cancelHash(_ e: LibraryEntry) { cancels[e.id]?.cancel(); hashing[e.id] = nil }

    func setExpected(_ value: String, for e: LibraryEntry) {
        guard let i = entries.firstIndex(where: { $0.id == e.id }) else { return }
        entries[i].expectedSHA256 = value
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        entries = (try? d.decode([LibraryEntry].self, from: data)) ?? []
    }

    private func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(entries).write(to: storeURL, options: .atomic)
    }
}

// MARK: - USB wizard

@MainActor @Observable
final class USBWizardModel {
    enum Step: Int, CaseIterable {
        case image, inspect, target, check, confirm, write, done
        var title: String {
            switch self {
            case .image: "Image"
            case .inspect: "Inspect"
            case .target: "Drive"
            case .check: "Check"
            case .confirm: "Confirm"
            case .write: "Write"
            case .done: "Done"
            }
        }
    }

    var step: Step = .image
    var imageURL: URL?
    private(set) var info: ImageInfo?
    private(set) var isInspecting = false
    var target: DiskDevice?
    var confirmText = ""
    private(set) var progress: WriteProgress?
    private(set) var result: Result<WriteResult, Error>?
    private var cancel = CancellationFlag()

    var allowDiskImages: Bool { UserDefaults.standard.bool(forKey: "allowDiskImageTargets") }
    var gate: DiskSafetyGate { DiskSafetyGate(allowDiskImages: allowDiskImages) }

    var requiredBytes: Int64 {
        guard let info else { return 0 }
        return info.workflow == .macInstaller ? info.size + 1_000_000_000 : info.size
    }

    func reset() {
        animate { step = .image; imageURL = nil; info = nil; target = nil; confirmText = ""; progress = nil; result = nil }
    }

    func choose(_ url: URL) {
        imageURL = url
        info = nil
        isInspecting = true
        animate { step = .inspect }
        Task {
            let i = await runInBackground { ImageInspector.inspect(url) }
            animate { info = i; isInspecting = false }
        }
    }

    func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose an ISO/IMG file or an “Install macOS” app"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        if panel.runModal() == .OK, let url = panel.url { choose(url) }
    }

    static func localInstallers() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Install macOS") && $0.pathExtension == "app" }
    }

    /// All problems for the current image + target, blocking ones first.
    var problems: [DiskSafetyGate.Problem] {
        guard let info else { return [] }
        var list: [DiskSafetyGate.Problem] = []
        if info.workflow == .unsupported {
            list.append(.init(message: "This image can't be written to a bootable USB: \(info.notes.first ?? info.format.rawValue)", blocking: true))
        }
        if info.workflow == .windows {
            list += WindowsMedia.preflight(info).map { .init(message: $0, blocking: true) }
        }
        if let target { list += gate.evaluate(target, requiredBytes: requiredBytes) }
        return list.sorted { $0.blocking && !$1.blocking }
    }

    var canWrite: Bool { target != nil && !problems.contains(where: \.blocking) }
    var confirmationPhrase: String { "ERASE \(target?.bsdName.uppercased() ?? "")" }

    func start() {
        guard let info, let target, let url = imageURL, canWrite, confirmText == confirmationPhrase else { return }
        cancel = CancellationFlag()
        let flag = cancel, gate = gate
        animate { step = .write; result = nil; progress = nil }
        Sound.play(.writeStart)
        Task {
            let outcome: Result<WriteResult, Error> = await runInBackground {
                let report: @Sendable (WriteProgress) -> Void = { p in Task { @MainActor in self.progress = p } }
                do {
                    switch info.workflow {
                    case .raw: return .success(try RawImageWriter.write(image: url, to: target, gate: gate, cancel: flag, progress: report))
                    case .macInstaller: return .success(try MacInstallerMedia.create(installer: url, on: target, gate: gate, cancel: flag, progress: report))
                    case .windows: return .success(try WindowsMedia.create(iso: url, info: info, on: target, gate: gate, cancel: flag, progress: report))
                    case .unsupported: return .failure(DiskWriteError.gate("Unsupported image."))
                    }
                } catch { return .failure(error) }
            }
            animate { result = outcome; step = .done }
            switch outcome {
            case .success: Sound.play(.writeComplete); try? await Task.sleep(for: .milliseconds(900)); Sound.play(.verifySuccess)
            case .failure: Sound.play(.error)
            }
        }
    }

    func stop() { cancel.cancel() }
}

// MARK: - Maintenance

@MainActor @Observable
final class MaintenanceModel {
    struct Run { var running = true; var lines: [String] = []; var result: MaintenanceResult?; var started = Date() }
    private(set) var runs: [String: Run] = [:]
    private var cancels: [String: CancellationFlag] = [:]

    func run(_ task: MaintenanceTask) {
        let flag = CancellationFlag()
        cancels[task.id] = flag
        runs[task.id] = Run()
        let id = task.id
        Task {
            let r = await runInBackground {
                MaintenanceRunner.run(task, cancel: flag) { line in
                    Task { @MainActor in
                        self.runs[id]?.lines.append(line)
                        if (self.runs[id]?.lines.count ?? 0) > 400 { self.runs[id]?.lines.removeFirst() }
                    }
                }
            }
            runs[id]?.running = false
            runs[id]?.result = r
            Sound.play(r.succeeded ? .success : .warning)
        }
    }

    func cancel(_ task: MaintenanceTask) { cancels[task.id]?.cancel() }
}
