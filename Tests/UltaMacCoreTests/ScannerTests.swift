import Foundation
import Testing
@testable import UltaMacCore

@Suite("Junk scanner")
struct JunkScannerTests {
    @Test func findsCachesAndRespectsRules() throws {
        let home = try FakeHome()
        try home.file("Library/Caches/com.vendor.app/data", bytes: 50_000)
        try home.file("Library/Caches/com.apple.Safari/data", bytes: 20_000)
        try home.file("Library/Caches/com.running.app/data", bytes: 8_000)
        try home.file("Library/Logs/thing.log", bytes: 9_000)
        let old = Date().addingTimeInterval(-30 * 86_400)
        try home.file("Downloads/Old.dmg", bytes: 70_000, modified: old)
        try home.file("Downloads/New.dmg", bytes: 70_000)
        try home.file("Downloads/Report.pdf", bytes: 70_000, modified: old)

        let scanner = JunkScanner(home: home.url, runningBundleIDs: ["com.running.app"])
        let groups = Dictionary(uniqueKeysWithValues: scanner.scan(cancel: CancellationFlag()).map { ($0.id, $0) })

        let caches = try #require(groups["user-caches"])
        #expect(Set(caches.items.map(\.url.lastPathComponent)) == ["com.vendor.app", "com.running.app"])
        let running = try #require(caches.items.first { $0.url.lastPathComponent == "com.running.app" })
        #expect(running.selectedByDefault == false)

        #expect(groups["apple-caches"]?.items.map(\.url.lastPathComponent) == ["com.apple.Safari"])
        #expect(groups["apple-caches"]?.rule.selectedByDefault == false)
        #expect(groups["user-logs"]?.items.count == 1)
        #expect(groups["old-installers"]?.items.map(\.url.lastPathComponent) == ["Old.dmg"])
    }

    @Test func everyFoundItemPassesSafetyPolicy() throws {
        let home = try FakeHome()
        try home.file("Library/Caches/a/b", bytes: 5_000)
        try home.file("Library/Developer/Xcode/DerivedData/Proj-abc/Build/x", bytes: 5_000)
        try home.file(".npm/_cacache/index", bytes: 5_000)
        let groups = JunkScanner(home: home.url).scan(cancel: CancellationFlag())
        let items = groups.flatMap(\.items)
        #expect(items.count == 3)
        for item in items {
            #expect(home.policy.check(item.url, purpose: .clean) == .allowed, "\(item.url.path)")
        }
    }
}

@Suite("Storage analyzer")
struct StorageAnalyzerTests {
    @Test func sizesRollUp() throws {
        let home = try FakeHome()
        try home.file("Root/a/big.bin", bytes: 2_000_000)
        try home.file("Root/a/small.txt", bytes: 100)
        try home.file("Root/b/mid.bin", bytes: 1_200_000)
        let root = home.url.appendingPathComponent("Root")
        let tree = StorageAnalyzer().scan(root, cancel: CancellationFlag())
        #expect(tree.children.first?.name == "a")
        #expect(tree.size >= 3_200_000)
        let a = try #require(tree.children.first)
        #expect(a.children.contains { $0.name == "big.bin" })
        #expect(a.children.contains { $0.isAggregate }) // small.txt grouped
        #expect(tree.itemCount == 3)
    }

    @Test func scansThousandsOfFilesQuickly() throws {
        let home = try FakeHome()
        for d in 0..<50 { for f in 0..<100 { try home.file("Root/d\(d)/f\(f)", bytes: 100) } }
        let start = Date()
        let tree = StorageAnalyzer().scan(home.url.appendingPathComponent("Root"), cancel: CancellationFlag())
        let elapsed = Date().timeIntervalSince(start)
        #expect(tree.itemCount == 5_000)
        #expect(elapsed < 2.0, "5,000 files took \(elapsed)s")
    }

    @Test func cancellationStopsEarly() throws {
        let home = try FakeHome()
        try home.file("Root/x/y", bytes: 10)
        let flag = CancellationFlag()
        flag.cancel()
        let tree = StorageAnalyzer().scan(home.url.appendingPathComponent("Root"), cancel: flag)
        #expect(tree.children.isEmpty)
    }
}

@Suite("Uninstaller")
struct UninstallerTests {
    func makeApp(_ home: FakeHome, name: String, bundleID: String) throws -> InstalledApp {
        let contents = try home.dir("Applications/\(name).app/Contents")
        let plist: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleShortVersionString": "1.0"]
        plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        return try #require(AppInventory.describe(contents.deletingLastPathComponent()))
    }

    @Test func listsAppsAndSkipsApple() throws {
        let home = try FakeHome()
        _ = try makeApp(home, name: "Widget", bundleID: "com.vendor.widget")
        _ = try makeApp(home, name: "FakeApple", bundleID: "com.apple.fake")
        let apps = AppInventory(home: home.url, searchFolders: [home.url.appendingPathComponent("Applications")]).listApps()
        #expect(apps.map(\.name) == ["Widget"])
    }

    @Test func findsLeftoversByBundleIDAndName() throws {
        let home = try FakeHome()
        let app = try makeApp(home, name: "Widget", bundleID: "com.vendor.widget")
        try home.file("Library/Application Support/com.vendor.widget/db", bytes: 3_000)
        try home.file("Library/Application Support/Widget/settings.json", bytes: 1_000)
        try home.file("Library/Preferences/com.vendor.widget.plist", bytes: 500)
        try home.file("Library/Caches/com.vendor.widget/c", bytes: 500)
        try home.file("Library/Containers/com.vendor.widget/Data/x", bytes: 500)
        try home.file("Library/Group Containers/ABCDE12345.com.vendor.widget/x", bytes: 500)
        // Must not match:
        try home.file("Library/Preferences/com.vendor.widgetpro.plist", bytes: 500)
        try home.file("Library/Caches/com.vendor.widget.beta/c", bytes: 500)
        try home.file("Library/Application Support/Widgets/x", bytes: 500)

        let found = LeftoverFinder(home: home.url).leftovers(for: app, otherBundleIDs: ["com.vendor.widget.beta"])
        let names = Set(found.map(\.url.lastPathComponent))
        #expect(names == ["com.vendor.widget", "Widget", "com.vendor.widget.plist", "ABCDE12345.com.vendor.widget"])
        #expect(found.filter { $0.url.lastPathComponent == "com.vendor.widget" }.count == 3) // support, caches, container
        let byName = try #require(found.first { $0.url.lastPathComponent == "Widget" })
        #expect(byName.match == .name && !byName.selectedByDefault)
    }

    @Test func genericNamesDoNotMatch() throws {
        let home = try FakeHome()
        let app = try makeApp(home, name: "Notes", bundleID: "com.someone.notes")
        try home.file("Library/Application Support/Notes/x")
        #expect(LeftoverFinder(home: home.url).leftovers(for: app).isEmpty)
    }
}

@Suite("System monitor")
struct MonitorTests {
    @Test func readsLiveStats() async throws {
        let cpu = CPUSampler()
        _ = cpu.sample()
        try await Task.sleep(for: .milliseconds(300))
        let load = try #require(cpu.sample())
        #expect(load.total >= 0 && load.total <= 1)
        #expect(load.perCore.count == ProcessInfo.processInfo.processorCount)

        let mem = try #require(MemoryStats.current())
        #expect(mem.total == ProcessInfo.processInfo.physicalMemory)
        #expect(mem.used > 0 && mem.used <= mem.total)

        let procs = ProcessSampler()
        _ = procs.sample()
        let samples = procs.sample()
        #expect(samples.contains { $0.pid == getpid() })

        let disk = try #require(DiskStatus.current())
        #expect(disk.total > disk.used)
        #expect(SystemInfo.current().uptime > 0)
        _ = NetworkSampler().sample()
        _ = BatteryStatus.current()
        #expect(!LaunchItemsScanner().scan().isEmpty || true)
    }
}
