import Foundation
import Testing
@testable import UltaMacCore

@Suite("Large & old files")
struct LargeOldTests {
    @Test func findsLargeAndOldSkippingLibrary() throws {
        let home = try FakeHome()
        let old = Date().addingTimeInterval(-500 * 86_400)
        try home.file("Movies/big.mov", bytes: 3_000_000)
        try home.file("Documents/ancient.zip", bytes: 1_500_000, modified: old)
        try home.file("Documents/recent.zip", bytes: 1_500_000)
        try home.file("Library/Caches/huge.bin", bytes: 5_000_000)
        try home.file(".hidden/huge.bin", bytes: 5_000_000)
        let finder = LargeOldFinder(home: home.url, largeThreshold: 2_000_000, oldMinimumSize: 1_000_000)
        let names = Set(finder.scan(cancel: CancellationFlag()).map(\.url.lastPathComponent))
        #expect(names == ["big.mov", "ancient.zip"])
    }
}

@Suite("Duplicates")
struct DuplicateTests {
    @Test func groupsIdenticalContentOnly() throws {
        let home = try FakeHome()
        let a = try home.file("Documents/a.bin", bytes: 2_000_000)
        try FileManager.default.copyItem(at: a, to: home.url.appendingPathComponent("Downloads/a copy.bin").also { try? FileManager.default.createDirectory(at: $0.deletingLastPathComponent(), withIntermediateDirectories: true) })
        // Same size, different content (last byte differs).
        var data = Data(repeating: 0x41, count: 2_000_000); data[1_999_999] = 0x42
        try data.write(to: home.url.appendingPathComponent("Documents/b.bin"))
        // Hard link: same file, must not count.
        try FileManager.default.linkItem(at: a, to: home.url.appendingPathComponent("Documents/a-link.bin"))
        let groups = DuplicateFinder(home: home.url, minimumSize: 1_000_000).scan(cancel: CancellationFlag())
        #expect(groups.count == 1)
        let names = Set(groups[0].files.map(\.url.lastPathComponent))
        #expect(names.contains("a copy.bin") && !names.contains("b.bin") && groups[0].files.count == 2)
        #expect(groups[0].wasted == groups[0].size)
    }
}

@Suite("App insights")
struct AppInsightTests {
    @Test func readsArchitectureOfRealBinaries() {
        // /usr/bin/true is a universal (or arm64) system binary on Apple Silicon Macs.
        let arch = AppArchitecture.of(executable: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(arch == .universal || arch == .appleSilicon)
        #expect(AppArchitecture.of(executable: URL(fileURLWithPath: "/etc/hosts")) == .unknown)
    }

    @Test func unusedLogic() {
        let app = InstalledApp(url: URL(fileURLWithPath: "/x.app"), name: "x", bundleID: nil, version: nil,
                               isFromAppStore: false, lastUsed: Date().addingTimeInterval(-200 * 86_400))
        #expect(app.isUnused(days: 90))
        #expect(!app.isUnused(days: 365))
    }
}

extension URL {
    func also(_ f: (URL) -> Void) -> URL { f(self); return self }
}

@Suite("Battery")
struct BatteryTests {
    @Test func healthUsesDesignCapacityWhenReported() {
        // On Macs with a battery, capacity values must be found (top-level or nested).
        guard let b = BatteryStatus.current() else { return }
        if let d = b.details, d.designCapacity != nil {
            #expect(d.fullChargeCapacity != nil)
            let h = try! #require(b.healthPercent)
            #expect(h > 30 && h <= 110)
        }
    }

    @Test func memoryUsesBinaryUnits() {
        #expect(ByteFormat.memory(8 * 1_073_741_824) == "8 GB")
    }
}

@Suite("Treemap layout")
struct TreemapTests {
    @Test func areasAreProportionalAndInsideBounds() {
        let values: [Double] = [600, 300, 60, 25, 10, 5]
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
        let rects = TreemapLayout.squarify(values, in: bounds)
        #expect(rects.count == values.count)
        let total = values.reduce(0, +)
        for (v, r) in zip(values, rects) {
            let expected = v / total * 800 * 500
            #expect(abs(Double(r.width * r.height) - expected) < 1, "area for \(v)")
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(r))
        }
        // No two tiles overlap.
        for a in 0..<rects.count { for b in (a + 1)..<rects.count {
            let i = rects[a].intersection(rects[b])
            #expect(i.isNull || i.width * i.height < 0.01)
        } }
    }

    @Test func emptyAndZeroInputs() {
        #expect(TreemapLayout.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(TreemapLayout.squarify([0, 0], in: CGRect(x: 0, y: 0, width: 10, height: 10)) == [.zero, .zero])
    }
}
