import Foundation

/// What the installer needs from a release's port.json, read from the tag before it's checked out: the
/// oldest installer that can build it, and the submodules to download (only those: the repository has
/// others that players never need, such as MCPE-1.1.5-decomp).
struct PortManifest: Equatable, Sendable {
    var version: String?
    /// port.json's minAppVersion, "1.0" read as "1.0.0".
    var minAppVersion: SemVer?
    var submodules: [String]

    init(version: String? = nil, minAppVersion: SemVer? = nil, submodules: [String] = []) {
        self.version = version
        self.minAppVersion = minAppVersion
        self.submodules = submodules
    }

    init?(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        version = json["version"] as? String
        minAppVersion = (json["minAppVersion"] as? String).flatMap(PortManifest.version)
        submodules = (json["submodules"] as? [Any] ?? []).compactMap { $0 as? String }.filter(PortManifest.isSafePath)
    }

    /// A version as port.json writes it: 1.0.0, or 1.0 for 1.0.0.
    static func version(_ text: String) -> SemVer? {
        let numeric = text.split(separator: "-", maxSplits: 1)[0]
        return SemVer(numeric.split(separator: ".").count == 2 ? numeric + ".0" + text.dropFirst(numeric.count) : text)
    }

    /// A path inside the repository: relative, without "..", and not an option.
    static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("-")
            && !path.split(separator: "/").contains("..")
    }
}
