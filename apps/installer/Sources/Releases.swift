import Foundation

/// A GitHub release of TVCraft: its tag is the version the installer builds.
struct Release: Decodable, Identifiable, Hashable, Sendable {
    let tag: String
    let name: String?
    let notes: String?
    let prerelease: Bool
    let draft: Bool
    let published: String?
    let page: String?

    var id: String { tag }
    var version: SemVer? { SemVer(tag) }
    var title: String { (name?.isEmpty == false ? name : nil) ?? tag }

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", name, notes = "body", prerelease, draft, published = "published_at", page = "html_url"
    }
}

/// The releases on GitHub, through its public API (no account: 60 requests an hour per address, so
/// answers are cached and asked again with If-None-Match, which doesn't count when nothing changed).
enum Releases {
    static let repository = "chocoguy/TVCraft"

    /// The releases a player can install, newest first: drafts never, pre-releases only with
    /// `prereleases` (the hidden `includePrereleases` default, for testing release candidates). Only
    /// tags that are versions.
    static func installable(_ all: [Release], prereleases: Bool) -> [Release] {
        all.filter { !$0.draft && (prereleases || !$0.prerelease) && $0.version != nil }
            .sorted { $0.version! > $1.version! }
    }

    static func parse(_ data: Data) throws -> [Release] {
        try JSONDecoder().decode([Release].self, from: data)
    }

    /// The latest releases (up to 30), from the cache in `cacheFile` when GitHub says nothing changed.
    static func fetch(cacheFile: URL) async throws -> [Release] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TVCraftInstaller", forHTTPHeaderField: "User-Agent")
        let cached = try? Data(contentsOf: cacheFile)
        let etag = try? String(contentsOf: cacheFile.appendingPathExtension("etag"), encoding: .utf8)
        if cached != nil, let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 304, let cached {
            return try parse(cached)
        }
        guard status == 200 else {
            if let cached {
                return try parse(cached)  // offline or rate limited: the last answer
            }
            throw FetchError.status(status)
        }
        let releases = try parse(data)
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
        if let tag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") {
            try? tag.write(to: cacheFile.appendingPathExtension("etag"), atomically: true, encoding: .utf8)
        }
        return releases
    }

    enum FetchError: LocalizedError {
        case status(Int)

        var errorDescription: String? {
            switch self {
            case .status(403), .status(429): "GitHub is limiting requests from this network. Try again in an hour."
            case .status(let code): "GitHub answered \(code)."
            }
        }
    }
}
