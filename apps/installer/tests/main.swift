// tvcraft_installertest: the installer's logic without its UI. Prints each failed check and exits
// non-zero if any did.

import Foundation

var failures = 0

func check(_ condition: Bool, _ what: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(what)")
    }
}

// Versions: tags with or without v, pre-releases before their release, numeric parts compared as numbers.
check(SemVer("v0.3.0") == SemVer("0.3.0"), "v prefix")
check(SemVer("0.3") == nil && SemVer("0.3.0-") == nil && SemVer("x.1.0") == nil, "bad versions rejected")
check(SemVer("0.3.0-rc1")! < SemVer("0.3.0")!, "pre-release before release")
check(SemVer("0.3.0-rc.2")! < SemVer("0.3.0-rc.10")!, "numeric pre-release parts")
check(SemVer("0.2.9")! < SemVer("0.3.0")!, "minor beats patch")
check(SemVer("0.10.0")! > SemVer("0.9.0")!, "numbers, not text")
check(SemVer("1.0.0-alpha")! < SemVer("1.0.0-beta")!, "words compared as text")
check(SemVer("1.0.0-1")! < SemVer("1.0.0-alpha")!, "numbers before words")
check(SemVer("0.3.0-rc1")!.description == "0.3.0-rc1", "description")

// Releases: drafts never, pre-releases only when asked, non-version tags skipped, newest first.
let json = """
[
  {"tag_name": "v0.2.0", "name": "Second", "body": "Notes **two**", "prerelease": false, "draft": false,
   "published_at": "2026-12-01T00:00:00Z", "html_url": "https://example.invalid/2"},
  {"tag_name": "v0.3.0-rc1", "name": "", "body": null, "prerelease": true, "draft": false},
  {"tag_name": "v0.4.0", "name": "Draft", "body": "", "prerelease": false, "draft": true},
  {"tag_name": "nightly", "name": "Nightly", "body": "", "prerelease": false, "draft": false},
  {"tag_name": "v0.1.0", "name": "First", "body": "", "prerelease": false, "draft": false}
]
"""
do {
    let all = try Releases.parse(Data(json.utf8))
    check(all.count == 5, "all parsed")
    check(Releases.installable(all, prereleases: false).map(\.tag) == ["v0.2.0", "v0.1.0"], "installable")
    check(Releases.installable(all, prereleases: true).map(\.tag) == ["v0.3.0-rc1", "v0.2.0", "v0.1.0"], "with pre-releases")
    check(all[1].title == "v0.3.0-rc1", "empty name falls back to the tag")
    check(all[0].notes == "Notes **two**", "notes")
} catch {
    check(false, "releases parse: \(error)")
}

// Saved state: round trip, and recording replaces an install with the same ID.
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("installertest-\(UUID())")
let workspace = Workspace(root: folder)
var state = workspace.load()
check(state.installs.isEmpty && state.apk.isEmpty, "fresh state")
state.apk = "/Users/me/Downloads/Minecraft PE 0.8.1.apk"
state.tag = "v1.0.0"
state.record(Install(deviceId: "ABC", deviceName: "Living Room", version: "0.9.0"))
state.record(Install(deviceId: "DEF", deviceName: "Guest Room", version: "0.9.0",
                     expires: Date(timeIntervalSince1970: 1_900_000_000), pending: true))
state.record(Install(deviceId: "ABC", deviceName: "Living Room", version: "1.0.0"))
workspace.save(state)
let loaded = workspace.load()
check(loaded.installs.count == 2, "record replaces by ID")
check(loaded.installs.first { $0.deviceId == "ABC" }?.version == "1.0.0", "replaced version")
check(loaded.installs.allSatisfy { $0.platform == .tvos }, "Apple TV only")
check(loaded.installs.first { $0.deviceId == "DEF" }?.pending == true, "pending kept")
check(loaded.installs.first { $0.deviceId == "DEF" }?.expires == Date(timeIntervalSince1970: 1_900_000_000), "date kept")
check(loaded.tag == "v1.0.0" && loaded.apk == "/Users/me/Downloads/Minecraft PE 0.8.1.apk", "fields kept")
let saved = (try? String(contentsOf: workspace.stateFile, encoding: .utf8)) ?? ""
check(saved.contains("\"platform\" : \"tvos\"") && saved.contains("\"apk\""), "state.json keys")
check(workspace.engine.path.hasSuffix("/source/scripts/tvcraft.py"), "engine path")
check(workspace.worldBackups.path.hasSuffix("/work/save-backups"), "world backups path")
check(Workspace().root.path.hasSuffix("/Library/Application Support/TVCraft Installer"), "default workspace")
try? FileManager.default.removeItem(at: folder)

// port.json at a tag: the installer it needs, and the submodules to download (only those).
let manifest = PortManifest(Data("""
{"schema": 1, "version": "1.0.0", "minAppVersion": "1.0.0", "entry": "scripts/tvcraft.py",
 "submodules": ["MCPE-0.8.1-fortv"], "requirements": {"tools": ["xcodegen"]}}
""".utf8))
check(manifest == PortManifest(version: "1.0.0", minAppVersion: SemVer("1.0.0"), submodules: ["MCPE-0.8.1-fortv"]), "port.json")
check(PortManifest(Data(#"{"minAppVersion": "1.0"}"#.utf8))?.minAppVersion == SemVer("1.0.0"), "1.0 is 1.0.0")
check(PortManifest(Data(#"{"minAppVersion": "1.1-rc2"}"#.utf8))?.minAppVersion == SemVer("1.1.0-rc2"), "1.1-rc2 is 1.1.0-rc2")
check(PortManifest(Data(#"{"version": "1.0.0"}"#.utf8))?.submodules == [], "no submodules listed")
check(PortManifest(Data(#"{"submodules": ["a/b", "/abs", "-x", "../up", "x/../y", "", 3]}"#.utf8))?.submodules == ["a/b"],
      "unsafe submodule paths dropped")
check(PortManifest(Data("not json".utf8)) == nil, "not json")
if let real = try? Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../port.json").standardizedFileURL) {
    let parsed = PortManifest(real)
    check(parsed?.submodules == ["MCPE-0.8.1-fortv"], "the repository's port.json lists only MCPE-0.8.1-fortv")
    check(parsed?.minAppVersion != nil, "the repository's port.json has a minAppVersion")
}

// The build engine's events (scripts/tvcraft.py --json).
check(PortEvent(line: #"{"event": "stage", "id": "compile", "label": "Compiling the game"}"#)
      == .stage(id: "compile", label: "Compiling the game"), "stage")
check(PortEvent(line: #"{"event": "progress", "fraction": 0.5}"#) == .progress(0.5), "progress")
check(PortEvent(line: #"{"event": "error", "code": "x", "message": "M", "fix": "F"}"#)
      == .error(code: "x", message: "M", fix: "F"), "error")
check(PortEvent(line: #"{"event": "installed", "present": true, "version": "0.2.0", "build": "200"}"#)
      == .installed(present: true, version: "0.2.0", build: "200"), "installed")
if case let .result(app, version, commit, expires)? = PortEvent(line:
    #"{"event": "result", "app": "/w/build/Build/Products/Release-appletvos/TVCraft.app", "bundleId": "io.github.chocoguy.tvcraft.ABCDE12345", "version": "1.0.0", "commit": "abc1234", "platform": "tvos", "simulator": false, "team": "ABCDE12345", "expires": "2026-11-28T10:00:00+00:00", "free": true}"#) {
    check(app.hasSuffix("/TVCraft.app") && version == "1.0.0" && commit == "abc1234", "result fields")
    check(expires == ISO8601DateFormatter().date(from: "2026-11-28T10:00:00Z"), "result expiry")
} else {
    check(false, "result")
}
if case let .result(_, _, _, expires)? = PortEvent(line: #"{"event": "result", "app": "/A.app", "version": "1.0.0", "commit": null, "expires": null}"#) {
    check(expires == nil, "simulator result: no expiry")
} else {
    check(false, "result without expiry")
}
check(PortEvent(line: #"{"event": "installed", "present": false, "bundleId": "io.github.chocoguy.tvcraft.X"}"#)
      == .installed(present: false, version: nil, build: nil), "not installed")
check(PortEvent(line: #"{"event": "note", "message": "Installed. It opens until 2026-11-28"}"#)
      == .note("Installed. It opens until 2026-11-28"), "note")
check(PortEvent(line: #"{"event": "check", "id": "team", "label": "A signing team", "ok": true, "detail": "X", "fix": ""}"#)
      == .check(id: "team", label: "A signing team", ok: true, detail: "X", fix: ""), "check")
check(PortEvent(line: "not json") == nil, "plain lines aren't events")

print(failures == 0 ? "installertest: all passed" : "installertest: \(failures) failed")
exit(failures == 0 ? 0 : 1)
