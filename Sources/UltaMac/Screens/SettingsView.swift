import SwiftUI
import UltaMacCore

struct SettingsView: View {
    /// true inside the main window (with page header), false in the Settings scene.
    let embedded: Bool
    @Environment(AppSettings.self) private var settings
    @State private var fda = FullDiskAccess.status()

    var body: some View {
        if embedded {
            Page(destination: .settings, scrolls: false) { form }
        } else {
            form
        }
    }

    private var form: some View {
        @Bindable var settings = settings
        return Form {
            SwiftUI.Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Expert Mode", isOn: $settings.expertMode)
                Text("Expert Mode shows full paths, rule IDs, risk details, hashes, file dates and raw system values.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.expertMode {
                    Toggle("Allow attached disk images as USB targets (testing)", isOn: $settings.allowDiskImageTargets)
                    Text("Lets you rehearse the USB tools on a disk image you attached instead of a real drive. Internal and system disks stay protected either way.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            SwiftUI.Section("Sounds") {
                Toggle("Play sound effects", isOn: $settings.soundEnabled)
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $settings.soundVolume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .disabled(!settings.soundEnabled)
                Toggle("Navigation clicks", isOn: $settings.soundNavigation).disabled(!settings.soundEnabled)
                if !Sound.systemAllowsUISounds {
                    Label("“Play user interface sound effects” is off in System Settings › Sound, so UltaMac stays silent.", systemImage: "speaker.slash")
                        .font(.caption).foregroundStyle(.orange)
                }
                if Sound.isBundled {
                    DisclosureGroup("Preview sounds") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], alignment: .leading) {
                            ForEach(SoundEffect.allCases) { effect in
                                Button { Sound.preview(effect) } label: { Label(effect.title, systemImage: "play.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                } else {
                    Text("Sound files aren't bundled in this build (run scripts/build-app.sh).").font(.caption).foregroundStyle(.secondary)
                }
            }

            SwiftUI.Section("Cleaning") {
                Picker("Default removal", selection: $settings.removalMode) {
                    Text("Move to Trash (recommended)").tag(RemovalMode.moveToTrash)
                    Text("Delete permanently").tag(RemovalMode.deletePermanently)
                }
                Stepper("Apps count as unused after \(settings.unusedAppDays) days", value: $settings.unusedAppDays, in: 30...720, step: 30)
                Text("You always review and confirm before anything is removed. Permanent deletion asks twice.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section("Scan rules") {
                ForEach(JunkRules.builtIn) { rule in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(rule.title).font(.callout.weight(.medium))
                            RiskPill(risk: rule.risk)
                            if rule.selectedByDefault { Pill(text: "Pre-selected", tint: .secondary) }
                            Spacer()
                            Text("~/\(rule.target.relativePath)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(rule.consequence).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            SwiftUI.Section("Exclusions") {
                if settings.exclusions.isEmpty {
                    Text("No folders excluded.").foregroundStyle(.secondary)
                }
                ForEach(settings.exclusions, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder.badge.minus").foregroundStyle(.secondary)
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { settings.exclusions.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK {
                        for url in panel.urls where !settings.exclusions.contains(url.path) { settings.exclusions.append(url.path) }
                    }
                }
            }

            SwiftUI.Section("Monitoring") {
                Picker("Sampling interval", selection: $settings.samplingInterval) {
                    Text("1 second").tag(1.0); Text("2 seconds").tag(2.0); Text("5 seconds").tag(5.0)
                }
                Toggle("Show monitor in menu bar", isOn: $settings.showMenuBarMonitor)
                Text("Sampling only runs while a monitor view or the menu-bar item is visible.").font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    Pill(text: fda == .granted ? "Granted" : fda == .notGranted ? "Not granted" : "Unknown",
                         tint: fda == .granted ? .green : .orange)
                }
                Text("Optional. Lets UltaMac read protected caches, the Trash and other apps' containers. Without it, those items are reported as unreadable rather than skipped silently.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Privacy & Security…") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                LabeledContent("Administrator access") { Text("Never requested").foregroundStyle(.secondary) }
                Text("UltaMac runs without root. Future disk-imaging tools will ask once per operation using macOS's own prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section("Privacy") {
                Label("No network access, accounts, analytics, crash reporting, remote configuration or update checks.", systemImage: "wifi.slash")
                LabeledContent("Activity log") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([settings.auditLog.url]) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { fda = FullDiskAccess.status() }
    }
}
