import Foundation

/// Where the installer keeps everything: ~/Library/Application Support/TVCraft Installer. One folder,
/// never inside the .app (writing there breaks its signature, a copy run from Downloads is read-only,
/// and a new download of the installer would lose it all), so replacing the installer changes nothing.
struct Workspace: Sendable {
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVCraft Installer", isDirectory: true)
    }

    /// The git checkout of the release being built, with the submodules its port.json lists.
    var source: URL { root.appendingPathComponent("source", isDirectory: true) }
    /// scripts/tvcraft.py's --work-dir: the prepared APK, the build, the world backups; kept across updates.
    var work: URL { root.appendingPathComponent("work", isDirectory: true) }
    /// The worlds the engine copies off the Apple TV before every install.
    var worldBackups: URL { work.appendingPathComponent("save-backups", isDirectory: true) }
    /// The downloaded XcodeGen.
    var tools: URL { root.appendingPathComponent("tools", isDirectory: true) }
    var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    var stateFile: URL { root.appendingPathComponent("state.json") }
    var releasesCache: URL { root.appendingPathComponent("cache/releases.json") }
    /// The build engine, from the checked-out release.
    var engine: URL { source.appendingPathComponent("scripts/tvcraft.py") }
    /// What Setup → Storage → Free Up Space deletes: the Xcode build (the engine's -derivedDataPath),
    /// which the next build makes again.
    var rebuildable: URL { work.appendingPathComponent("build", isDirectory: true) }

    /// What the folder takes on disk (allocated bytes, so sparse and compressed files count as they
    /// are). 0 if it doesn't exist.
    func size() -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    func load() -> InstallerState {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder.installer.decode(InstallerState.self, from: data) else {
            return InstallerState()
        }
        return state
    }

    func save(_ state: InstallerState) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.installer.encode(state) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }
}

/// TVCraft runs on the Apple TV only.
enum Platform: String, Codable, CaseIterable, Identifiable, Sendable {
    case tvos

    var id: String { rawValue }
    var title: String { "Apple TV" }
    var symbol: String { "appletv" }
    /// devicectl's name for the platform.
    var devicePlatform: String { "tvOS" }
    /// xcodebuild's SDK.
    var sdk: String { "appletvos" }
    /// The name `xcodebuild -downloadPlatform` takes.
    var downloadName: String { "tvOS" }
}

/// An Apple TV the game is installed on.
struct Install: Codable, Identifiable, Hashable, Sendable {
    var platform: Platform = .tvos
    /// devicectl's identifier.
    var deviceId: String
    var deviceName: String
    var version: String?
    var commit: String?
    var installedAt: Date?
    /// When the development profile stops the app opening (7 days after the install with a free Apple ID).
    var expires: Date?
    /// The last update didn't reach it (it was off, or away): try again.
    var pending: Bool = false

    var id: String { platform.rawValue + ":" + deviceId }
}

/// What the installer remembers (state.json).
struct InstallerState: Codable, Sendable {
    /// The player's Minecraft PE 0.8.1 APK.
    var apk: String = ""
    /// The release tag the source is at, once fetched.
    var tag: String?
    var installs: [Install] = []

    mutating func record(_ install: Install) {
        if let index = installs.firstIndex(where: { $0.id == install.id }) {
            installs[index] = install
        } else {
            installs.append(install)
        }
    }
}

extension JSONEncoder {
    static var installer: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var installer: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
