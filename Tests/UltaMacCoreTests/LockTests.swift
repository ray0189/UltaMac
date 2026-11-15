import Foundation
import Testing
@testable import UltaMacCore

/// Uses real ACLs (`chmod +a`) on files in a temporary folder, the same kind of lock found on
/// ~/Pictures on the developer's Mac.
@Suite("Removal locks")
struct LockTests {
    func lock(_ url: URL, _ rule: String) throws {
        let r = ProcessRunner.run("/bin/chmod", ["+a", rule, url.path])
        try #require(r.succeeded, "chmod +a failed: \(r.stderr)")
    }

    @Test func unlockedFileHasNoLock() throws {
        let home = try FakeHome()
        let f = try home.file("Documents/free.bin")
        #expect(RemovalLock.check(f) == nil)
    }

    @Test func detectsItemDenyDelete() throws {
        let home = try FakeHome()
        let f = try home.file("Pictures/locked.ipsw", bytes: 2_000)
        try lock(f, "everyone deny delete")
        #expect(RemovalLock.check(f) == .itemACL)
    }

    @Test func detectsFolderDenyDeleteChild() throws {
        let home = try FakeHome()
        let f = try home.file("Pictures/in-locked-folder.bin")
        try lock(f.deletingLastPathComponent(), "everyone deny delete_child")
        #expect(RemovalLock.check(f) == .folderACL("Pictures"))
    }

    @Test func removerReportsLockClearlyAndLeavesFile() throws {
        let home = try FakeHome()
        let f = try home.file("Downloads/big.ipsw", bytes: 5_000)
        try lock(f, "everyone deny delete")
        for mode in RemovalMode.allCases {
            let report = FileRemover(policy: home.policy).remove([RemovalRequest(url: f, size: 5_000)], mode: mode)
            #expect(report.removed.isEmpty)
            let reason = try #require(report.failures.first?.reason)
            #expect(reason.contains("access rule"))
            #expect(!reason.contains("Full Disk Access"), "must not blame Full Disk Access for an ACL lock")
        }
        #expect(FileManager.default.fileExists(atPath: f.path))
        // The lock itself is untouched.
        #expect(RemovalLock.check(f) == .itemACL)
    }

    @Test func scannersFlagLockedItems() throws {
        let home = try FakeHome()
        let old = Date().addingTimeInterval(-400 * 86_400)
        let locked = try home.file("Documents/locked.zip", bytes: 2_000_000, modified: old)
        try home.file("Documents/free.zip", bytes: 2_000_000, modified: old)
        try lock(locked, "everyone deny delete")
        let entries = LargeOldFinder(home: home.url, largeThreshold: 10_000_000, oldMinimumSize: 1_000_000)
            .scan(cancel: CancellationFlag())
        #expect(entries.first { $0.url.lastPathComponent == "locked.zip" }?.lock == .itemACL)
        #expect(entries.first { $0.url.lastPathComponent == "free.zip" }?.lock == nil)

        let cache = try home.file("Library/Caches/com.locked.app/data", bytes: 4_000).deletingLastPathComponent()
        try lock(cache, "everyone deny delete")
        let groups = JunkScanner(home: home.url, rules: JunkRules.builtIn.filter { $0.id == "user-caches" }).scan(cancel: CancellationFlag())
        let item = try #require(groups.first?.items.first)
        #expect(item.note == "Locked")
        #expect(!item.selectedByDefault)
    }
}
