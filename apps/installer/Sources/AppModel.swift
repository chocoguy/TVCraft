import AppKit
import CryptoKit
import Foundation

/// A failed step: what went wrong, and what to do about it. `code` is the engine's error code, if it
/// came from the engine.
struct Problem: Error, Sendable {
    let message: String
    let fix: String
    var code: String = ""
}

/// The job running now (or the last one): what the Activity screen shows.
struct Activity {
    var title = ""
    var running = false
    var stage = ""
    var progress: Double?
    var log: [String] = []
    var notes: [String] = []
    var problem: Problem?
    var finished: String?
    var cancelled = false
}

/// The installer: its saved state, the releases on GitHub, the setup checks, and every job (fetching
/// the source, building, installing, updating), run one at a time through scripts/tvcraft.py from the
/// release being built.
@MainActor
final class AppModel: ObservableObject {
    enum Screen: Hashable {
        case setup, game, updates, activity
    }

    /// The engine's error codes that mean the Apple TV couldn't be reached (off, asleep, away): the
    /// install is marked pending, and the job goes on with the others.
    static let unreachableCodes: Set<String> = ["device-unreachable", "device-asleep", "no-devices", "install-failed"]

    let workspace = Workspace()
    @Published var screen: Screen = .game
    @Published var state: InstallerState {
        didSet { workspace.save(state) }
    }
    @Published var releases: [Release] = []
    @Published var releaseError: String?
    @Published var doctor: [DoctorItem] = []
    @Published var checkingSetup = false
    @Published var activity = Activity()
    /// What each install reports now (tvcraft.py installed), by install ID: its version, "Not installed",
    /// or "Not reachable".
    @Published var reported: [String: String] = [:]
    /// A release needs this installer version or later (its port.json's minAppVersion).
    @Published var needsInstaller: SemVer?
    /// The Apple TVs paired with this Mac (devicectl).
    @Published var devices: [Device] = []
    @Published var loadingDevices = false

    private let shell = Shell()
    private var log: FileHandle?

    init() {
        state = workspace.load()
    }

    // MARK: What the screens ask

    var installerVersion: SemVer {
        SemVer(Bundle.main.object(forInfoDictionaryKey: "TVCraftVersion") as? String ?? "") ?? SemVer("0.0.1")!
    }

    /// Release candidates too (the hidden includePrereleases default, for testing them).
    var prereleases: Bool { UserDefaults.standard.bool(forKey: "includePrereleases") }

    var installable: [Release] { Releases.installable(releases, prereleases: prereleases) }
    var latest: Release? { installable.first }

    /// A newer release than the one installed.
    var updateAvailable: Bool {
        guard let latest = latest?.version, !state.installs.isEmpty else {
            return false
        }
        return state.tag.flatMap(SemVer.init).map { latest > $0 } ?? true
    }

    var setupReady: Bool { !doctor.isEmpty && !doctor.contains { $0.status == .missing } }
    var setupIssues: Int { doctor.filter { $0.status == .missing }.count }
    var pending: [Install] { state.installs.filter(\.pending) }
    var canRun: Bool { !activity.running && setupReady && !state.apk.isEmpty && (state.tag ?? latest?.tag) != nil }

    /// Paired Apple TVs the game isn't installed on yet.
    var newDevices: [Device] { devices.filter { device in !state.installs.contains { $0.deviceId == device.id } } }

    /// Why nothing can be installed yet, if so.
    var blocker: String? {
        if activity.running { return "Something is already running." }
        if !setupReady { return "Finish Setup first." }
        if state.apk.isEmpty { return "Choose your APK first." }
        if state.tag == nil && latest == nil { return releaseError ?? "No release found on GitHub yet." }
        return nil
    }

    // MARK: Start

    func start() {
        Task {
            await refresh()
            if !setupReady {
                screen = .setup
            } else if updateAvailable {
                screen = .updates
            }
        }
    }

    func refresh() async {
        await checkSetup()
        await loadReleases()
        await loadDevices()
        await checkInstalled()
    }

    func checkSetup() async {
        checkingSetup = true
        doctor = await Doctor.check(workspace)
        checkingSetup = false
    }

    func loadReleases() async {
        do {
            releases = try await Releases.fetch(cacheFile: workspace.releasesCache)
            releaseError = nil
        } catch {
            releaseError = "Couldn't reach GitHub: \(error.localizedDescription)"
        }
    }

    func loadDevices() async {
        loadingDevices = true
        devices = await Device.list(.tvos)
        loadingDevices = false
    }

    /// Asks each Apple TV what's there now (tvcraft.py installed), so the list stays honest when the app
    /// was deleted or installed some other way. Quietly: Apple TVs that are off just say so.
    func checkInstalled() async {
        guard FileManager.default.fileExists(atPath: workspace.engine.path) else {
            return
        }
        for install in state.installs {
            let arguments = ["-I", workspace.engine.path, "installed", "--device", install.deviceId] + engineOptions
            let output = await Shell.output("/usr/bin/python3", arguments, path: Shell.path(tools: workspace.tools))
            let event = output?.split(separator: "\n").compactMap { PortEvent(line: String($0)) }.last
            switch event {
            case .installed(true, let version, _):
                reported[install.id] = version ?? "Installed"
            case .installed(false, _, _):
                reported[install.id] = "Not installed"
            default:
                reported[install.id] = "Not reachable"
            }
        }
    }

    /// The options every engine command gets: the workspace's work folder, JSON events, and the
    /// installer's XcodeGen when it downloaded one (otherwise the engine finds one on PATH).
    private var engineOptions: [String] {
        var options = ["--work-dir", workspace.work.path, "--json"]
        if XcodeGen.installed(workspace) {
            options += ["--xcodegen", XcodeGen.binary(workspace).path]
        }
        return options
    }

    // MARK: Jobs

    /// Installs the game on an Apple TV, at the release already built (or the latest).
    func add(_ device: Device) {
        guard let tag = state.tag ?? latest?.tag else {
            return
        }
        let install = Install(deviceId: device.id, deviceName: device.name)
        run("Installing on \(install.deviceName)") {
            try await self.bringSource(to: tag)
            try await self.build(tag: tag, targets: [install])
        }
    }

    /// Builds and installs again: also how a free Apple ID's 7 days are renewed.
    func reinstall(_ install: Install) {
        guard let tag = state.tag ?? latest?.tag else {
            return
        }
        run("Reinstalling on \(install.deviceName)") {
            try await self.bringSource(to: tag)
            try await self.build(tag: tag, targets: [install])
        }
    }

    /// The latest release, everywhere the game is installed.
    func updateAll() {
        guard let latest else {
            return
        }
        install(latest, title: "Updating to \(latest.tag)")
    }

    /// `release` on every install: an update, or going back to an earlier version.
    func install(_ release: Release, title: String? = nil) {
        let targets = state.installs
        run(title ?? "Installing \(release.tag)") {
            try await self.bringSource(to: release.tag)
            try await self.build(tag: release.tag, targets: targets)
        }
    }

    func retryPending() {
        guard let tag = state.tag else {
            return
        }
        let targets = pending
        run("Finishing the update") {
            try await self.bringSource(to: tag)
            try await self.build(tag: tag, targets: targets)
        }
    }

    func forget(_ install: Install) {
        state.installs.removeAll { $0.id == install.id }
        reported[install.id] = nil
    }

    /// The worlds the engine backed up before each install, in Finder.
    func showWorldBackups() {
        try? FileManager.default.createDirectory(at: workspace.worldBackups, withIntermediateDirectories: true)
        NSWorkspace.shared.open(workspace.worldBackups)
    }

    func openXcode() {
        if let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
            NSWorkspace.shared.openApplication(at: xcode, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func downloadXcodeGen() {
        run("Downloading XcodeGen \(XcodeGen.version)") {
            self.step("Downloading XcodeGen from GitHub (about 5 MB)")
            let (file, response) = try await URLSession.shared.download(from: XcodeGen.url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Problem(message: "Couldn't download XcodeGen.", fix: "Check the internet connection and try again.")
            }
            self.step("Checking it")
            let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            guard digest == XcodeGen.sha256 else {
                throw Problem(message: "The XcodeGen download didn't match its checksum.", fix: "Try again; if it keeps failing, report it.")
            }
            self.step("Unpacking it")
            let folder = self.workspace.tools.appendingPathComponent(XcodeGen.folder, isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await self.tool("/usr/bin/ditto", ["-x", "-k", file.path, folder.path])
            guard XcodeGen.installed(self.workspace) else {
                throw Problem(message: "The XcodeGen download had no xcodegen in it.", fix: "Try again; if it keeps failing, report it.")
            }
            self.activity.finished = "XcodeGen \(XcodeGen.version) is ready."
            await self.checkSetup()
        }
    }

    func downloadPlatform(_ platform: Platform) {
        let name = platform.downloadName
        run("Installing \(name) support in Xcode") {
            self.step("Downloading \(name) support (a few GB)")
            try await self.tool("/usr/bin/xcodebuild", ["-downloadPlatform", name]) { line in
                if let percent = line.range(of: #"(\d+(\.\d+)?)%"#, options: .regularExpression) {
                    self.activity.progress = Double(line[percent].dropLast()).map { $0 / 100 }
                }
            }
            self.activity.finished = "\(name) support is installed."
            await self.checkSetup()
        }
    }

    func perform(_ action: DoctorItem.Action) {
        switch action {
        case .installXcode:
            NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/id497799835")!)
        case .openXcode, .openAccounts:
            openXcode()
        case .installXcodeGen:
            downloadXcodeGen()
        case .downloadPlatform(let platform):
            downloadPlatform(platform)
        }
    }

    func cancel() {
        guard activity.running else {
            return
        }
        activity.cancelled = true
        activity.stage = "Cancelling…"
        shell.cancel()
    }

    /// Everything a bug report needs, on the clipboard.
    func copyDiagnostics() {
        var lines = ["TVCraft Installer \(installerVersion)", "Source: \(state.tag ?? "none")", "APK: \(state.apk)", ""]
        lines += doctor.map { "\($0.status == .ok ? "ok" : "--") \($0.title): \($0.detail)" }
        lines += [""] + state.installs.map { "\($0.deviceName) (\($0.platform.rawValue)): \($0.version ?? "?") \($0.pending ? "pending" : "")" }
        lines += ["", "Last job: \(activity.title)"] + activity.log.suffix(300)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: Running a job

    private func run(_ title: String, _ body: @escaping @MainActor () async throws -> Void) {
        guard !activity.running else {
            return
        }
        activity = Activity(title: title, running: true)
        screen = .activity
        openLog(title)
        Task {
            do {
                try await body()
                if activity.finished == nil {
                    activity.finished = "Done."
                }
            } catch let problem as Problem {
                activity.problem = activity.cancelled ? nil : problem
            } catch {
                activity.problem = activity.cancelled ? nil : Problem(message: error.localizedDescription, fix: "")
            }
            activity.running = false
            activity.stage = ""
            activity.progress = nil
            try? log?.close()
            log = nil
            if activity.problem != nil || activity.finished != nil {
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
    }

    private func openLog(_ title: String) {
        try? FileManager.default.createDirectory(at: workspace.logs, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: ".")
        let file = workspace.logs.appendingPathComponent("\(stamp) \(title).log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        log = try? FileHandle(forWritingTo: file)
    }

    private func append(_ line: String) {
        activity.log.append(line)
        if activity.log.count > 4000 {
            activity.log.removeFirst(1000)
        }
        log?.write(Data((line + "\n").utf8))
    }

    private func step(_ label: String) {
        activity.stage = label
        activity.progress = nil
        append("==> " + label)
    }

    /// Runs a tool as part of the job; throws if it fails (or the job was cancelled).
    private func tool(_ executable: String, _ arguments: [String], in folder: URL? = nil,
                      onLine: (@MainActor (String) -> Void)? = nil) async throws {
        let status = await shell.run(executable, arguments, in: folder, path: Shell.path(tools: workspace.tools)) { line, _ in
            self.append(line)
            onLine?(line)
        }
        if activity.cancelled {
            throw CancellationError()
        }
        if status != 0 {
            throw Problem(message: "\(URL(fileURLWithPath: executable).lastPathComponent) stopped (status \(status)).",
                          fix: "The Details below say why. Copy Diagnostics to report it.")
        }
    }

    /// Runs scripts/tvcraft.py from the checked-out release, showing its events. Its result, if it made
    /// one. Never asked to launch anything.
    @discardableResult
    private func engine(_ arguments: [String]) async throws -> PortEvent? {
        var result: PortEvent?
        var failure: Problem?
        let all = ["-I", workspace.engine.path] + arguments + engineOptions
        let status = await shell.run("/usr/bin/python3", all, in: workspace.source, path: Shell.path(tools: workspace.tools)) { line, isError in
            guard !isError, let event = PortEvent(line: line) else {
                self.append(line)
                return
            }
            switch event {
            case .stage(_, let label):
                self.step(label)
            case .progress(let fraction):
                self.activity.progress = fraction
            case .error(let code, let message, let fix):
                failure = Problem(message: message, fix: fix, code: code)
                self.append("error: " + message)
            case .warning(let message), .note(let message):
                self.activity.notes.append(message)
                self.append(message)
            case .result:
                result = event
            default:
                break
            }
        }
        if activity.cancelled {
            throw CancellationError()
        }
        if status != 0 {
            throw failure ?? Problem(message: "The build engine stopped (status \(status)).",
                                     fix: "The Details below say why. Copy Diagnostics to report it.")
        }
        return result
    }

    /// Brings the source to `tag`: fetches it, reads its port.json (is this installer new enough, and
    /// which submodules it needs), then checks it and those submodules out. On a failure it goes back
    /// to the tag it was at.
    private func bringSource(to tag: String) async throws {
        let previous = state.tag
        for (label, arguments) in Source.fetchCommands(workspace) {
            step(label)
            try await tool(Source.git, arguments) { line in
                if let fraction = Source.progress(in: line) {
                    self.activity.progress = fraction
                }
            }
        }
        let manifest = await Source.manifest(for: tag, in: workspace)
        if let minimum = manifest?.minAppVersion, minimum > installerVersion {
            needsInstaller = minimum
            throw Problem(message: "\(tag) needs TVCraft Installer \(minimum) or later (this is \(installerVersion)).",
                          fix: "Choose TVCraft Installer → Check for Updates…, then try again.")
        }
        needsInstaller = nil
        guard previous != tag || !FileManager.default.fileExists(atPath: workspace.engine.path) else {
            return
        }
        let submodules = manifest?.submodules ?? []
        do {
            for (label, arguments) in Source.checkoutCommands(tag, submodules: submodules, workspace) {
                step(label)
                try await tool(Source.git, arguments) { line in
                    if let fraction = Source.progress(in: line) {
                        self.activity.progress = fraction
                    }
                }
            }
            state.tag = tag
        } catch {
            if let previous, !activity.cancelled {
                append("Going back to \(previous)")
                let before = await Source.manifest(for: previous, in: workspace)?.submodules ?? []
                for (_, arguments) in Source.checkoutCommands(previous, submodules: before, workspace) {
                    _ = await shell.run(Source.git, arguments, path: nil) { line, _ in self.append(line) }
                }
            }
            throw error
        }
    }

    /// Reads the APK (cached by the engine, so only the first time), then, for each Apple TV, builds
    /// `tag` for it (only the first build compiles; the others re-sign) and installs it without opening
    /// it. An Apple TV that can't be reached is marked pending, and the others go on.
    private func build(tag: String, targets: [Install]) async throws {
        try await engine(["prepare", "--disc", state.apk])
        var missed: [String] = []
        for target in targets {
            var install = target
            do {
                let built = try await engine(["build", "--platform", Platform.tvos.rawValue, "--disc", state.apk,
                                              "--device", target.deviceId])
                try await engine(["install", "--platform", Platform.tvos.rawValue, "--device", target.deviceId])
                if case let .result(_, version, commit, expires) = built {
                    install.version = version ?? tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                    install.commit = commit
                    install.expires = expires
                } else {
                    install.version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                }
            } catch let problem as Problem where Self.unreachableCodes.contains(problem.code) && !activity.cancelled {
                install.pending = true
                state.record(install)
                missed.append(target.deviceName)
                activity.notes.append("\(target.deviceName): \(problem.message) It's marked to finish later.")
                continue
            }
            install.installedAt = .now
            install.pending = false
            state.record(install)
            reported[install.id] = install.version
        }
        let names = targets.map(\.deviceName).filter { !missed.contains($0) }
        if names.isEmpty && !missed.isEmpty {
            throw Problem(message: "Couldn't reach \(missed.joined(separator: ", ")).",
                          fix: "Wake it with its remote, check it's paired in Xcode (Window > Devices and Simulators), then press Finish the Update.")
        }
        activity.finished = "TVCraft \(tag) is on " + names.joined(separator: ", ") + ". Open it from the Apple TV's Home screen." +
            (missed.isEmpty ? "" : " \(missed.joined(separator: ", ")) will be finished later.")
    }
}
