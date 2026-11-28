import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.screen) {
                Label("Setup", systemImage: "wrench.and.screwdriver")
                    .badge(model.setupIssues)
                    .tag(AppModel.Screen.setup)
                Label("Game", systemImage: "gamecontroller")
                    .tag(AppModel.Screen.game)
                Label("Updates", systemImage: "arrow.down.circle")
                    .badge(model.updateAvailable ? 1 : 0)
                    .tag(AppModel.Screen.updates)
                Label {
                    Text("Activity")
                } icon: {
                    if model.activity.running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "list.bullet.rectangle")
                    }
                }
                .tag(AppModel.Screen.activity)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            ScrollView {
                Group {
                    switch model.screen {
                    case .setup: SetupScreen()
                    case .game: GameScreen()
                    case .updates: UpdatesScreen()
                    case .activity: ActivityScreen()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .alert("A new TVCraft Installer is available", isPresented: $model.showNewInstallerAlert) {
            Button("Download") { model.downloadNewInstaller() }
            Button("Later", role: .cancel) {}
        } message: {
            Text(newInstallerMessage)
        }
    }

    private var newInstallerMessage: String {
        let tag = model.newerInstaller?.tag ?? "A new release"
        return "\(tag) needs a new installer. Download it from its release page to keep updating the game. Until then, Reinstall still works."
    }
}

/// Shown on the Game and Updates screens while a release of a later major version is out.
struct NewInstallerBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let release = model.newerInstaller {
            GroupBox {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.down.app.fill").font(.title2).foregroundStyle(Color.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A new TVCraft Installer is available").bold()
                        Text("\(release.tag) needs it. Game updates stop until you download it; Reinstall still works, so a free Apple ID's 7 days can be renewed.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Download", action: model.downloadNewInstaller)
                        .buttonStyle(.borderedProminent)
                }
                .padding(6)
            }
        }
    }
}

// MARK: - Setup

struct SetupScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Header(title: "Setup", subtitle: "What this Mac needs to build TVCraft and install it on your Apple TV.")
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if model.doctor.isEmpty {
                        ProgressView("Checking…")
                    }
                    ForEach(model.doctor) { item in
                        HStack(alignment: .top, spacing: 10) {
                            StatusIcon(status: item.status)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).bold()
                                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if let action = item.action, let title = item.actionTitle {
                                Button(title) { model.perform(action) }
                                    .disabled(model.activity.running)
                            }
                        }
                    }
                }
                .padding(8)
            }
            HStack {
                Button("Check Again") {
                    Task { await model.checkSetup() }
                }
                .disabled(model.checkingSetup)
                if model.checkingSetup {
                    ProgressView().controlSize(.small)
                }
            }
            APKBox()
            StorageBox()
        }
    }
}

/// Setup → Storage: the one folder the installer writes to, and ways to shrink it.
struct StorageBox: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmingRemove = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "internaldrive").font(.title).foregroundStyle(Color.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.storageSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Measuring…")
                            .font(.headline)
                        Text(model.workspace.root.path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Show in Finder", action: model.showStorage)
                }
                Text("Everything the installer downloads and builds is in this folder, never in the app, so replacing the installer keeps it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Free Up Space", action: model.freeUpSpace)
                        .help("Deletes the Xcode build. The next install builds it again.")
                    Spacer()
                    Button("Remove Everything…", role: .destructive) { confirmingRemove = true }
                }
                .disabled(model.activity.running)
            }
            .padding(6)
        } label: {
            Text("Storage").font(.headline)
        }
        .confirmationDialog("Remove everything the installer keeps on this Mac?", isPresented: $confirmingRemove) {
            Button("Remove Everything", role: .destructive, action: model.removeEverything)
        } message: {
            Text("This deletes the source, the build, the logs, your world backups and the installer's settings. The game stays on your Apple TVs.")
        }
    }
}

struct StatusIcon: View {
    let status: DoctorItem.Status

    var body: some View {
        switch status {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .optional: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        }
    }
}

struct APKBox: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropping = false

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox").font(.title)
                    .foregroundStyle(model.state.apk.isEmpty ? Color.secondary : Color.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.state.apk.isEmpty ? "No APK chosen" : URL(fileURLWithPath: model.state.apk).lastPathComponent)
                        .font(.headline)
                    Text(model.state.apk.isEmpty
                         ? "The Android APK of your own copy of Minecraft: Pocket Edition 0.8.1 (armeabi-v7a). Drop it here."
                         : model.state.apk)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                Spacer()
                Button("Choose…", action: choose).disabled(model.activity.running)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).stroke(dropping ? Color.brand : .clear, lineWidth: 2))
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                guard !model.activity.running, let provider = providers.first else {
                    return false
                }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.pathExtension.lowercased() == "apk" {
                        Task { @MainActor in model.state.apk = url.path }
                    }
                }
                return true
            }
        } label: {
            Text("Your APK").font(.headline)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.message = "Choose the APK of your own Minecraft: Pocket Edition 0.8.1 (armeabi-v7a)."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            model.state.apk = url.path
        }
    }
}

// MARK: - Game

struct GameScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Header(title: "TVCraft", subtitle: gameStatus)
            NewInstallerBanner()
            APKBox()
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.state.installs) { install in
                        InstallRow(install: install)
                        Divider()
                    }
                    ForEach(model.newDevices) { device in
                        DeviceRow(device: device)
                        Divider()
                    }
                    if model.state.installs.isEmpty && model.devices.isEmpty {
                        PairingHelp()
                    }
                    HStack {
                        Button {
                            Task {
                                await model.loadDevices()
                                await model.checkInstalled()
                            }
                        } label: {
                            Label("Look Again", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.loadingDevices || model.activity.running)
                        if model.loadingDevices {
                            ProgressView().controlSize(.small)
                        }
                        if !model.pending.isEmpty {
                            Button("Finish the Update", action: model.retryPending).disabled(!model.canRun)
                        }
                        Spacer()
                        if let blocker = model.blocker {
                            Text(blocker).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            } label: {
                Text("Your Apple TVs").font(.headline)
            }
            HStack {
                Text("Before every install, the installer copies your worlds from the Apple TV to this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Show world backups in Finder", action: model.showWorldBackups)
            }
        }
    }

    private var gameStatus: String {
        guard !model.state.installs.isEmpty else {
            return "Not installed yet. The first build takes about 10 minutes."
        }
        return model.state.tag.map { "Version \($0) is installed." } ?? "Installed."
    }
}

/// What to do when no Apple TV is paired.
struct PairingHelp: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "appletv").font(.title2).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("No Apple TV is paired with this Mac").bold()
                Text("On the Apple TV: Settings > Remotes and Devices > Remote App and Devices. On this Mac: open Xcode, choose Window > Devices and Simulators, select the Apple TV and pair it with the code it shows. Keep the Apple TV awake, then press Look Again.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Xcode", action: model.openXcode)
        }
    }
}

/// A paired Apple TV without the game.
struct DeviceRow: View {
    @EnvironmentObject private var model: AppModel
    let device: Device

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: device.platform.symbol).font(.title2).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).bold()
                Text(device.model.isEmpty ? "Not installed" : "\(device.model) · not installed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Install") { model.add(device) }.disabled(!model.canRun)
        }
    }
}

struct InstallRow: View {
    @EnvironmentObject private var model: AppModel
    let install: Install

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: install.platform.symbol).font(.title2).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(install.deviceName).bold()
                Text(details).font(.caption).foregroundStyle(install.pending || expiringSoon ? .orange : .secondary)
            }
            Spacer()
            Button("Reinstall") { model.reinstall(install) }
                .disabled(!model.canRun)
                .help("Builds and installs it again. With a free Apple ID this renews the 7 days.")
            Menu {
                Button("Remove from List", role: .destructive) { model.forget(install) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var expiringSoon: Bool {
        install.expires.map { $0.timeIntervalSinceNow < 3 * 86400 } ?? false
    }

    private var details: String {
        var parts: [String] = []
        parts.append("Version \(install.version ?? "unknown")")
        if let now = model.reported[install.id], now != install.version {
            parts.append("reports: \(now)")
        }
        if let expires = install.expires {
            let date = expires.formatted(date: .abbreviated, time: .omitted)
            parts.append(expires < .now ? "stopped opening on \(date): Reinstall to renew" : "Opens until \(date)")
        }
        if install.pending {
            parts.append("the last update didn't reach it")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Updates

struct UpdatesScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Header(title: "Updates", subtitle: "New versions come from the project's releases on GitHub.")
            NewInstallerBanner()
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = model.releaseError {
                        Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                    }
                    if let latest = model.latest {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(latest.title).font(.title3.bold())
                                Text(status(latest)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.state.installs.isEmpty {
                                Button("Go to Game") { model.screen = .game }
                            } else {
                                Button("Update All", action: model.updateAll)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!model.updateAvailable || !model.canRun || model.newerInstaller != nil)
                            }
                        }
                        if let notes = latest.notes, !notes.isEmpty {
                            Divider()
                            Text((try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(notes))
                                .textSelection(.enabled)
                        }
                    } else if model.releaseError == nil {
                        Text("No release has been published yet.").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Check Again") {
                            Task { await model.loadReleases() }
                        }
                        Spacer()
                        Menu("Install Another Version…") {
                            ForEach(model.installable) { release in
                                Button(release.tag + (release.tag == model.state.tag ? " (built)" : "")) {
                                    model.install(release)
                                }
                            }
                        }
                        .fixedSize()
                        .disabled(model.installable.isEmpty || model.state.installs.isEmpty || !model.canRun
                                  || model.newerInstaller != nil)
                    }
                }
                .padding(8)
            } label: {
                Text("The game").font(.headline)
            }
        }
    }

    private func status(_ latest: Release) -> String {
        guard !model.state.installs.isEmpty, let tag = model.state.tag else {
            return "Install it on an Apple TV from the Game screen."
        }
        return model.updateAvailable ? "You have \(tag). Update All rebuilds it and reinstalls it on each of your Apple TVs, backing up your worlds first."
                                     : "You have the newest version."
    }
}

// MARK: - Activity

struct ActivityScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let activity = model.activity
        VStack(alignment: .leading, spacing: 14) {
            Header(title: activity.title.isEmpty ? "Activity" : activity.title,
                   subtitle: activity.title.isEmpty ? "Nothing has run yet." : "")
            if activity.running {
                VStack(alignment: .leading, spacing: 6) {
                    Text(activity.stage.isEmpty ? "Starting…" : activity.stage)
                    if let progress = activity.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            } else if let problem = activity.problem {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.message).bold()
                        if !problem.fix.isEmpty {
                            Text(problem.fix).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            } else if activity.cancelled {
                Text("Cancelled.").foregroundStyle(.secondary)
            } else if let finished = activity.finished {
                Label(finished, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            }
            ForEach(Array(activity.notes.enumerated()), id: \.offset) { note in
                Label(note.element, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if activity.running {
                    Button("Cancel", action: model.cancel)
                }
                Spacer()
                Button("Copy Diagnostics", action: model.copyDiagnostics).disabled(activity.log.isEmpty)
                Button("Show Logs") { NSWorkspace.shared.open(model.workspace.logs) }
            }
            GroupBox {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(activity.log.enumerated()), id: \.offset) { line in
                                Text(line.element)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .id(line.offset)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 280)
                    .onChange(of: activity.log.count) { _, count in
                        reader.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            } label: {
                Text("Details").font(.headline)
            }
        }
    }
}

struct Header: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            if !subtitle.isEmpty {
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
    }
}
