import Foundation
import Testing
@testable import UltaMacCore

func fakeDisk(_ bsd: String = "disk9", size: Int64 = 16_000_000_000, isInternal: Bool = false, removable: Bool = true,
              writable: Bool = true, virtual: Bool = false, boot: Bool = false, fingerprint: String = "fp") -> DiskDevice {
    DiskDevice(bsdName: bsd, mediaName: "Test USB", size: size, busProtocol: virtual ? "Disk Image" : "USB",
               isInternal: isInternal, isRemovable: removable, isEjectable: removable, isWritable: writable,
               isVirtual: virtual, scheme: "GUID_partition_scheme", partitions: [], isBootDisk: boot, fingerprint: fingerprint)
}

@Suite("Disk safety gate")
struct DiskSafetyGateTests {
    let gate = DiskSafetyGate()

    @Test func allowsOrdinaryUSB() { #expect(gate.isAllowed(fakeDisk(), requiredBytes: 4_000_000_000)) }
    @Test func blocksBootDisk() { #expect(!gate.isAllowed(fakeDisk(boot: true), requiredBytes: 1)) }
    @Test func blocksInternal() { #expect(!gate.isAllowed(fakeDisk(isInternal: true), requiredBytes: 1)) }
    @Test func blocksNonRemovable() { #expect(!gate.isAllowed(fakeDisk(removable: false), requiredBytes: 1)) }
    @Test func blocksReadOnly() { #expect(!gate.isAllowed(fakeDisk(writable: false), requiredBytes: 1)) }
    @Test func blocksTooSmall() { #expect(!gate.isAllowed(fakeDisk(size: 1_000), requiredBytes: 2_000)) }
    @Test func blocksDiskImagesUnlessExplicitlyAllowed() {
        #expect(!gate.isAllowed(fakeDisk(virtual: true), requiredBytes: 1))
        #expect(DiskSafetyGate(allowDiskImages: true).isAllowed(fakeDisk(virtual: true), requiredBytes: 1))
    }

    @Test func revalidationDetectsReplacementAndRemoval() {
        let selected = fakeDisk(fingerprint: "A")
        #expect(throws: DiskSafetyGate.RevalidationError.changed) {
            try gate.revalidate(selected, requiredBytes: 1) { _ in fakeDisk(fingerprint: "B") }
        }
        #expect(throws: DiskSafetyGate.RevalidationError.disappeared) {
            try gate.revalidate(selected, requiredBytes: 1) { _ in nil }
        }
        #expect(throws: (any Error).self) {
            try gate.revalidate(selected, requiredBytes: 1) { _ in fakeDisk(isInternal: true, fingerprint: "A") }
        }
    }

    @Test func operationLockIsExclusive() {
        let lock = DiskOperationLock()
        #expect(lock.acquire())
        #expect(!lock.acquire())
        lock.release()
        #expect(lock.acquire())
        lock.release()
    }

    @Test func realBootDiskIsProtected() {
        let disks = DiskInventory.list()
        let boot = disks.filter(\.isBootDisk)
        #expect(!boot.isEmpty, "the running system's disk must be identified")
        for d in boot { #expect(!gate.isAllowed(d, requiredBytes: 1)) }
        for d in disks where d.isInternal { #expect(!gate.isAllowed(d, requiredBytes: 1)) }
    }

    @Test func fat32NamesAreSanitised() {
        #expect(DiskEraser.sanitizedName("my usb stick!!", for: .fat32) == "MY USB STICK".prefix(11).description)
        #expect(DiskEraser.sanitizedName("$$$", for: .exFAT) == "UNTITLED")
    }
}

@Suite("Image inspector")
struct ImageInspectorTests {
    func makeImage(_ home: FakeHome, _ name: String, size: Int = 0x10000, edit: (inout [UInt8]) -> Void) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: size)
        edit(&bytes)
        let url = home.url.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func put(_ s: String, at o: Int, _ b: inout [UInt8]) { for (i, c) in s.utf8.enumerated() { b[o + i] = c } }

    @Test func detectsHybridISO() throws {
        let home = try FakeHome()
        let url = try makeImage(home, "distro.iso") { b in
            b[510] = 0x55; b[511] = 0xAA
            put("CD001", at: 0x8001, &b); put("UBUNTU 26.04 LTS", at: 0x8028, &b)
        }
        let info = ImageInspector.inspect(url, mountContents: false)
        #expect(info.format == .hybridISO)
        #expect(info.workflow == .raw)
        #expect(info.os == .ubuntu)
        #expect(info.label == "UBUNTU 26.04 LTS")
    }

    @Test func plainISOIsNotWrittenRaw() throws {
        let home = try FakeHome()
        let url = try makeImage(home, "data.iso") { b in put("CD001", at: 0x8001, &b) }
        let info = ImageInspector.inspect(url, mountContents: false)
        #expect(info.format == .iso9660)
        #expect(info.workflow == .unsupported)
    }

    @Test func detectsGPTAndCompressed() throws {
        let home = try FakeHome()
        let gpt = try makeImage(home, "disk.img") { b in b[510] = 0x55; b[511] = 0xAA; put("EFI PART", at: 512, &b) }
        #expect(ImageInspector.inspect(gpt, mountContents: false).format == .rawGPT)
        let xz = try makeImage(home, "2026-raspios-bookworm-arm64.img.xz") { b in b[0...5] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00] }
        let info = ImageInspector.inspect(xz, mountContents: false)
        #expect(info.format == .compressed)
        #expect(info.os == .raspberryPi)
        #expect(info.workflow == .unsupported)
    }

    @Test func sha256MatchesShasum() throws {
        let home = try FakeHome()
        let f = try home.file("x.bin", bytes: 3_000_000)
        let ours = ImageInspector.sha256(f, cancel: CancellationFlag())
        let theirs = ProcessRunner.run("/usr/bin/shasum", ["-a", "256", f.path]).output.split(separator: " ").first.map(String.init)
        #expect(ours == theirs)
    }
}

/// End-to-end write against a scratch disk image created and destroyed by the test.
/// No physical device is touched.
@Suite("Raw writer (scratch disk image)", .serialized)
struct RawWriterTests {
    @Test func writesAndVerifiesOnScratchImageAndGateBlocksByDefault() throws {
        let home = try FakeHome()
        let dmg = home.url.appendingPathComponent("target.dmg")
        let create = ProcessRunner.run("/usr/bin/hdiutil", ["create", "-size", "8m", "-layout", "NONE", dmg.path])
        try #require(create.succeeded, "hdiutil create: \(create.stderr)")
        let attach = ProcessRunner.run("/usr/bin/hdiutil", ["attach", "-nomount", "-noverify", "-plist", dmg.path])
        try #require(attach.succeeded)
        let plist = try #require(try PropertyListSerialization.propertyList(from: attach.stdout, format: nil) as? [String: Any])
        let dev = try #require(((plist["system-entities"] as? [[String: Any]])?.first?["dev-entry"] as? String))
        defer { _ = ProcessRunner.run("/usr/bin/hdiutil", ["detach", dev, "-force"]) }
        let bsd = String(dev.dropFirst("/dev/".count))
        let disk = try #require(DiskInventory.device(bsd))
        #expect(disk.isVirtual && !disk.isBootDisk && !disk.isInternal)

        // Image: 3 MB of pseudo-random data plus an odd tail (tests sector padding).
        var bytes = [UInt8](repeating: 0, count: 3_000_123)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
        let image = home.url.appendingPathComponent("test.img")
        try Data(bytes).write(to: image)

        // Default gate refuses disk images: nothing is written.
        #expect(throws: (any Error).self) {
            try RawImageWriter.write(image: image, to: disk, gate: DiskSafetyGate(), cancel: CancellationFlag()) { _ in }
        }

        let result = try RawImageWriter.write(image: image, to: disk, gate: DiskSafetyGate(allowDiskImages: true),
                                              cancel: CancellationFlag()) { _ in }
        #expect(result.verified)
        // Independent check: read the device directly and compare the original bytes.
        let h = try #require(FileHandle(forReadingAtPath: disk.rawNode))
        let back = try #require(try h.read(upToCount: 3_000_320))
        try h.close()
        #expect(Array(back.prefix(bytes.count)) == bytes)
    }

    @Test func cancellationStopsBeforeWriting() throws {
        let home = try FakeHome()
        let dmg = home.url.appendingPathComponent("t2.dmg")
        _ = ProcessRunner.run("/usr/bin/hdiutil", ["create", "-size", "4m", "-layout", "NONE", dmg.path])
        let attach = ProcessRunner.run("/usr/bin/hdiutil", ["attach", "-nomount", "-noverify", "-plist", dmg.path])
        let plist = try #require(try PropertyListSerialization.propertyList(from: attach.stdout, format: nil) as? [String: Any])
        let dev = try #require(((plist["system-entities"] as? [[String: Any]])?.first?["dev-entry"] as? String))
        defer { _ = ProcessRunner.run("/usr/bin/hdiutil", ["detach", dev, "-force"]) }
        let disk = try #require(DiskInventory.device(String(dev.dropFirst(5))))
        let image = try home.file("i.img", bytes: 1_000_000)
        let flag = CancellationFlag(); flag.cancel()
        #expect(throws: (any Error).self) {
            try RawImageWriter.write(image: image, to: disk, gate: DiskSafetyGate(allowDiskImages: true), cancel: flag) { _ in }
        }
    }
}

@Suite("Network, maintenance & reports")
struct SystemToolTests {
    @Test func networkSnapshotReadsLocalConfig() {
        let n = NetworkSnapshot.current()
        #expect(!n.hostName.isEmpty)
        #expect(n.interfaces.contains { !$0.ipv4.isEmpty } || n.interfaces.isEmpty == false)
    }

    @Test func reportExcludesIdentifiersByDefault() {
        let r = SystemReport.generate(includeIdentifiers: false)
        #expect(!r.markdown.contains("Serial number"))
        #expect(r.markdown.contains("## Hardware"))
        #expect(!r.json.isEmpty)
    }

    @Test func readOnlyMaintenanceTaskRuns() {
        let task = MaintenanceTask.all.first { $0.id == "spotlight-status" }!
        let r = MaintenanceRunner.run(task, cancel: CancellationFlag())
        #expect(r.succeeded)
        #expect(!MaintenanceTask.all.filter(\.needsAdmin).isEmpty)
    }

    @Test func processRunnerNeverUsesAShell() {
        // Arguments with shell metacharacters are passed literally.
        let r = ProcessRunner.run("/bin/echo", ["a; rm -rf /tmp/x", "$(whoami)"])
        #expect(r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "a; rm -rf /tmp/x $(whoami)")
    }
}
