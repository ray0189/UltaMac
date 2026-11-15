import SwiftUI
import UltaMacCore

/// A removal waiting for the user's review. The ReviewSheet is the only path to FileRemover.
struct PendingRemoval: Identifiable {
    let id = UUID()
    let title: String
    let requests: [RemovalRequest]
    var purpose: SafetyPolicy.Purpose = .clean
    var context: String
    var note: String? = nil

    var totalSize: Int64 { requests.reduce(0) { $0 + $1.size } }
    var permanentCount: Int { requests.filter(\.permanentOnly).count }
}

struct ReviewSheet: View {
    let removal: PendingRemoval
    let completion: (RemovalReport) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var mode: RemovalMode = .moveToTrash
    @State private var confirmPermanent = false
    @State private var working = false
    @State private var locked: Set<URL> = []
    @State private var includeLocked = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                IconBadge(symbol: "trash", tint: .danger, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(removal.title).font(.title2.bold())
                    Text("\(removal.requests.count) item\(removal.requests.count == 1 ? "" : "s") · \(ByteFormat.string(removal.totalSize))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let note = removal.note {
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }

            List(removal.requests, id: \.url) { request in
                HStack(spacing: Theme.Space.s) {
                    FileIcon(url: request.url, size: 18)
                    Text(settings.expertMode ? request.url.path : relativeHomePath(request.url))
                        .lineLimit(1).truncationMode(.middle)
                    if request.permanentOnly { Pill(text: "Permanent", tint: .red) }
                    if locked.contains(request.url) { Pill(text: "Password", tint: .orange, symbol: "lock.fill") }
                    Spacer()
                    Text(ByteFormat.string(request.size)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 200)

            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $mode) {
                    Text("Move to Trash: you can restore items until you empty it").tag(RemovalMode.moveToTrash)
                    Text("Delete permanently: can't be undone").tag(RemovalMode.deletePermanently)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if !locked.isEmpty {
                    Toggle(isOn: $includeLocked) {
                        Text("Also remove the \(locked.count) locked item\(locked.count == 1 ? "" : "s") with my administrator password. macOS asks for it once; UltaMac never sees it. System files stay protected.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                }
                if removal.permanentCount > 0 {
                    Label("\(removal.permanentCount) item(s) are already in the Trash and will be deleted permanently.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            HStack {
                if working { ProgressView().controlSize(.small); Text("Removing…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(mode == .moveToTrash ? "Move to Trash" : "Delete Permanently", role: .destructive) {
                    if mode == .deletePermanently || removal.permanentCount > 0 { confirmPermanent = true } else { perform() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(working || removal.requests.isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 640, height: 540)
        .onAppear {
            mode = settings.removalMode
            locked = Set(removal.requests.map(\.url).filter { RemovalLock.check($0) != nil })
        }
        .alert(permanentAlertTitle, isPresented: $confirmPermanent) {
            Button("Delete Permanently", role: .destructive) { perform() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently deleted items can't be recovered from the Trash.")
        }
    }

    private var permanentAlertTitle: String {
        let n = mode == .deletePermanently ? removal.requests.count : removal.permanentCount
        return "Permanently delete \(n) item\(n == 1 ? "" : "s")?"
    }

    private func perform() {
        working = true
        Sound.play(.confirm)
        let remover = settings.remover, requests = removal.requests, mode = mode
        let admin = settings.adminRemover
        let purpose = removal.purpose, context = removal.context
        let lockedRequests = includeLocked ? requests.filter { locked.contains($0.url) } : []
        Task {
            var report = await runInBackground { remover.remove(requests, mode: mode, purpose: purpose, context: context) }
            let retry = lockedRequests.filter { r in report.adminRetryable.contains { $0.url == r.url } }
            if !retry.isEmpty {
                let adminReport = await runInBackground { admin.remove(retry, mode: mode, purpose: purpose, context: context) }
                report = report.merging(admin: adminReport)
            }
            Sound.play(report.failures.isEmpty ? .success : .warning)
            completion(report)
            settings.historyRevision += 1
            working = false
            dismiss()
        }
    }
}

struct ReportBanner: View {
    let report: RemovalReport
    let onClose: () -> Void
    /// Called with a merged report after an administrator removal, so the screen can update.
    var onUpdate: ((RemovalReport) -> Void)? = nil

    @Environment(AppSettings.self) private var settings
    @State private var expanded = false
    @State private var confirmAdmin = false
    @State private var working = false

    private var retryable: [RemovalFailure] { report.adminRetryable }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(report.failures.isEmpty ? .green : .orange)
                    .symbolEffect(.bounce, value: report.bytesRemoved)
                Text(report.summary)
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                } else if !retryable.isEmpty, onUpdate != nil {
                    Button { confirmAdmin = true } label: {
                        Label("Remove with Password…", systemImage: "lock.open")
                    }
                    .help("Uses macOS's administrator prompt to remove locked items. System files stay protected.")
                }
                if !report.failures.isEmpty {
                    Button(expanded ? "Hide details" : "Details") { animate { expanded.toggle() } }.buttonStyle(.link)
                }
                Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            if expanded {
                ForEach(report.failures) { failure in
                    Text("\(failure.url.lastPathComponent): \(failure.reason)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(Theme.Space.m)
        .background((report.failures.isEmpty ? Color.green : Color.orange).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
        .alert(adminTitle, isPresented: $confirmAdmin) {
            Button(report.mode == .moveToTrash ? "Continue" : "Delete Permanently", role: .destructive) { removeAsAdmin() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(adminMessage)
        }
    }

    private var adminTitle: String {
        "Remove \(retryable.count) locked item\(retryable.count == 1 ? "" : "s") with your administrator password?"
    }

    private var adminMessage: String {
        let names = retryable.prefix(3).map { $0.url.lastPathComponent }.joined(separator: ", ")
            + (retryable.count > 3 ? " and \(retryable.count - 3) more" : "")
        let action = report.mode == .moveToTrash
            ? "They'll be moved to your Trash and their lock cleared, so you can still restore them."
            : "They'll be deleted permanently and can't be recovered."
        return "\(names). macOS will ask for your password. \(action) System and SIP-protected files are still refused."
    }

    private func removeAsAdmin() {
        working = true
        let requests = retryable.map { RemovalRequest(url: $0.url, size: SizeCalculator.allocatedSize(of: $0.url)) }
        let remover = settings.adminRemover, mode = report.mode, purpose = report.purpose
        let previous = report
        Task {
            let admin = await runInBackground { remover.remove(requests, mode: mode, purpose: purpose, context: "Locked items") }
            let merged = previous.merging(admin: admin)
            Sound.play(admin.failures.isEmpty ? .success : .warning)
            settings.historyRevision += 1
            working = false
            onUpdate?(merged)
        }
    }
}
