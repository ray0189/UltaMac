import SwiftUI
import UltaMacCore

// MARK: - Disk Manager

struct DiskManagerScreen: View {
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings
    @State private var selected: DiskDevice.ID?
    @State private var eraseTarget: DiskDevice?

    var body: some View {
        let model = state.disks
        Page(destination: .diskManager, subtitle: "\(model.disks.count) disks · internal and system disks are read-only here", scrolls: false) {
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        } content: {
            VStack(spacing: Theme.Space.m) {
                if let m = model.message {
                    HStack { Label(m, systemImage: "info.circle"); Spacer(); Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
                        .padding(Theme.Space.m).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    List(model.disks, selection: $selected) { d in
                        HStack(spacing: 10) {
                            Image(systemName: d.isInternal ? "internaldrive.fill" : d.isVirtual ? "opticaldiscdrive" : "externaldrive.fill")
                                .font(.title2).foregroundStyle(d.isInternal ? Theme.Tint.tools.color : Theme.Tint.storage.color).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.mediaName.isEmpty ? d.bsdName : d.mediaName).lineLimit(1)
                                Text("\(ByteFormat.string(d.size)) · \(d.busProtocol)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if d.isBootDisk { Pill(text: "System", tint: .red, symbol: "lock.fill") }
                            else if d.isInternal { Pill(text: "Internal", tint: .secondary, symbol: "lock") }
                        }
                        .padding(.vertical, 3)
                        .tag(d.id)
                    }
                    .listStyle(.inset)
                    .cardSurface(padding: 0)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .frame(width: 340)

                    if let d = model.disks.first(where: { $0.id == selected }) {
                        detail(d).cardSurface()
                    } else {
                        EmptyHero(symbol: "externaldrive", tint: .tools, title: "Select a disk",
                                  message: "Connect a USB drive to see its partitions and manage it. Internal and system disks are shown for information only.")
                            .cardSurface()
                    }
                }
            }
        }
        .onAppear { model.watch() }
        .onDisappear { model.unwatch() }
        .sheet(item: $eraseTarget) { d in EraseSheet(disk: d) { model.refresh() } }
    }

    private func detail(_ d: DiskDevice) -> some View {
        let gate = DiskSafetyGate(allowDiskImages: settings.allowDiskImageTargets)
        let blocking = gate.evaluate(d, requiredBytes: 0).filter(\.blocking)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                IconBadge(symbol: d.isInternal ? "internaldrive" : "externaldrive", tint: d.isInternal ? .tools : .storage, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.mediaName.isEmpty ? d.bsdName : d.mediaName).font(.title2.bold())
                    HStack(spacing: 6) {
                        Pill(text: ByteFormat.string(d.size))
                        Pill(text: d.busProtocol, tint: .blue)
                        Pill(text: d.schemeTitle, tint: .purple)
                        if !d.isWritable { Pill(text: "Read-only", tint: .orange) }
                    }
                    if settings.expertMode {
                        Text("\(d.deviceNode) · removable \(d.isRemovable ? "yes" : "no") · ejectable \(d.isEjectable ? "yes" : "no") · \(d.isVirtual ? "virtual" : "physical")")
                            .font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            Text("Partitions").font(.headline)
            if d.partitions.isEmpty {
                Text("No partitions.").foregroundStyle(.secondary)
            } else {
                // Proportional partition map.
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(d.partitions) { p in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Treemap.tint(forPartition: p))
                                .frame(width: max(4, geo.size.width * CGFloat(Double(p.size) / Double(max(d.size, 1))) - 2))
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 18)
                ForEach(d.partitions) { p in
                    HStack {
                        Circle().fill(Treemap.tint(forPartition: p)).frame(width: 8, height: 8)
                        Text(p.name.isEmpty ? p.bsdName : p.name)
                        Text(p.content).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let mp = p.mountPoint { Text(mp).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Text(ByteFormat.string(p.size)).monospacedDigit()
                        if settings.expertMode { Text(p.bsdName).font(.caption.monospaced()).foregroundStyle(.tertiary) }
                    }
                    .font(.callout)
                }
            }
            Spacer()
            if !blocking.isEmpty {
                Label(blocking[0].message, systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Mount") { state.disks.run("Mount") { DiskInventory.mount(d) } }
                    Button("Unmount") { state.disks.run("Unmount") { DiskInventory.unmount(d) } }
                    Button("Eject") { state.disks.run("Eject") { DiskInventory.eject(d) } }
                    Spacer()
                    Button("Erase…", role: .destructive) { eraseTarget = d }
                        .help("Formats the whole drive after a typed confirmation")
                }
            }
        }
    }
}

extension Treemap {
    static func tint(forPartition p: PartitionInfo) -> Color {
        let c = p.content.lowercased()
        if c.contains("efi") { return .gray }
        if c.contains("apfs") { return Theme.Tint.storage.colors[0] }
        if c.contains("dos") || c.contains("fat") || c.contains("windows") || c.contains("microsoft") { return Theme.Tint.warning.colors[0] }
        if c.contains("linux") { return Theme.Tint.clean.colors[0] }
        if c.contains("hfs") { return Theme.Tint.apps.colors[0] }
        return .teal
    }
}

struct EraseSheet: View {
    let disk: DiskDevice
    let done: () -> Void
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var fs: DiskEraser.FileSystem = .exFAT
    @State private var scheme: DiskEraser.Scheme = .gpt
    @State private var name = "USB"
    @State private var typed = ""
    @State private var working = false
    @State private var error: String?

    private var phrase: String { "ERASE \(disk.bsdName.uppercased())" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                IconBadge(symbol: "exclamationmark.triangle.fill", tint: .danger, size: 44)
                VStack(alignment: .leading) {
                    Text("Erase “\(disk.mediaName)”").font(.title2.bold())
                    Text("\(ByteFormat.string(disk.size)) · \(disk.busProtocol) · \(disk.deviceNode)").foregroundStyle(.secondary)
                }
            }
            Text("Everything on this drive will be permanently erased\(disk.mountPoints.isEmpty ? "" : ", including \(disk.mountPoints.joined(separator: ", "))"). This can't be undone.")
            Form {
                Picker("Format", selection: $fs) { ForEach(DiskEraser.FileSystem.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("Scheme", selection: $scheme) { ForEach(DiskEraser.Scheme.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField("Name", text: $name)
                Text("Will be named “\(DiskEraser.sanitizedName(name, for: fs))”").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 4) {
                Text("Type **\(phrase)** to confirm").font(.callout)
                TextField(phrase, text: $typed).textFieldStyle(.roundedBorder).font(.body.monospaced())
            }
            if let error { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout) }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Erasing…") }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.disabled(working)
                Button("Erase", role: .destructive) { erase() }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(typed != phrase || working)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
    }

    private func erase() {
        working = true
        let gate = DiskSafetyGate(allowDiskImages: settings.allowDiskImageTargets)
        let d = disk, fs = fs, name = name, scheme = scheme
        Task {
            let outcome: String? = await runInBackground {
                do { _ = try DiskEraser.erase(d, fs: fs, name: name, scheme: scheme, gate: gate); return nil }
                catch { return error.localizedDescription }
            }
            working = false
            if let outcome { error = outcome; Sound.play(.error) } else { Sound.play(.success); done(); dismiss() }
        }
    }
}

// MARK: - ISO Library

struct ISOLibraryScreen: View {
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings
    @State private var expected = ""
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var lib = state.library
        Page(destination: .isoLibrary, subtitle: "\(lib.entries.count) images · stored as references; your files stay where they are", scrolls: false) {
            TextField("Search", text: $lib.search).textFieldStyle(.roundedBorder).frame(width: 180)
            Button { lib.importImages() } label: { Label("Add Images…", systemImage: "plus") }.buttonStyle(.borderedProminent)
        } content: {
            if lib.entries.isEmpty && lib.inspecting.isEmpty {
                EmptyHero(symbol: "opticaldisc", tint: .tools, title: "Your image library",
                          message: "Add ISO, IMG or “Install macOS” files. UltaMac detects the OS, architecture and boot format, computes SHA-256 checksums and compares them with values you paste from the publisher. Drag files here or click Add.",
                          buttonTitle: "Add Images…") { lib.importImages() }
                    .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
            } else {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    List(lib.visible, selection: $lib.selection) { e in
                        HStack(spacing: 10) {
                            IconBadge(symbol: icon(e.info.os), tint: e.exists ? .tools : .danger, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text("\(e.info.os.rawValue) · \(ByteFormat.string(e.info.size))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let m = e.checksumMatches { Image(systemName: m ? "checkmark.seal.fill" : "xmark.seal.fill").foregroundStyle(m ? .green : .red) }
                            if !e.exists { Pill(text: "Missing", tint: .red) }
                        }
                        .tag(e.id)
                    }
                    .listStyle(.inset)
                    .cardSurface(padding: 0)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .frame(width: 340)
                    .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)

                    if let e = lib.entries.first(where: { $0.id == lib.selection }) {
                        detail(e).cardSurface()
                    } else {
                        EmptyHero(symbol: "opticaldisc", tint: .tools, title: "Select an image", message: "Details, checksum and compatibility appear here.").cardSurface()
                    }
                }
            }
        }
    }

    private func detail(_ e: LibraryEntry) -> some View {
        let lib = state.library
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.m) {
                    IconBadge(symbol: icon(e.info.os), tint: .tools, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.url.lastPathComponent).font(.title3.bold()).lineLimit(2)
                        Text(relativeHomePath(e.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.xl, verticalSpacing: 6) {
                    GridRow { Text("Operating system").foregroundStyle(.secondary); Text(e.info.os.rawValue) }
                    if let v = e.info.version { GridRow { Text("Version").foregroundStyle(.secondary); Text(v).lineLimit(2) } }
                    if let l = e.info.label { GridRow { Text("Volume label").foregroundStyle(.secondary); Text(l) } }
                    GridRow { Text("Format").foregroundStyle(.secondary); Text(e.info.format.rawValue) }
                    GridRow { Text("Architecture").foregroundStyle(.secondary); Text(e.info.architectures.isEmpty ? "Not detected" : e.info.architectures.joined(separator: ", ")) }
                    GridRow { Text("Size").foregroundStyle(.secondary); Text(ByteFormat.string(e.info.size)) }
                    GridRow { Text("USB workflow").foregroundStyle(.secondary); Text(e.info.workflow.rawValue).foregroundStyle(e.info.workflow == .unsupported ? .orange : .primary) }
                }
                .font(.callout)
                ForEach(e.info.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }

                Divider()
                Text("Integrity").font(.headline)
                if let progress = lib.hashing[e.id] {
                    HStack { ProgressView(value: progress); Text("\(Int(progress * 100))%").monospacedDigit(); Button("Stop") { lib.cancelHash(e) } }
                } else if let h = e.sha256 {
                    Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                    Text(h).font(.caption.monospaced()).textSelection(.enabled)
                    let dupes = lib.duplicates(of: e)
                    if !dupes.isEmpty { Label("Identical to \(dupes.map { $0.url.lastPathComponent }.joined(separator: ", "))", systemImage: "doc.on.doc").font(.caption).foregroundStyle(.orange) }
                } else if e.info.format != .macInstaller {
                    Button("Compute SHA-256") { lib.computeHash(e) }.disabled(!e.exists)
                }
                if e.info.format != .macInstaller {
                    HStack {
                        TextField("Paste the publisher's SHA-256 to compare", text: $expected)
                            .textFieldStyle(.roundedBorder).font(.caption.monospaced())
                        Button("Compare") { lib.setExpected(expected, for: e); if e.sha256 == nil { lib.computeHash(e) } }
                            .disabled(expected.isEmpty)
                    }
                    if let m = lib.entries.first(where: { $0.id == e.id })?.checksumMatches {
                        Label(m ? "Checksum matches the publisher's value." : "Checksum does NOT match. Don't use this image.",
                              systemImage: m ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(m ? .green : .red)
                    }
                }
                Divider()
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }
                    Button("Remove from Library") { lib.remove(e) }
                    Spacer()
                    Button { state.usb.choose(e.url); state.go(.usbToolkit) } label: { Label("Create USB…", systemImage: "externaldrive.badge.plus") }
                        .buttonStyle(.borderedProminent)
                        .disabled(e.info.workflow == .unsupported || !e.exists)
                }
            }
        }
        .onChange(of: e.id) { _, _ in expected = e.expectedSHA256 ?? "" }
        .onAppear { expected = e.expectedSHA256 ?? "" }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in state.library.add(url) } }
            }
        }
        return true
    }

    func icon(_ os: ImageInfo.OS) -> String {
        switch os {
        case .macOS: "apple.logo"
        case .windows: "pc"
        case .raspberryPi: "cpu"
        case .unknown: "opticaldisc"
        default: "terminal"
        }
    }
}

// MARK: - USB & OS Toolkit (wizard)

struct USBToolkitScreen: View {
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var w = state.usb
        Page(destination: .usbToolkit, subtitle: "Select Image → Inspect → USB Drive → Compatibility → Confirm → Write & Verify", scrolls: false) {
            if w.step != .image && w.step != .write { Button("Start Over") { w.reset() } }
        } content: {
            VStack(spacing: Theme.Space.l) {
                stepper(w.step)
                Group {
                    switch w.step {
                    case .image: chooseImage
                    case .inspect: inspect
                    case .target: chooseTarget
                    case .check: compatibility
                    case .confirm: confirm
                    case .write: writing
                    case .done: done
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .cardSurface(padding: Theme.Space.xl)
                .transition(.opacity)
            }
        }
        .onAppear { state.disks.watch() }
        .onDisappear { state.disks.unwatch() }
    }

    private func stepper(_ current: USBWizardModel.Step) -> some View {
        HStack(spacing: 0) {
            ForEach(USBWizardModel.Step.allCases, id: \.self) { s in
                let passed = s.rawValue < current.rawValue, active = s == current
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(active ? AnyShapeStyle(Theme.gradient(.brand)) : AnyShapeStyle(passed ? Color.green.opacity(0.8) : Color.primary.opacity(0.1)))
                            .frame(width: 22, height: 22)
                        if passed { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) }
                        else { Text("\(s.rawValue + 1)").font(.caption2.bold()).foregroundStyle(active ? .white : .secondary) }
                    }
                    Text(s.title).font(.caption.weight(active ? .semibold : .regular)).foregroundStyle(active ? .primary : .secondary)
                }
                if s != USBWizardModel.Step.allCases.last { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).frame(maxWidth: .infinity).padding(.horizontal, 6) }
            }
        }
    }

    // Step 1
    private var chooseImage: some View {
        let installers = USBWizardModel.localInstallers()
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Choose what to put on the USB drive").font(.title3.bold())
            HStack(spacing: Theme.Space.l) {
                optionCard("opticaldisc", "ISO or disk image", "Linux, Windows 10/11, Raspberry Pi OS and other images") { state.usb.pickFile() }
                optionCard("books.vertical", "From ISO Library", "\(state.library.entries.count) images") { state.go(.isoLibrary) }
            }
            if !installers.isEmpty {
                Text("macOS installers on this Mac").font(.headline)
                ForEach(installers, id: \.self) { url in
                    Button { state.usb.choose(url) } label: {
                        HStack { FileIcon(url: url, size: 28); Text(url.deletingPathExtension().lastPathComponent); Spacer(); Image(systemName: "chevron.right") }
                            .padding(Theme.Space.m).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("No “Install macOS” apps found in /Applications. Download one from the App Store or Software Update to make a macOS installer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func optionCard(_ symbol: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                IconBadge(symbol: symbol, tint: .brand, size: 40)
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(HoverLift())
    }

    // Step 2
    private var inspect: some View {
        let w = state.usb
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            if w.isInspecting || w.info == nil {
                ScanProgress(title: "Inspecting image…", detail: w.imageURL?.lastPathComponent ?? "")
            } else if let info = w.info {
                Text(info.url.lastPathComponent).font(.title3.bold())
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.xl, verticalSpacing: 6) {
                    GridRow { Text("Operating system").foregroundStyle(.secondary); Text(info.os.rawValue + (info.version.map { " · \($0)" } ?? "")).lineLimit(2) }
                    GridRow { Text("Format").foregroundStyle(.secondary); Text(info.format.rawValue) }
                    GridRow { Text("Architecture").foregroundStyle(.secondary); Text(info.architectures.isEmpty ? "Not detected" : info.architectures.joined(separator: ", ")) }
                    GridRow { Text("Size").foregroundStyle(.secondary); Text(ByteFormat.string(info.size)) }
                    GridRow { Text("Method").foregroundStyle(.secondary); Text(info.workflow.rawValue).foregroundStyle(info.workflow == .unsupported ? .orange : .primary) }
                }
                ForEach(info.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                HStack {
                    Button("Back") { animate { state.usb.step = .image } }
                    Spacer()
                    Button("Choose USB Drive") { animate { state.usb.step = .target } }
                        .buttonStyle(.borderedProminent).disabled(info.workflow == .unsupported)
                }
            }
        }
    }

    // Step 3 — never auto-selected.
    private var chooseTarget: some View {
        let candidates = state.disks.external
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Choose the USB drive to erase").font(.title3.bold())
            Text("Only external drives are listed. UltaMac never picks one for you.").foregroundStyle(.secondary)
            if candidates.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Waiting for a USB drive… Connect one now.") }
                    .padding(.vertical, Theme.Space.xl)
            }
            ForEach(candidates) { d in
                let selected = state.usb.target?.id == d.id
                Button { state.usb.target = d } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
                        Image(systemName: d.isVirtual ? "opticaldiscdrive" : "externaldrive.fill").font(.title2).foregroundStyle(Theme.Tint.storage.color)
                        VStack(alignment: .leading) {
                            Text(d.mediaName).font(.body.weight(.semibold))
                            Text("\(ByteFormat.string(d.size)) · \(d.busProtocol) · \(d.deviceNode)\(d.mountPoints.isEmpty ? "" : " · " + d.mountPoints.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if d.isVirtual { Pill(text: "Disk image (testing)", tint: .orange) }
                    }
                    .padding(Theme.Space.m)
                    .background(selected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack {
                Button("Back") { animate { state.usb.step = .inspect } }
                Spacer()
                Button("Check Compatibility") { animate { state.usb.step = .check } }.buttonStyle(.borderedProminent).disabled(state.usb.target == nil)
            }
        }
    }

    // Step 4
    private var compatibility: some View {
        let w = state.usb
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Compatibility check").font(.title3.bold())
            if let t = w.target, let info = w.info {
                Text("\(info.url.lastPathComponent) → \(t.mediaName) (\(ByteFormat.string(t.size)))").foregroundStyle(.secondary)
                let problems = w.problems
                if problems.isEmpty { Label("No problems found.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                ForEach(problems, id: \.self) { p in
                    Label(p.message, systemImage: p.blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(p.blocking ? .red : .orange)
                }
                Text(compatibilityNote(info)).font(.callout).foregroundStyle(.secondary)
                Text("Boot compatibility depends on the target computer's firmware. UltaMac doesn't claim universal compatibility.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            HStack {
                Button("Back") { animate { state.usb.step = .target } }
                Spacer()
                Button("Continue") { animate { state.usb.step = .confirm } }.buttonStyle(.borderedProminent).disabled(!w.canWrite)
            }
        }
    }

    private func compatibilityNote(_ info: ImageInfo) -> String {
        switch info.workflow {
        case .raw: "The image is copied block-for-block, then read back and compared with SHA-256. Hybrid Linux ISOs boot on UEFI and most BIOS PCs; Raspberry Pi images boot on compatible Pi models."
        case .windows: "The drive is formatted GPT + FAT32 and the Windows files are copied (install.wim split if needed). Boots on UEFI PCs, including with Secure Boot. Legacy-BIOS-only PCs aren't supported."
        case .macInstaller: "Apple's createinstallmedia erases the drive and makes a bootable installer for Macs that support this macOS version. You'll be asked for your administrator password."
        case .unsupported: ""
        }
    }

    // Step 5 — separate erase confirmation.
    private var confirm: some View {
        @Bindable var w = state.usb
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                IconBadge(symbol: "exclamationmark.triangle.fill", tint: .danger, size: 44)
                VStack(alignment: .leading) {
                    Text("Erase \(w.target?.mediaName ?? "")?").font(.title2.bold())
                    Text("\(ByteFormat.string(w.target?.size ?? 0)) · \(w.target?.deviceNode ?? "")").foregroundStyle(.secondary)
                }
            }
            Text("Everything on this drive will be destroyed and replaced with \(w.info?.url.lastPathComponent ?? "the image"). Interrupting the write (or unplugging the drive) can leave it unbootable until it's erased again.")
            if w.target?.isVirtual == false {
                Label("Real USB drives need your administrator password; macOS will ask (UltaMac never sees it).", systemImage: "lock").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Type **\(w.confirmationPhrase)** to confirm")
                TextField(w.confirmationPhrase, text: $w.confirmText).textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(width: 260)
            }
            Spacer()
            HStack {
                Button("Back") { animate { state.usb.step = .check } }
                Spacer()
                Button("Erase & Write", role: .destructive) { state.usb.start() }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(w.confirmText != w.confirmationPhrase || !w.canWrite)
            }
        }
    }

    // Step 6
    private var writing: some View {
        let p = state.usb.progress
        return VStack(spacing: Theme.Space.l) {
            Spacer()
            ScanProgress(title: p?.phase ?? "Starting…",
                         detail: progressDetail(p),
                         fraction: p?.fraction)
                .frame(height: 260)
            Button("Cancel") { state.usb.stop() }
            Text("Cancelling leaves the drive partially written. Erase it before reusing it.").font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func progressDetail(_ p: WriteProgress?) -> String {
        guard let p else { return "" }
        var parts: [String] = []
        if p.total > 0 { parts.append("\(ByteFormat.string(p.done)) of \(ByteFormat.string(p.total))") }
        if p.bytesPerSecond > 0 { parts.append(ByteFormat.rate(p.bytesPerSecond)) }
        if let s = p.secondsRemaining { parts.append("about \(formatDuration(s)) left") }
        return parts.joined(separator: " · ")
    }

    // Step 7
    private var done: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            switch state.usb.result {
            case .success(let r):
                EmptyHero(symbol: "checkmark.seal.fill", tint: .success, title: "Ready to boot", message: r.summary + (r.sha256.map { "\nSHA-256 \($0.prefix(24))…" } ?? ""))
                HStack {
                    if let t = state.usb.target { Button("Eject Drive") { state.disks.run("Eject") { DiskInventory.eject(t) } } }
                    Button("Make Another") { state.usb.reset() }.buttonStyle(.borderedProminent)
                }
            case .failure(let e):
                EmptyHero(symbol: "xmark.octagon.fill", tint: .danger, title: "Not completed", message: e.localizedDescription)
                Button("Start Over") { state.usb.reset() }
            case nil:
                ProgressView()
            }
            Spacer()
        }
    }
}
