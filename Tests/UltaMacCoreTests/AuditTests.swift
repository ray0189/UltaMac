import Foundation
import Testing
@testable import UltaMacCore

@Suite("Audit log & mixed removal")
struct AuditTests {
    @Test func permanentOnlyAppliesPerItemNotToWholeBatch() throws {
        let home = try FakeHome()
        let cache = try home.file("Library/Caches/app/blob", bytes: 1_000).deletingLastPathComponent()
        let trashed = try home.file(".Trash/old.txt", bytes: 1_000)
        let log = AuditLog(url: home.url.appendingPathComponent("audit.jsonl"))
        let remover = FileRemover(policy: home.policy, auditLog: log)
        let report = remover.remove([RemovalRequest(url: cache, size: 1_000),
                                     RemovalRequest(url: trashed, size: 1_000, permanentOnly: true)],
                                    mode: .moveToTrash, context: "Test")
        // The cache goes through the Trash path (may fail in a temp dir without a Trash
        // volume; either way it must NOT be permanently deleted). The Trash item is deleted.
        #expect(report.deleted == [trashed])
        #expect(!report.deleted.contains(cache))
        #expect(!FileManager.default.fileExists(atPath: trashed.path))

        let entries = log.recent()
        #expect(entries.count == 1)
        #expect(entries[0].context == "Test")
        #expect(entries[0].items.contains { $0.path == trashed.path && $0.permanent })
    }

    @Test func refusalsAreLoggedToo() throws {
        let home = try FakeHome()
        let key = try home.file("Library/Keychains/login.keychain-db")
        let log = AuditLog(url: home.url.appendingPathComponent("audit.jsonl"))
        _ = FileRemover(policy: home.policy, auditLog: log).remove([RemovalRequest(url: key, size: 1)], mode: .deletePermanently)
        #expect(log.recent().first?.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: key.path))
    }

    @Test func everyBuiltInRuleIsDocumented() {
        for rule in JunkRules.builtIn {
            #expect(!rule.consequence.isEmpty, "\(rule.id)")
            if rule.risk == .review { #expect(!rule.autoCleanAllowed, "\(rule.id) must not auto-clean") }
            if rule.permanentOnly { #expect(!rule.selectedByDefault, "\(rule.id)") }
        }
        #expect(Set(JunkRules.builtIn.map(\.id)).count == JunkRules.builtIn.count)
    }
}
