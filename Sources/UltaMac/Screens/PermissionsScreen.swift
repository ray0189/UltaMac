import SwiftUI
import UltaMacCore

@MainActor @Observable
final class PermissionsModel {
    private(set) var fullDisk: FullDiskAccess = .unknown
    /// Results of explicit requests this session, plus what was remembered from earlier ones.
    private(set) var folders: [ProtectedFolder: ProtectedFolder.Status] = [:]
    private(set) var requesting: ProtectedFolder?

    init() {
        refresh()
        for f in ProtectedFolder.allCases {
            if let raw = UserDefaults.standard.string(forKey: "folderAccess.\(f.rawValue)") {
                folders[f] = raw == "granted" ? .granted : .denied
            }
        }
    }

    func refresh() {
        fullDisk = FullDiskAccess.status()
        if fullDisk == .granted { for f in ProtectedFolder.allCases { folders[f] = .granted } }
    }

    func status(_ f: ProtectedFolder) -> ProtectedFolder.Status { folders[f] ?? .notRequested }

    var allFoldersGranted: Bool { ProtectedFolder.allCases.allSatisfy { status($0) == .granted } }

    func request(_ f: ProtectedFolder) {
        requesting = f
        Task {
            let s = await runInBackground { f.request() }
            folders[f] = s
            UserDefaults.standard.set(s == .granted ? "granted" : "denied", forKey: "folderAccess.\(f.rawValue)")
            requesting = nil
            Sound.play(s == .granted ? .success : .warning)
        }
    }

    func requestAll() {
        Task {
            for f in ProtectedFolder.allCases where status(f) != .granted {
                requesting = f
                let s = await runInBackground { f.request() }
                folders[f] = s
                UserDefaults.standard.set(s == .granted ? "granted" : "denied", forKey: "folderAccess.\(f.rawValue)")
            }
            requesting = nil
        }
    }
}

struct PermissionsScreen: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Page(destination: .permissions, subtitle: "UltaMac asks only for what a feature needs. You can change any of these in System Settings.") {
            Button { state.permissions.refresh() } label: { Label("Recheck", systemImage: "arrow.clockwise") }
        } content: {
            PermissionsContent()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.permissions.refresh()
        }
    }
}

struct PermissionsContent: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let p = state.permissions
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            // Full Disk Access
            Card {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    IconBadge(symbol: "lock.open.laptopcomputer", tint: p.fullDisk == .granted ? .success : .warning, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Full Disk Access").font(.title3.bold())
                            statusPill(p.fullDisk == .granted ? .granted : p.fullDisk == .notGranted ? .denied : .notRequested)
                            Text("Recommended").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Lets UltaMac scan everything it cleans: protected caches, the Trash, mail downloads and other apps' containers, without a prompt for each folder. macOS only lets *you* grant it, in System Settings.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if p.fullDisk != .granted {
                    VStack(alignment: .leading, spacing: 6) {
                        step(1, "Click **Open Full Disk Access**.")
                        step(2, "Turn on **UltaMac** in the list. If it isn't listed, click **+** and choose **UltaMac** in Applications (or drag it in with **Show UltaMac in Finder**).")
                        step(3, "Come back here. The status updates automatically. macOS may ask you to quit and reopen UltaMac.")
                    }
                    .padding(.leading, 56)
                    HStack {
                        Button("Open Full Disk Access") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }.buttonStyle(.borderedProminent)
                        Button("Show UltaMac in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        Spacer()
                        if !Bundle.main.bundlePath.hasPrefix("/Applications") {
                            Label("UltaMac is running from \(relativeHomePath(Bundle.main.bundleURL.deletingLastPathComponent())). Install it in Applications first so the permission sticks.",
                                  systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.leading, 56)
                }
            }

            // Folder access
            Card {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    IconBadge(symbol: "folder.badge.person.crop", tint: p.allFoldersGranted ? .success : .storage, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your folders").font(.title3.bold())
                        Text("Without Full Disk Access, macOS asks separately for Desktop, Documents and Downloads the first time a scan reaches them, and the scan waits for your answer. Grant them here up front instead.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !p.allFoldersGranted && p.fullDisk != .granted {
                        Button("Ask for All") { p.requestAll() }.disabled(p.requesting != nil)
                    }
                }
                ForEach(ProtectedFolder.allCases) { f in
                    HStack {
                        Image(systemName: f.symbol).frame(width: 24).foregroundStyle(.secondary)
                        Text(f.rawValue)
                        Spacer()
                        if p.requesting == f {
                            ProgressView().controlSize(.small)
                            Text("Answer the macOS prompt…").font(.caption).foregroundStyle(.secondary)
                        } else {
                            statusPill(p.status(f))
                            if p.status(f) == .notRequested { Button("Allow…") { p.request(f) }.disabled(p.requesting != nil) }
                            if p.status(f) == .denied {
                                Button("Change in Settings") { NSWorkspace.shared.open(FullDiskAccess.filesAndFoldersURL) }
                            }
                        }
                    }
                    .padding(.leading, 56)
                }
            }

            // Other permissions (informational, requested only when used)
            Card(title: "Asked only when needed", symbol: "hand.raised") {
                infoRow("externaldrive", "Removable volumes", "macOS asks the first time UltaMac reads a USB drive in Disk Manager or the USB Toolkit.")
                infoRow("lock.shield", "Administrator password", "Requested by macOS's own dialog for one operation at a time: writing a USB installer, or flushing the DNS cache. UltaMac never sees or stores it and runs no background root helper.")
                infoRow("wifi.slash", "Network", "Not used. UltaMac has no network code; the only traffic is a router ping you start yourself.")
            }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.bold()).foregroundStyle(.white).frame(width: 18, height: 18).background(Theme.brand, in: Circle())
            Text(text).font(.callout)
        }
    }

    private func infoRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusPill(_ s: ProtectedFolder.Status) -> some View {
        switch s {
        case .granted: Pill(text: "Allowed", tint: .green, symbol: "checkmark")
        case .denied: Pill(text: "Not allowed", tint: .orange, symbol: "xmark")
        case .notRequested: Pill(text: "Not asked yet", tint: .secondary)
        }
    }
}

/// First-launch welcome with the brand and the permission setup.
struct WelcomeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                IconBadge(symbol: "sparkles", tint: .brand, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to UltaMac").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("The Ultimate Mac Toolkit").foregroundStyle(.secondary)
                    Text("Clean. Monitor. Optimise. Recover.").font(.callout.weight(.medium)).foregroundStyle(Theme.brand)
                }
            }
            Text("Everything runs on this Mac: no accounts, no subscriptions, no internet. Scans only read; nothing is removed until you review it.")
                .foregroundStyle(.secondary)
            ScrollView { PermissionsContent() }.frame(height: 430)
            HStack {
                Text("You can revisit this any time in Permissions.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") {
                    UserDefaults.standard.set(true, forKey: "welcomed")
                    dismiss()
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 720)
    }
}
