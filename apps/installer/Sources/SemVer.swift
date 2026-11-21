import Foundation

/// A release version, as tags name them: 0.3.0, v0.3.0, 0.3.0-rc1. Compared as semantic versions: a
/// pre-release comes before its release, and pre-release parts compare numerically when both are numbers.
struct SemVer: Comparable, CustomStringConvertible, Hashable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        let main = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = main[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard numbers.count == 3, let major = numbers[0], let minor = numbers[1], let patch = numbers[2],
              major >= 0, minor >= 0, patch >= 0 else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = main.count > 1 ? main[1].split(separator: ".").map(String.init) : []
        if main.count > 1 && prerelease.isEmpty {
            return nil
        }
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false):
            return false
        case (false, true):
            return true
        case (false, false):
            for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
                switch (Int(x), Int(y)) {
                case let (i?, j?): return i < j
                case (.some, nil): return true  // numbers come before words
                case (nil, .some): return false
                case (nil, nil): return x < y
                }
            }
            return a.prerelease.count < b.prerelease.count
        }
    }
}
