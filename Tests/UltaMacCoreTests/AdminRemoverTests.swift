import Foundation
import Testing
@testable import UltaMacCore

/// The administrator remover's script is run here without the password prompt (a normal user
/// can't bypass a lock), which exercises argument quoting, Trash naming and ownership handling.
@Suite("Administrator remover")
struct AdminRemoverTests {
    @Test func movesAwkwardNamesToTrashWithoutShellInterpretation() throws {
        let home = try FakeHome()
        let trash = try home.dir(".Trash")
        let names = ["it's a \"test\".bin", "$(touch PWNED) ; rm -rf x.bin", "spaces and\ttab.bin"]
        let files = try names.map { try home.file("Downloads/\($0)", bytes: 1_000) }
        try home.file(".Trash/\(names[0])", bytes: 10)   // forces "… 2" naming
        let remover = AdminRemover(policy: home.policy, auditLog: nil, useAdministratorPrivileges: false, trashDirectory: trash)
        let report = remover.remove(files.map { RemovalRequest(url: $0, size: 1_000) }, mode: .moveToTrash)
        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(report.trashed.count == 3)
        for f in files { #expect(!FileManager.default.fileExists(atPath: f.path)) }
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("it's a \"test\" 2.bin").path))
        #expect(!FileManager.default.fileExists(atPath: home.url.appendingPathComponent("Downloads/PWNED").path))
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/PWNED"))
    }

    @Test func clearsAccessRulesOnTrashedItem() throws {
        let home = try FakeHome()
        let trash = try home.dir(".Trash")
        let f = try home.file("Pictures/rule.bin")
        // An allow rule the owner may add and remove; the script must leave the trashed copy rule-free.
        try #require(ProcessRunner.run("/bin/chmod", ["+a", "everyone allow read", f.path]).succeeded)
        let remover = AdminRemover(policy: home.policy, auditLog: nil, useAdministratorPrivileges: false, trashDirectory: trash)
        let report = remover.remove([RemovalRequest(url: f, size: 4096)], mode: .moveToTrash)
        #expect(report.trashed == [f])
        let moved = trash.appendingPathComponent("rule.bin")
        let acl = ProcessRunner.run("/bin/ls", ["-le", moved.path]).output
        #expect(!acl.contains("everyone"))
    }

    @Test func permanentModeDeletes() throws {
        let home = try FakeHome()
        let d = try home.dir("Library/Caches/com.example.big")
        try home.file("Library/Caches/com.example.big/a/b.bin")
        let remover = AdminRemover(policy: home.policy, auditLog: nil, useAdministratorPrivileges: false, trashDirectory: try home.dir(".Trash"))
        let report = remover.remove([RemovalRequest(url: d, size: 4096)], mode: .deletePermanently)
        #expect(report.deleted == [d])
        #expect(!FileManager.default.fileExists(atPath: d.path))
    }

    @Test func stillRefusesWhatThePolicyDenies() throws {
        let home = try FakeHome()
        let keychain = try home.file("Library/Keychains/login.keychain-db")
        let remover = AdminRemover(policy: home.policy, auditLog: nil, useAdministratorPrivileges: false, trashDirectory: try home.dir(".Trash"))
        let report = remover.remove([RemovalRequest(url: keychain, size: 1)], mode: .moveToTrash)
        #expect(report.removed.isEmpty)
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: keychain.path))
    }

    @Test func lockFailuresAreMarkedRetryableButPolicyDenialsAreNot() throws {
        let home = try FakeHome()
        let locked = try home.file("Pictures/locked.bin")
        try #require(ProcessRunner.run("/bin/chmod", ["+a", "everyone deny delete", locked.path]).succeeded)
        let keychain = try home.file("Library/Keychains/login.keychain-db")
        let report = FileRemover(policy: home.policy).remove([RemovalRequest(url: locked, size: 1), RemovalRequest(url: keychain, size: 1)], mode: .moveToTrash)
        #expect(report.adminRetryable.map(\.url) == [locked])
        let merged = report.merging(admin: RemovalReport(mode: .moveToTrash))
        #expect(merged.failures.count == 2)
    }
}
