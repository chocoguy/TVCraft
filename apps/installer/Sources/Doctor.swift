import Foundation

/// What the Setup screen checks before anything is built, and what each missing piece's button does.
struct DoctorItem: Identifiable, Sendable {
    enum Status: Sendable {
        case ok, missing, optional, checking
    }

    enum Action: Sendable, Hashable {
        case installXcode, openXcode, installXcodeGen, downloadPlatform(Platform), openAccounts
    }

    let id: String
    let title: String
    var status: Status
    var detail: String
    var action: Action?
    var actionTitle: String?
}

enum Doctor {
    /// The oldest XcodeGen already on the Mac that the installer uses instead of downloading its own:
    /// the version TVCraft's project.yml was tested with.
    static let minimumXcodeGen = SemVer(XcodeGen.version)!

    static func check(_ workspace: Workspace) async -> [DoctorItem] {
        var items: [DoctorItem] = []

        // Xcode, selected and set up (its first launch installs the parts builds need).
        let selected = await Shell.output("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let xcodeVersion = await Shell.output("/usr/bin/xcodebuild", ["-version"])?
            .split(separator: "\n").first.map(String.init)
        let major = xcodeVersion.flatMap { $0.split(separator: " ").last }.flatMap { Int($0.split(separator: ".")[0]) } ?? 0
        if selected == nil || selected!.contains("CommandLineTools") || xcodeVersion == nil {
            items.append(DoctorItem(id: "xcode", title: "Xcode 27", status: .missing,
                                    detail: "Install Xcode from the App Store. It's free, and about 10 GB.",
                                    action: .installXcode, actionTitle: "Open the App Store"))
        } else if major < 27 {
            items.append(DoctorItem(id: "xcode", title: "Xcode 27", status: .missing,
                                    detail: "\(xcodeVersion!) is installed; the game needs Xcode 27 or later. Update it in the App Store.",
                                    action: .installXcode, actionTitle: "Open the App Store"))
        } else if await Shell.output("/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"]) == nil {
            items.append(DoctorItem(id: "xcode", title: "Xcode 27", status: .missing,
                                    detail: "Open Xcode once and let it install its components (it asks for your password).",
                                    action: .openXcode, actionTitle: "Open Xcode"))
        } else {
            items.append(DoctorItem(id: "xcode", title: "Xcode 27", status: .ok, detail: xcodeVersion!))
        }
        let xcodeReady = items.last?.status == .ok

        // Python 3 comes with Xcode; the build engine runs on it.
        let python = await Shell.output("/usr/bin/python3", ["--version"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pythonMinor = python.flatMap { $0.split(separator: " ").last?.split(separator: ".").dropFirst().first }
            .flatMap { Int($0) } ?? 0
        items.append(DoctorItem(id: "python", title: "Python 3", status: python != nil && pythonMinor >= 9 ? .ok : .missing,
                                detail: python ?? "Comes with Xcode: install Xcode first."))

        // XcodeGen: the installer's own copy, or one already on this Mac that's new enough.
        if XcodeGen.installed(workspace) {
            items.append(DoctorItem(id: "xcodegen", title: "XcodeGen", status: .ok,
                                    detail: "XcodeGen \(XcodeGen.version), downloaded by the installer"))
        } else if let found = await onPath(workspace), found.version >= minimumXcodeGen {
            items.append(DoctorItem(id: "xcodegen", title: "XcodeGen", status: .ok, detail: "XcodeGen \(found.version) (\(found.path))"))
        } else {
            items.append(DoctorItem(id: "xcodegen", title: "XcodeGen", status: .missing,
                                    detail: "Makes the game's Xcode project. The installer downloads it from GitHub (about 5 MB).",
                                    action: .installXcodeGen, actionTitle: "Download"))
        }

        // The Apple TV platform: the only place the game runs.
        let sdks = xcodeReady ? await Shell.output("/usr/bin/xcodebuild", ["-showsdks", "-json"]) ?? "" : ""
        let platform = Platform.tvos
        let has = sdks.contains("\"\(platform.sdk)\"")
        items.append(DoctorItem(id: "platform-\(platform.rawValue)", title: "\(platform.downloadName) support in Xcode",
                                status: has ? .ok : .missing,
                                detail: has ? "Installed" : "Xcode needs it to build for the Apple TV (a few GB).",
                                action: has || !xcodeReady ? nil : .downloadPlatform(platform),
                                actionTitle: has ? nil : "Install"))

        // An Apple ID signed in to Xcode. A free one works: its installs open for 7 days.
        let teams = await xcodeTeams()
        let names = teams.map { ($0.name.isEmpty ? $0.id : "\($0.name) (\($0.id))") + ($0.free ? ", free" : "") }
        let freeNote = teams.contains(where: \.free)
            ? " With a free Apple ID, installs open for 7 days; Reinstall renews them." : ""
        items.append(DoctorItem(
            id: "account", title: "Apple ID in Xcode", status: teams.isEmpty ? .missing : .ok,
            detail: teams.isEmpty ? "Sign in to Xcode with your Apple ID (a free one works): Xcode > Settings > Accounts."
                                  : names.joined(separator: "; ") + "." + freeNote,
            action: teams.isEmpty && xcodeReady ? .openAccounts : nil, actionTitle: teams.isEmpty ? "Open Xcode" : nil))
        return items
    }

    /// An XcodeGen on PATH (Homebrew's, say), and its version.
    static func onPath(_ workspace: Workspace) async -> (path: String, version: SemVer)? {
        let path = Shell.path(tools: workspace.tools)
        guard let found = await Shell.output("/usr/bin/env", ["which", "xcodegen"], path: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !found.isEmpty,
              let text = await Shell.output(found, ["--version"], path: path),
              let range = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression),
              let version = SemVer(String(text[range])) else {
            return nil
        }
        return (found, version)
    }

    struct Team: Sendable {
        let id: String
        let name: String
        let free: Bool
    }

    /// The teams of the Apple IDs signed in to Xcode (as scripts/tvcraft.py reads them).
    static func xcodeTeams() async -> [Team] {
        guard let text = await Shell.output("/usr/bin/defaults", ["export", "com.apple.dt.Xcode", "-"]),
              let plist = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any],
              let byAccount = plist["IDEProvisioningTeamByIdentifier"] as? [String: Any] else {
            return []
        }
        var teams: [Team] = []
        for case let account as [[String: Any]] in byAccount.values {
            for team in account {
                guard let id = team["teamID"] as? String, !teams.contains(where: { $0.id == id }) else {
                    continue
                }
                teams.append(Team(id: id, name: team["teamName"] as? String ?? "",
                                  free: (team["isFreeProvisioningTeam"] as? Bool) ?? false))
            }
        }
        return teams
    }
}
