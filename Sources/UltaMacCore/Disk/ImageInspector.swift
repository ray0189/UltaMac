import Foundation
import CryptoKit

public struct ImageInfo: Sendable, Hashable, Codable {
    public enum Format: String, Sendable, Codable {
        case hybridISO = "Hybrid ISO (bootable when written raw)"
        case iso9660 = "ISO 9660"
        case udf = "UDF / ISO"
        case rawMBR = "Raw disk image (MBR)"
        case rawGPT = "Raw disk image (GPT)"
        case appleDiskImage = "Apple disk image (DMG)"
        case compressed = "Compressed archive"
        case macInstaller = "macOS installer app"
        case unknown = "Unknown"
    }

    public enum OS: String, Sendable, Codable {
        case macOS, windows = "Windows", ubuntu = "Ubuntu", mint = "Linux Mint", debian = "Debian",
             fedora = "Fedora", raspberryPi = "Raspberry Pi OS", linux = "Linux", unknown = "Unknown"
    }

    public enum Workflow: String, Sendable, Codable {
        case raw = "Raw write + verify"
        case windows = "Windows installer (GPT + FAT32 copy)"
        case macInstaller = "Apple createinstallmedia"
        case unsupported = "Not supported"
    }

    public var url: URL
    public var size: Int64
    public var format: Format
    public var os: OS
    public var label: String?
    public var architectures: [String]
    public var workflow: Workflow
    public var notes: [String]
    /// Windows only: size of sources/install.wim (FAT32 can't hold files ≥ 4 GiB).
    public var installWimSize: Int64?
    public var version: String?
}

public enum ImageInspector {
    public static let fat32Limit: Int64 = 4_294_967_295

    public static func inspect(_ url: URL, mountContents: Bool = true) -> ImageInfo {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        var info = ImageInfo(url: url, size: size, format: .unknown, os: .unknown, label: nil, architectures: [],
                             workflow: .unsupported, notes: [], installWimSize: nil, version: nil)

        if url.pathExtension == "app" { return inspectInstaller(url, info: info) }

        guard let header = readBytes(url, offset: 0, count: 0x9800) else {
            info.notes.append("The file couldn't be read.")
            return info
        }
        func at(_ o: Int, _ s: String) -> Bool {
            let b = Array(s.utf8)
            return header.count >= o + b.count && Array(header[o..<o + b.count]) == b
        }
        let mbr = header.count > 511 && header[510] == 0x55 && header[511] == 0xAA
        let gpt = at(512, "EFI PART")
        let iso = at(0x8001, "CD001")
        let udf = stride(from: 0x8001, to: 0x9801, by: 0x800).contains { at($0, "NSR02") || at($0, "NSR03") }

        if header.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) || header.starts(with: [0x1F, 0x8B])
            || header.starts(with: [0x50, 0x4B, 0x03, 0x04]) || header.starts(with: [0x28, 0xB5, 0x2F, 0xFD])
            || header.starts(with: [0x42, 0x5A, 0x68]) {
            info.format = .compressed
            info.notes.append("Compressed images must be decompressed before writing (for example with Archive Utility or `xz -d`).")
            info.os = guessFromName(url)
            return info
        }
        if let trailer = readBytes(url, offset: max(0, size - 512), count: 4), trailer == Array("koly".utf8) {
            info.format = .appleDiskImage
            info.notes.append("DMG files are mounted on a Mac, not written to USB. To make a macOS installer, use the installer app.")
            return info
        }

        if iso {
            let labelBytes = header[0x8028..<0x8048]
            info.label = String(decoding: labelBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.controlCharacters))
            info.format = mbr ? .hybridISO : (udf ? .udf : .iso9660)
        } else if udf {
            info.format = .udf
        } else if gpt {
            info.format = .rawGPT
        } else if mbr {
            info.format = .rawMBR
        }

        if [.iso9660, .udf, .hybridISO].contains(info.format), mountContents {
            inspectISOContents(&info)
        } else if info.format == .rawMBR || info.format == .rawGPT {
            info.os = guessFromName(url)
            // First MBR partition FAT (0x0B/0x0C/0x0E) with a Pi-style name → Raspberry Pi OS.
            let type1 = header.count > 450 ? header[450] : 0
            if info.os == .unknown, [0x0B, 0x0C, 0x0E].contains(type1), url.lastPathComponent.lowercased().contains("pi") {
                info.os = .raspberryPi
            }
            info.workflow = .raw
            if info.os == .raspberryPi { info.architectures = ["arm64/armhf"] }
        }
        if info.os == .unknown, info.label != nil { info.os = guessFromLabel(info.label!) }
        if info.os == .unknown { info.os = guessFromName(url) }

        switch info.format {
        case .hybridISO:
            if info.os == .windows { info.workflow = .windows } else { info.workflow = .raw }
        case .iso9660, .udf:
            if info.os == .windows {
                info.workflow = .windows
            } else {
                info.workflow = .unsupported
                info.notes.append("This ISO has no hybrid boot record, so writing it raw won't produce a bootable USB.")
            }
        default: break
        }
        if info.workflow == .windows, let wim = info.installWimSize, wim > fat32Limit {
            info.notes.append("install.wim is \(ByteFormat.string(wim)), larger than FAT32's 4 GB limit. It must be split with wimlib-imagex (\(WindowsMedia.wimlibPath() == nil ? "not installed, run `brew install wimlib`" : "found")).")
        }
        return info
    }

    static func inspectInstaller(_ url: URL, info base: ImageInfo) -> ImageInfo {
        var info = base
        info.format = .macInstaller
        info.os = .macOS
        let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        info.label = plist["CFBundleDisplayName"] as? String ?? url.deletingPathExtension().lastPathComponent
        info.version = plist["DTPlatformVersion"] as? String ?? plist["CFBundleShortVersionString"] as? String
        info.size = SizeCalculator.allocatedSize(of: url)
        let cim = url.appendingPathComponent("Contents/Resources/createinstallmedia")
        if FileManager.default.isExecutableFile(atPath: cim.path) {
            info.workflow = .macInstaller
            info.architectures = ["Apple Silicon", "Intel (model-dependent)"]
            info.notes.append("A bootable installer starts Macs that support this macOS version. It is not a DFU or firmware restore.")
        } else {
            info.notes.append("This installer has no createinstallmedia tool. It may be a stub; download the full installer from the App Store or Software Update.")
        }
        return info
    }

    static func inspectISOContents(_ info: inout ImageInfo) {
        let r = ProcessRunner.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen",
                                                       "-mountrandom", NSTemporaryDirectory(), "-plist", info.url.path], timeout: 60)
        guard r.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: r.stdout, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            info.notes.append("Contents couldn't be inspected (the image didn't mount).")
            return
        }
        let mount = entities.compactMap { $0["mount-point"] as? String }.first
        let devs = entities.compactMap { $0["dev-entry"] as? String }
        defer {
            if let dev = devs.min(by: { $0.count < $1.count }) {
                _ = ProcessRunner.run("/usr/bin/hdiutil", ["detach", dev, "-force"], timeout: 30)
            }
        }
        guard let mount else { return }
        let root = URL(fileURLWithPath: mount)
        let fm = FileManager.default
        func exists(_ p: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(p).path) }
        func firstExisting(_ names: [String]) -> URL? { names.map { root.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) } }

        // Architecture from UEFI boot loaders (case varies between distributions).
        let efi = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("EFI/BOOT").path))
            ?? (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("efi/boot").path)) ?? []
        let lower = Set(efi.map { $0.lowercased() })
        if lower.contains("bootx64.efi") { info.architectures.append("x86_64") }
        if lower.contains("bootaa64.efi") { info.architectures.append("arm64") }
        if lower.contains("bootia32.efi") { info.architectures.append("x86 (32-bit UEFI)") }
        if efi.isEmpty { info.notes.append("No UEFI boot loader found; the image may only boot on legacy BIOS PCs.") }

        if let wim = firstExisting(["sources/install.wim", "sources/install.esd", "SOURCES/INSTALL.WIM"]) {
            info.os = .windows
            info.installWimSize = (try? wim.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
            info.notes.append("Windows 11 needs a PC with UEFI, Secure Boot and TPM 2.0. Secure Boot works when booting the Microsoft loader from FAT32.")
            return
        }
        let diskInfo = (try? String(contentsOf: root.appendingPathComponent(".disk/info"), encoding: .utf8)) ?? ""
        if diskInfo.localizedCaseInsensitiveContains("mint") { info.os = .mint }
        else if diskInfo.localizedCaseInsensitiveContains("ubuntu") || exists("casper") { info.os = .ubuntu }
        else if diskInfo.localizedCaseInsensitiveContains("debian") || exists("live") && exists("pool") { info.os = .debian }
        else if exists("images/pxeboot") || exists("LiveOS") { info.os = .fedora }
        else if exists("boot/grub") || exists("isolinux") || !efi.isEmpty { info.os = .linux }
        if !diskInfo.isEmpty { info.version = diskInfo.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func guessFromName(_ url: URL) -> ImageInfo.OS {
        let n = url.lastPathComponent.lowercased()
        if n.contains("raspios") || n.contains("raspberry") { return .raspberryPi }
        if n.contains("win") && (n.contains("10") || n.contains("11")) { return .windows }
        if n.contains("ubuntu") { return .ubuntu }
        if n.contains("mint") { return .mint }
        if n.contains("debian") { return .debian }
        if n.contains("fedora") { return .fedora }
        return .unknown
    }

    static func guessFromLabel(_ label: String) -> ImageInfo.OS {
        let l = label.lowercased()
        if l.hasPrefix("ccc") || l.contains("win") || l.contains("esd-iso") { return .windows }
        if l.contains("ubuntu") { return .ubuntu }
        if l.contains("mint") { return .mint }
        if l.contains("debian") { return .debian }
        if l.contains("fedora") { return .fedora }
        return .unknown
    }

    static func readBytes(_ url: URL, offset: Int64, count: Int) -> [UInt8]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(max(0, offset)))
        return (try? h.read(upToCount: count)).map { [UInt8]($0) }
    }

    /// Streaming SHA-256 with progress (fraction 0…1).
    public static func sha256(_ url: URL, cancel: CancellationFlag, progress: (@Sendable (Double) -> Void)? = nil) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let total = Double((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 1)
        var hasher = SHA256()
        var done = 0.0, lastReport = 0.0
        while true {
            if cancel.isCancelled { return nil }
            guard let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            done += Double(chunk.count)
            if done - lastReport > Double(64 << 20) { lastReport = done; progress?(done / max(total, 1)) }
        }
        progress?(1)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
