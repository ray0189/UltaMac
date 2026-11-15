import Foundation
import Darwin

public enum FullDiskAccess: Sendable {
    case granted, notGranted, unknown

    /// Probes a TCC-protected location that exists on every Mac. Opening it read-only only
    /// succeeds with Full Disk Access; nothing is read or changed, and no prompt is shown.
    public static func status(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> FullDiskAccess {
        let probes = [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
            home.appendingPathComponent("Library/Safari").path,
        ]
        for path in probes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES { return .notGranted }
        }
        return .unknown
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    public static let filesAndFoldersURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
}

/// Folders protected by macOS privacy controls (TCC). Reading one for the first time makes
/// macOS show its own prompt; the call blocks until you answer.
public enum ProtectedFolder: String, CaseIterable, Sendable, Identifiable {
    case desktop = "Desktop", documents = "Documents", downloads = "Downloads"

    public var id: String { rawValue }

    public enum Status: Sendable, Equatable { case granted, denied, notRequested }

    public var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(rawValue) }

    public var symbol: String {
        switch self {
        case .desktop: "menubar.dock.rectangle"
        case .documents: "doc.text"
        case .downloads: "arrow.down.circle"
        }
    }

    /// Requests access (may show the macOS prompt) and returns the result. Call off the main thread.
    public func request() -> Status {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 {
            // Opening the directory isn't enough on all versions; listing it triggers the check.
            defer { close(fd) }
            if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil { return .granted }
            return .denied
        }
        return (errno == EPERM || errno == EACCES) ? .denied : .granted
    }
}
