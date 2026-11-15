import Foundation
import Darwin

/// Decides whether a path may be removed. Every removal in UltaMac goes through `check`.
public struct SafetyPolicy: Sendable {
    public enum Purpose: Sendable {
        /// Cleaning junk, storage items or startup items.
        case clean
        /// Uninstalling an application bundle (allows `.app` bundles in Applications folders).
        case uninstallApp
    }

    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(String)

        public var isAllowed: Bool { self == .allowed }
    }

    public let home: String
    public var userExclusions: [String]
    /// Path of the running UltaMac bundle, never removable.
    public var ownBundlePath: String?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                userExclusions: [URL] = [],
                ownBundlePath: String? = Bundle.main.bundlePath) {
        self.home = SafetyPolicy.normalize(home.path)
        self.userExclusions = userExclusions.map { SafetyPolicy.normalize($0.path) }
        self.ownBundlePath = ownBundlePath.map(SafetyPolicy.normalize)
    }

    // MARK: Lists

    /// Paths that may never be removed themselves (their contents may be, subject to other rules).
    var protectedExactPaths: Set<String> {
        let h = home
        var set: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/usr", "/bin", "/sbin",
            "/private", "/var", "/etc", "/tmp", "/opt", "/cores", "/dev",
            "/Applications/Utilities", "/Users/Shared",
        ]
        let userRelative = [
            "", "Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public",
            "Applications", ".Trash",
            "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Preferences",
            "Library/Containers", "Library/Group Containers", "Library/LaunchAgents",
            "Library/Saved Application State", "Library/Developer", "Library/Developer/Xcode",
            "Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator",
            "Library/Developer/CoreSimulator/Caches", "Library/Developer/Xcode/iOS DeviceSupport",
            "Library/Fonts", "Library/Cookies", "Library/HTTPStorages", "Library/WebKit",
            ".npm", ".gradle", ".cargo", ".cargo/registry", ".cache",
            "Library/Developer/Xcode/UserData",
        ]
        for rel in userRelative {
            set.insert(rel.isEmpty ? h : h + "/" + rel)
        }
        return set
    }

    /// Areas whose contents are never touched.
    var protectedSubtrees: [String] {
        let h = home
        return [
            "/System", "/usr", "/bin", "/sbin", "/private", "/Library/Apple", "/dev", "/cores",
            h + "/Library/Keychains",
            h + "/Library/Mail",
            h + "/Library/Messages",
            h + "/Library/Mobile Documents",
            h + "/Library/CloudStorage",
            h + "/Library/Application Support/MobileSync",
            h + "/Library/Application Support/com.apple.TCC",
            h + "/Library/Accounts",
            h + "/Library/Photos",
            h + "/.ssh",
            h + "/.gnupg",
        ]
    }

    // MARK: Check

    public func check(_ url: URL, purpose: Purpose) -> Verdict {
        guard url.isFileURL else { return .denied("Not a local file.") }
        let raw = url.path
        guard raw.hasPrefix("/") else { return .denied("Path is not absolute.") }
        if raw.split(separator: "/").contains("..") { return .denied("Path contains '..'.") }

        // Resolve symlinks in the *parent* only, so a symlink is judged by where it lives,
        // and removing it removes the link, never its target.
        let parent = (raw as NSString).deletingLastPathComponent
        let resolvedParent = SafetyPolicy.normalize(
            (URL(fileURLWithPath: parent).resolvingSymlinksInPath().path))
        let name = (raw as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return .denied("Invalid name.") }
        let path = resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name

        var st = stat()
        guard lstat(path, &st) == 0 else { return .denied("Item no longer exists.") }

        if protectedExactPaths.contains(path) {
            return .denied("\(path) is a protected folder; only its contents can be removed.")
        }
        for subtree in protectedSubtrees where SafetyPolicy.isPath(path, inside: subtree) {
            return .denied("Items inside \(subtree) are never removed.")
        }
        if path.lowercased().contains(".photoslibrary") {
            return .denied("Photos libraries are never removed.")
        }
        if let own = ownBundlePath, path == own || SafetyPolicy.isPath(path, inside: own) {
            return .denied("UltaMac cannot remove itself.")
        }
        for excluded in userExclusions where path == excluded || SafetyPolicy.isPath(path, inside: excluded) {
            return .denied("Excluded in Settings: \(excluded)")
        }

        // File flags: SIP-restricted, immutable or no-unlink items are refused, never unlocked.
        let flags = UInt32(st.st_flags)
        let forbidden: [(UInt32, String)] = [
            (0x0008_0000, "protected by System Integrity Protection"), // SF_RESTRICTED
            (0x0002_0000, "marked system-immutable"),                  // SF_IMMUTABLE
            (0x0000_0002, "locked (user-immutable)"),                  // UF_IMMUTABLE
            (0x0010_0000, "marked no-unlink"),                          // SF_NOUNLINK
        ]
        for (bit, reason) in forbidden where flags & bit != 0 {
            return .denied("Item is \(reason).")
        }

        // Allowed roots.
        switch purpose {
        case .uninstallApp:
            if path.hasSuffix(".app") {
                let appRoots = ["/Applications", home + "/Applications"]
                if appRoots.contains(where: { SafetyPolicy.isPath(path, inside: $0) }) {
                    return .allowed
                }
            }
            fallthrough
        case .clean:
            if SafetyPolicy.isPath(path, inside: home) { return .allowed }
            let parts = path.split(separator: "/")
            if parts.count >= 3, parts[0] == "Volumes" { return .allowed }
            return .denied("Outside your home folder; UltaMac only removes items you own.")
        }
    }

    // MARK: Helpers

    static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        // /private/var, /private/tmp aliases are left as-is: /private is protected anyway.
        return p
    }

    /// True if `path` is strictly inside `folder`.
    static func isPath(_ path: String, inside folder: String) -> Bool {
        if folder == "/" { return path != "/" }
        return path.hasPrefix(folder + "/")
    }
}
