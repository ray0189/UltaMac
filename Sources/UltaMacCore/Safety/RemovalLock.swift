import Foundation
import Darwin

/// Why an item can't be removed by the current user, diagnosed *before* trying.
/// Locks are reported, never removed: UltaMac doesn't change permissions, ACLs or flags.
public enum RemovalLock: Sendable, Hashable {
    /// The item has an access-control rule denying deletion.
    case itemACL
    /// The enclosing folder has an access-control rule denying removal of its contents.
    case folderACL(String)
    /// The enclosing folder isn't writable by you (e.g. owned by another user or root).
    case folderNotWritable(String)
    /// The item itself is owned by another user inside a sticky folder.
    case ownedByOtherUser(String)

    public var reason: String {
        switch self {
        case .itemACL:
            return "Locked by an access rule on this item (“deny delete”). Remove it in Finder with your password, or change it in Get Info › Sharing & Permissions."
        case .folderACL(let folder):
            return "The folder “\(folder)” has an access rule that stops items being removed from it. Change it in Get Info › Sharing & Permissions, or remove the item in Finder with your password."
        case .folderNotWritable(let folder):
            return "The folder “\(folder)” doesn't allow changes by your account. Removing this needs an administrator."
        case .ownedByOtherUser(let owner):
            return "Owned by “\(owner)”, so only that account or an administrator can remove it."
        }
    }

    public var shortLabel: String {
        switch self {
        case .itemACL, .folderACL: return "Locked"
        case .folderNotWritable, .ownedByOtherUser: return "Needs admin"
        }
    }

    /// Returns the first reason the item can't be removed, or nil if it looks removable.
    public static func check(_ url: URL) -> RemovalLock? {
        let path = url.path
        let parent = url.deletingLastPathComponent().path
        let folderName = url.deletingLastPathComponent().lastPathComponent

        if hasDenyEntry(path, perm: ACL_DELETE) { return .itemACL }
        if hasDenyEntry(parent, perm: ACL_DELETE_CHILD) { return .folderACL(folderName) }
        if access(parent, W_OK | X_OK) != 0 { return .folderNotWritable(folderName) }

        // Sticky folders (like /tmp) only let owners remove their own items.
        var parentStat = stat(), itemStat = stat()
        if stat(parent, &parentStat) == 0, lstat(path, &itemStat) == 0,
           parentStat.st_mode & S_ISVTX != 0, itemStat.st_uid != getuid() {
            let owner = getpwuid(itemStat.st_uid).flatMap { $0.pointee.pw_name }.map { String(cString: $0) } ?? "another user"
            return .ownedByOtherUser(owner)
        }
        return nil
    }

    /// True if the path's extended ACL contains an explicit deny entry with the given permission.
    static func hasDenyEntry(_ path: String, perm: acl_perm_t) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var which = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, which, &entry) == 0, let e = entry {
            which = Int32(ACL_NEXT_ENTRY.rawValue)
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(e, &tag) == 0, tag == ACL_EXTENDED_DENY else { continue }
            var permset: acl_permset_t?
            guard acl_get_permset(e, &permset) == 0, let ps = permset else { continue }
            if acl_get_perm_np(ps, perm) == 1 { return true }
        }
        return false
    }
}
