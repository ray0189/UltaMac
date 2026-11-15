import Foundation

/// Mandatory checks before any destructive disk operation. See docs/Security-Model.md.
public struct DiskSafetyGate: Sendable {
    public struct Problem: Sendable, Hashable {
        public let message: String
        public let blocking: Bool

        public init(message: String, blocking: Bool) {
            self.message = message
            self.blocking = blocking
        }
    }

    /// Only tests and an explicit Expert setting may target attached disk images.
    public var allowDiskImages: Bool

    public init(allowDiskImages: Bool = false) {
        self.allowDiskImages = allowDiskImages
    }

    public func evaluate(_ disk: DiskDevice, requiredBytes: Int64) -> [Problem] {
        var problems: [Problem] = []
        if disk.isBootDisk {
            problems.append(Problem(message: "This disk holds the running macOS system. It can never be erased by UltaMac.", blocking: true))
        }
        if disk.isInternal {
            problems.append(Problem(message: "Internal disks are protected. Only external, removable drives can be written.", blocking: true))
        }
        if disk.isVirtual && !allowDiskImages {
            problems.append(Problem(message: "This is an attached disk image, not a USB drive.", blocking: true))
        }
        if !disk.isVirtual && !(disk.isRemovable || disk.isEjectable) {
            problems.append(Problem(message: "The drive isn't reported as removable or ejectable.", blocking: true))
        }
        if !disk.isWritable {
            problems.append(Problem(message: "The drive is read-only (check its write-protect switch).", blocking: true))
        }
        if disk.size <= 0 {
            problems.append(Problem(message: "The drive's capacity couldn't be read.", blocking: true))
        } else if requiredBytes > disk.size {
            problems.append(Problem(message: "The image needs \(ByteFormat.string(requiredBytes)) but the drive holds \(ByteFormat.string(disk.size)).", blocking: true))
        }
        if disk.size > 2_000_000_000_000 && !disk.isVirtual {
            problems.append(Problem(message: "This drive is larger than 2 TB, which is unusual for a USB stick. Make sure it isn't a backup disk.", blocking: false))
        }
        if !disk.mountPoints.isEmpty {
            problems.append(Problem(message: "Mounted volumes will be unmounted and erased: \(disk.mountPoints.joined(separator: ", ")).", blocking: false))
        }
        return problems
    }

    public func isAllowed(_ disk: DiskDevice, requiredBytes: Int64) -> Bool {
        !evaluate(disk, requiredBytes: requiredBytes).contains { $0.blocking }
    }

    public enum RevalidationError: Error, LocalizedError, Equatable {
        case disappeared
        case changed
        case nowBlocked(String)

        public var errorDescription: String? {
            switch self {
            case .disappeared: "The drive is no longer connected."
            case .changed: "A different drive is now at this address. Nothing was written."
            case .nowBlocked(let m): m
            }
        }
    }

    /// Re-reads the device immediately before writing and confirms it is the same drive.
    public func revalidate(_ selected: DiskDevice, requiredBytes: Int64,
                           reread: (String) -> DiskDevice? = { DiskInventory.device($0) }) throws -> DiskDevice {
        guard let now = reread(selected.bsdName) else { throw RevalidationError.disappeared }
        guard now.fingerprint == selected.fingerprint else { throw RevalidationError.changed }
        if let blocking = evaluate(now, requiredBytes: requiredBytes).first(where: \.blocking) {
            throw RevalidationError.nowBlocked(blocking.message)
        }
        return now
    }
}

/// Process-wide lock so two destructive disk operations never run at once.
public final class DiskOperationLock: @unchecked Sendable {
    public static let shared = DiskOperationLock()
    private let lock = NSLock()
    private var busy = false

    public func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    public func release() {
        lock.lock(); busy = false; lock.unlock()
    }
}
