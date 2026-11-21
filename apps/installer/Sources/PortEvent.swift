import Foundation

/// One line of scripts/tvcraft.py --json: what the build script reports as it goes.
enum PortEvent: Equatable, Sendable {
    case stage(id: String, label: String)
    case progress(Double)
    case check(id: String, label: String, ok: Bool, detail: String, fix: String)
    case error(code: String, message: String, fix: String)
    case warning(String)
    case note(String)
    /// A finished build: the app, its version and commit, and (devices) when its profile expires.
    case result(app: String, version: String?, commit: String?, expires: Date?)
    case installed(present: Bool, version: String?, build: String?)
    case other(String)

    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = event["event"] as? String else {
            return nil
        }
        let text = { (key: String) in event[key] as? String ?? "" }
        switch kind {
        case "stage":
            self = .stage(id: text("id"), label: text("label"))
        case "progress":
            self = .progress((event["fraction"] as? NSNumber)?.doubleValue ?? 0)
        case "check":
            self = .check(id: text("id"), label: text("label"), ok: event["ok"] as? Bool ?? false,
                          detail: text("detail"), fix: text("fix"))
        case "error":
            self = .error(code: text("code"), message: text("message"), fix: text("fix"))
        case "warning":
            self = .warning(text("message"))
        case "note":
            self = .note(text("message"))
        case "result":
            let expires = (event["expires"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            self = .result(app: text("app"), version: event["version"] as? String, commit: event["commit"] as? String,
                           expires: expires)
        case "installed":
            self = .installed(present: event["present"] as? Bool ?? false, version: event["version"] as? String,
                              build: event["build"] as? String)
        default:
            self = .other(kind)
        }
    }
}
