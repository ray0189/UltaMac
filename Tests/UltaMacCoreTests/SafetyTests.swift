import Foundation
import Testing
@testable import UltaMacCore

@Suite("Safety policy")
struct SafetyPolicyTests {
    @Test func allowsCacheContents() throws {
        let home = try FakeHome()
        let item = try home.file("Library/Caches/com.vendor.app/blob")
        #expect(home.policy.check(item.deletingLastPathComponent(), purpose: .clean) == .allowed)
    }

    @Test func refusesProtectedContainers() throws {
        let home = try FakeHome()
        let caches = try home.dir("Library/Caches")
        try home.dir("Documents")
        #expect(!home.policy.check(caches, purpose: .clean).isAllowed)
        #expect(!home.policy.check(home.url.appendingPathComponent("Documents"), purpose: .clean).isAllowed)
        #expect(!home.policy.check(home.url, purpose: .clean).isAllowed)
    }

    @Test func refusesSensitiveSubtrees() throws {
        let home = try FakeHome()
        let key = try home.file("Library/Keychains/login.keychain-db")
        let ssh = try home.file(".ssh/id_ed25519")
        let photos = try home.file("Pictures/Photos Library.photoslibrary/database/x")
        for url in [key, ssh, photos] {
            #expect(!home.policy.check(url, purpose: .clean).isAllowed, "\(url.path)")
        }
    }

    @Test func refusesSystemPaths() {
        let policy = SafetyPolicy(home: URL(fileURLWithPath: NSHomeDirectory()), ownBundlePath: nil)
        for path in ["/System/Library/CoreServices/Finder.app", "/usr/bin/true", "/bin/ls", "/etc/hosts",
                     "/Library/Preferences", "/Applications/Safari.app"] {
            #expect(!policy.check(URL(fileURLWithPath: path), purpose: .clean).isAllowed, "\(path)")
        }
    }

    @Test func refusesLockedFilesWithoutUnlocking() throws {
        let home = try FakeHome()
        let locked = try home.file("Library/Caches/locked.bin")
        #expect(chflags(locked.path, 0x2) == 0) // UF_IMMUTABLE
        #expect(!home.policy.check(locked, purpose: .clean).isAllowed)
        var st = stat()
        lstat(locked.path, &st)
        #expect(st.st_flags & 0x2 != 0, "flag must be left untouched")
    }

    @Test func refusesDotDotAndMissing() throws {
        let home = try FakeHome()
        try home.dir("Library/Caches/x")
        let sneaky = URL(fileURLWithPath: home.url.path + "/Library/Caches/x/../../..")
        #expect(!home.policy.check(sneaky, purpose: .clean).isAllowed)
        #expect(!home.policy.check(home.url.appendingPathComponent("nope"), purpose: .clean).isAllowed)
    }

    @Test func symlinkIsJudgedByItsOwnLocation() throws {
        let home = try FakeHome()
        let cacheDir = try home.dir("Library/Caches/app")
        let link = cacheDir.appendingPathComponent("link-to-docs")
        try home.dir("Documents")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.url.appendingPathComponent("Documents"))
        // The link itself lives in a cache folder, so removing *the link* is allowed.
        #expect(home.policy.check(link, purpose: .clean) == .allowed)
    }

    @Test func honoursUserExclusions() throws {
        let home = try FakeHome()
        let keep = try home.dir("Library/Caches/keep-me")
        var policy = home.policy
        policy.userExclusions = [keep.path]
        #expect(!policy.check(keep, purpose: .clean).isAllowed)
    }

    @Test func appBundlesOnlyForUninstall() throws {
        let home = try FakeHome()
        let app = try home.dir("Applications/Thing.app/Contents")
        let bundle = app.deletingLastPathComponent()
        #expect(home.policy.check(bundle, purpose: .uninstallApp) == .allowed)
    }
}

@Suite("File remover")
struct FileRemoverTests {
    @Test func permanentDeleteRemovesOnlyAllowedItems() throws {
        let home = try FakeHome()
        let junk = try home.file("Library/Caches/app/blob", bytes: 10_000)
        let doc = try home.file("Library/Keychains/k")
        let remover = FileRemover(policy: home.policy)
        let report = remover.remove([RemovalRequest(url: junk.deletingLastPathComponent(), size: 10_000),
                                     RemovalRequest(url: doc, size: 1)],
                                    mode: .deletePermanently)
        #expect(report.removed.count == 1)
        #expect(report.failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: junk.path))
        #expect(FileManager.default.fileExists(atPath: doc.path))
        #expect(report.bytesRemoved == 10_000)
    }

    @Test func lockedFileIsReportedNotForced() throws {
        let home = try FakeHome()
        let locked = try home.file("Library/Caches/l")
        chflags(locked.path, 0x2)
        let report = FileRemover(policy: home.policy).remove([RemovalRequest(url: locked, size: 1)], mode: .deletePermanently)
        #expect(report.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: locked.path))
    }
}
