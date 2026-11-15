import Foundation

public struct JunkItem: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let ruleID: String
    public let selectedByDefault: Bool
    public let note: String?
    public var modified: Date? = nil
}

public struct JunkGroup: Sendable, Identifiable {
    public var id: String { rule.id }
    public let rule: JunkRule
    public var items: [JunkItem]
    /// Set when the location could not be read (e.g. missing Full Disk Access).
    public var accessProblem: String?

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

public struct JunkScanner: Sendable {
    public let home: URL
    public let rules: [JunkRule]
    public var runningBundleIDs: Set<String>
    public var now: Date

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                rules: [JunkRule] = JunkRules.builtIn,
                runningBundleIDs: Set<String> = [],
                now: Date = Date()) {
        self.home = home
        self.rules = rules
        self.runningBundleIDs = runningBundleIDs
        self.now = now
    }

    public func scan(cancel: CancellationFlag,
                     progress: (@Sendable (String) -> Void)? = nil) -> [JunkGroup] {
        var groups: [JunkGroup] = []
        for rule in rules {
            if cancel.isCancelled { break }
            progress?(rule.title)
            groups.append(scan(rule: rule, cancel: cancel))
        }
        return groups
    }

    func scan(rule: JunkRule, cancel: CancellationFlag) -> JunkGroup {
        let fm = FileManager.default
        var group = JunkGroup(rule: rule, items: [], accessProblem: nil)
        switch rule.target {
        case .folder(let rel):
            let url = home.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return group }
            let size = SizeCalculator.allocatedSize(of: url, cancel: cancel)
            if size > 0 {
                group.items.append(JunkItem(url: url, size: size, ruleID: rule.id,
                                            selectedByDefault: rule.selectedByDefault, note: nil,
                                            modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate))
            }
        case .contentsOf(let rel):
            let folder = home.appendingPathComponent(rel)
            guard fm.fileExists(atPath: folder.path) else { return group }
            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
            } catch {
                group.accessProblem = "Couldn't read \(rel). Grant Full Disk Access in System Settings › Privacy & Security."
                return group
            }
            for entry in entries {
                if cancel.isCancelled { break }
                let name = entry.lastPathComponent
                if name == ".DS_Store" || name == ".localized" { continue }
                if let prefix = rule.namePrefix, !name.hasPrefix(prefix) { continue }
                if rule.excludedPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
                if let exts = rule.extensions, !exts.contains(entry.pathExtension.lowercased()) { continue }
                if let days = rule.minimumAgeDays {
                    let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? now
                    if now.timeIntervalSince(modified) < Double(days) * 86_400 { continue }
                }
                let size = SizeCalculator.allocatedSize(of: entry, cancel: cancel)
                guard size > 0 else { continue }
                var selected = rule.selectedByDefault
                var note: String? = nil
                if let lock = RemovalLock.check(entry) {
                    selected = false
                    note = lock.shortLabel
                }
                if rule.protectRunningApps {
                    let base = name.hasSuffix(".savedState") ? String(name.dropLast(".savedState".count)) : name
                    if runningBundleIDs.contains(base) {
                        selected = false
                        note = "App is running"
                    }
                }
                group.items.append(JunkItem(url: entry, size: size, ruleID: rule.id,
                                            selectedByDefault: selected, note: note,
                                            modified: (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate))
            }
            group.items.sort { $0.size > $1.size }
        }
        return group
    }
}
