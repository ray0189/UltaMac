import Foundation
@testable import UltaMacCore

/// A throwaway fake home folder in the temporary directory.
final class FakeHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UltaMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Clear flags we may have set so cleanup succeeds.
        if let e = FileManager.default.enumerator(atPath: url.path) {
            for case let rel as String in e { chflags(url.appendingPathComponent(rel).path, 0) }
        }
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ rel: String, bytes: Int = 4096, modified: Date? = nil) throws -> URL {
        let f = url.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: f)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: f.path)
        }
        return f
    }

    @discardableResult
    func dir(_ rel: String) throws -> URL {
        let d = url.appendingPathComponent(rel, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    var policy: SafetyPolicy { SafetyPolicy(home: url, ownBundlePath: nil) }
}
