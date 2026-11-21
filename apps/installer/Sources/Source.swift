import Foundation

/// The game's source: a git checkout of TVCraft at a release tag, with the submodules its port.json
/// lists (never the others). The repositories are public, so nothing asks for an account. Blobs are
/// fetched as needed (a partial clone), which keeps the first download small.
enum Source {
    static let url = "https://github.com/\(Releases.repository).git"
    static let git = "/usr/bin/git"

    static func exists(_ workspace: Workspace) -> Bool {
        FileManager.default.fileExists(atPath: workspace.source.appendingPathComponent(".git").path)
    }

    /// Brings the checkout up to date with GitHub: cloned the first time (without checking anything
    /// out, so no submodule either), then the tags fetched.
    static func fetchCommands(_ workspace: Workspace) -> [(label: String, arguments: [String])] {
        let folder = workspace.source.path
        var steps: [(String, [String])] = []
        if !exists(workspace) {
            steps.append(("Downloading the source",
                          ["clone", "--progress", "--filter=blob:none", "--no-checkout", url, folder]))
        }
        steps.append(("Looking for releases", ["-C", folder, "fetch", "--progress", "--force", "--tags", "--prune", "origin"]))
        return steps
    }

    /// Checks `tag` out (whatever was changed there goes) and brings `submodules` (port.json's list) to
    /// the tag's commits. Only those: a plain `submodule update` would download every submodule.
    static func checkoutCommands(_ tag: String, submodules: [String], _ workspace: Workspace) -> [(label: String, arguments: [String])] {
        let folder = workspace.source.path
        var steps: [(String, [String])] = [
            ("Switching to \(tag)", ["-C", folder, "-c", "advice.detachedHead=false", "checkout", "--force", "tags/\(tag)"]),
        ]
        guard !submodules.isEmpty else {
            return steps
        }
        steps.append(("Downloading the game code", ["-C", folder, "submodule", "sync", "--recursive", "--"] + submodules))
        steps.append(("Downloading the game code", ["-C", folder, "submodule", "update", "--init", "--recursive", "--force",
                                                    "--progress", "--filter=blob:none", "--"] + submodules))
        return steps
    }

    /// `tag`'s port.json, read from the fetched tag before it's checked out. Nil if it has none.
    static func manifest(for tag: String, in workspace: Workspace) async -> PortManifest? {
        guard let text = await Shell.output(git, ["-C", workspace.source.path, "show", "tags/\(tag):port.json"]) else {
            return nil
        }
        return PortManifest(Data(text.utf8))
    }

    /// git's progress lines ("Receiving objects:  45% (…)") as a fraction.
    static func progress(in line: String) -> Double? {
        guard line.contains("Receiving objects") || line.contains("Resolving deltas") || line.contains("Updating files"),
              let percent = line.range(of: #"(\d+)%"#, options: .regularExpression) else {
            return nil
        }
        return Double(line[percent].dropLast()).map { $0 / 100 }
    }
}

/// XcodeGen, which makes the game's Xcode project; downloaded once into the workspace, so a player
/// needs no Homebrew. Pinned, and checked against its SHA-256 (GitHub's digest for the release asset).
/// The zip is unpacked whole: xcodegen reads its presets from the share folder next to bin.
enum XcodeGen {
    static let version = "2.46.0"
    static let sha256 = "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
    static let url = URL(string: "https://github.com/yonaskolb/XcodeGen/releases/download/\(version)/xcodegen.zip")!
    /// Inside the workspace's tools folder.
    static let folder = "xcodegen-\(version)"
    static let binFolder = folder + "/xcodegen/bin"

    static func binary(_ workspace: Workspace) -> URL {
        workspace.tools.appendingPathComponent(binFolder + "/xcodegen")
    }

    static func installed(_ workspace: Workspace) -> Bool {
        FileManager.default.isExecutableFile(atPath: binary(workspace).path)
    }
}

/// A paired device devicectl can install on.
struct Device: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let model: String
    let platform: Platform

    var title: String { model.isEmpty ? name : "\(name) (\(model))" }

    /// The paired, physical devices of `platform`.
    static func list(_ platform: Platform) async -> [Device] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tvcraft-devices-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = await Shell.output("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", file.path])
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let entries = result["devices"] as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry -> Device? in
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = entry["deviceProperties"] as? [String: Any] ?? [:]
            guard hardware["platform"] as? String == platform.devicePlatform,
                  (hardware["reality"] as? String ?? "physical") == "physical",
                  let id = entry["identifier"] as? String else {
                return nil
            }
            return Device(id: id, name: properties["name"] as? String ?? id,
                          model: hardware["marketingName"] as? String ?? "", platform: platform)
        }
        .sorted { $0.name < $1.name }
    }
}
