import SwiftUI
import UltaMacCore

/// Holds every feature model so state survives switching screens.
@MainActor @Observable
final class AppState {
    var destination: Destination? = .dashboard
    let junk = JunkModel()
    let storage = StorageModel()
    let largeOld = LargeOldModel()
    let duplicates = DuplicatesModel()
    let uninstaller = UninstallerModel()
    let startup = StartupModel()
    let smartScan = SmartScanModel()
    let disks = DisksModel()
    let library = ImageLibraryModel()
    let usb = USBWizardModel()
    let permissions = PermissionsModel()

    func go(_ d: Destination) {
        animate(Motion.spring) { destination = d }
    }
}

@main
struct UltaMacApp: App {
    @State private var settings = AppSettings()
    @State private var monitor = MonitorModel()
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("UltaMac", id: "main") {
            RootView()
                .environment(settings)
                .environment(monitor)
                .environment(state)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(settings.appearance.colorScheme)
                .onAppear { Sound.play(.launch) }
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Run Smart Scan") {
                    state.go(.dashboard)
                    state.smartScan.run(junk: state.junk, files: state.largeOld, apps: state.uninstaller)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Toggle("Expert Mode", isOn: $settings.expertMode).keyboardShortcut("e", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView(embedded: false)
                .environment(settings)
                .environment(monitor)
                .frame(width: 640, height: 560)
                .preferredColorScheme(settings.appearance.colorScheme)
        }

        MenuBarExtra(isInserted: $settings.showMenuBarMonitor) {
            MenuBarPanel().environment(monitor).environment(settings)
        } label: {
            MenuBarLabel().environment(monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings
    @State private var expandedTools = true
    @State private var showWelcome = false

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(selection: $state.destination) {
                ForEach(NavGroup.allCases) { group in
                    SwiftUI.Section(group.rawValue) {
                        ForEach(Destination.items(in: group)) { d in SidebarRow(destination: d).tag(d) }
                    }
                }
                SwiftUI.Section {
                    SidebarRow(destination: .permissions).tag(Destination.permissions)
                    SidebarRow(destination: .settings).tag(Destination.settings)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top) { brandHeader }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            detail(for: state.destination ?? .dashboard)
                .id(state.destination)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
        .onChange(of: state.destination) { _, _ in Sound.play(.navigate) }
        .sheet(isPresented: $showWelcome) { WelcomeSheet().environment(state) }
        .onAppear {
            // `--section <name>` opens a given screen (screenshots/testing). Applied after window
            // restoration so it can't be overridden.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--section"), i + 1 < args.count, let d = Destination(rawValue: args[i + 1]) {
                state.destination = d
            }
            if args.contains("--expert") { settings.expertMode = true }
            if !UserDefaults.standard.bool(forKey: "welcomed") && !args.contains("--section") { showWelcome = true }
            if args.contains("--basic") { settings.expertMode = false }
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: "sparkles", tint: .brand, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("UltaMac").font(.system(size: 17, weight: .bold, design: .rounded))
                Text("Clean · Monitor · Optimise · Recover").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 34).padding(.bottom, 6)
    }

    private var sidebarFooter: some View {
        @Bindable var settings = settings
        return HStack(spacing: 6) {
            Image(systemName: "wifi.slash").foregroundStyle(.secondary)
            Text("Offline").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            Toggle(isOn: $settings.expertMode) { Text("Expert").font(.caption) }
                .toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private func detail(for d: Destination) -> some View {
        switch d {
        case .dashboard: DashboardScreen()
        case .activity: ActivityScreen()
        case .cleaner: CleanerScreen(model: state.junk)
        case .storage: StorageScreen(model: state.storage)
        case .duplicates: DuplicatesScreen(model: state.duplicates)
        case .largeOld: LargeOldScreen(model: state.largeOld)
        case .uninstaller: UninstallerScreen(model: state.uninstaller)
        case .monitor: MonitorScreen()
        case .processes: ProcessScreen()
        case .battery: BatteryScreen()
        case .startup: StartupScreen(model: state.startup)
        case .network: NetworkScreen()
        case .maintenance: MaintenanceScreen()
        case .usbToolkit: USBToolkitScreen()
        case .diskManager: DiskManagerScreen()
        case .isoLibrary: ISOLibraryScreen()
        case .reports: ReportsScreen()
        case .permissions: PermissionsScreen()
        case .settings: SettingsView(embedded: true)
        }
    }
}

struct SidebarRow: View {
    let destination: Destination

    var body: some View {
        HStack(spacing: 9) {
            IconBadge(symbol: destination.symbol, tint: destination.isAvailable ? destination.tint : .settings, size: 22)
                .opacity(destination.isAvailable ? 1 : 0.55)
            Text(destination.title).foregroundStyle(destination.isAvailable ? .primary : .secondary)
            Spacer(minLength: 4)
            if !destination.isAvailable {
                Text("Soon").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
        }
        .padding(.vertical, 1)
    }
}
