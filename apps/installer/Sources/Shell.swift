import Foundation

/// Runs a tool and hands its output to the main actor line by line: the build script, git, xcodebuild,
/// devicectl. One at a time per Shell; `cancel` stops the tool and everything it started.
final class Shell: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    /// PATH for the tools: the XcodeGen the installer downloaded, Homebrew's, then the system's.
    static func path(tools: URL) -> String {
        let xcodegen = tools.appendingPathComponent(XcodeGen.binFolder).path
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return [xcodegen, "/opt/homebrew/bin", "/usr/local/bin", base]
            .joined(separator: ":")
    }

    /// Runs `executable` with `arguments`; `onLine` gets each line, and whether it came from stderr.
    /// The exit status (-1 if it couldn't start).
    func run(_ executable: String, _ arguments: [String], in folder: URL? = nil, path: String? = nil,
             onLine: @escaping @MainActor (String, Bool) -> Void) async -> Int32 {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: executable)
        tool.arguments = arguments
        tool.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        if let path {
            environment["PATH"] = path
        }
        // git: no prompts (the repositories are public), and progress even without a terminal.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        tool.environment = environment
        let out = Pipe()
        let err = Pipe()
        tool.standardOutput = out
        tool.standardError = err
        tool.standardInput = FileHandle.nullDevice
        let outLines = LineReader { line in onLine(line, false) }
        let errLines = LineReader { line in onLine(line, true) }
        out.fileHandleForReading.readabilityHandler = { outLines.feed($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { errLines.feed($0.availableData) }
        lock.withLock { process = tool }
        return await withCheckedContinuation { continuation in
            tool.terminationHandler = { finished in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outLines.feed(out.fileHandleForReading.readDataToEndOfFile())
                errLines.feed(err.fileHandleForReading.readDataToEndOfFile())
                outLines.flush()
                errLines.flush()
                // After the lines: they're delivered on the main queue, in order.
                let status = finished.terminationStatus
                DispatchQueue.main.async {
                    continuation.resume(returning: status)
                }
            }
            do {
                try tool.run()
            } catch {
                tool.terminationHandler = nil
                Task { @MainActor in onLine("Couldn't run \(executable): \(error.localizedDescription)", true) }
                continuation.resume(returning: -1)
            }
        }
    }

    /// Runs a tool to the end and returns its stdout (nil if it failed).
    static func output(_ executable: String, _ arguments: [String], path: String? = nil) async -> String? {
        await Task.detached {
            let tool = Process()
            tool.executableURL = URL(fileURLWithPath: executable)
            tool.arguments = arguments
            if let path {
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = path
                tool.environment = environment
            }
            let pipe = Pipe()
            tool.standardOutput = pipe
            tool.standardError = FileHandle.nullDevice
            tool.standardInput = FileHandle.nullDevice
            guard (try? tool.run()) != nil else {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            tool.waitUntilExit()
            return tool.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }.value
    }

    func cancel() {
        guard let process = lock.withLock({ process }), process.isRunning else {
            return
        }
        Self.terminateTree(process.processIdentifier)
    }

    /// Stops `pid` and everything it started (xcodegen, xcodebuild, devicectl and their tools).
    static func terminateTree(_ pid: Int32) {
        let children = Process()
        children.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        children.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        children.standardOutput = pipe
        try? children.run()
        children.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for child in text.split(separator: "\n").compactMap({ Int32($0) }) {
            terminateTree(child)
        }
        kill(pid, SIGTERM)
    }
}

/// Splits a pipe's data into lines (at \n, and at \r, which git's progress uses) and hands each to the
/// main actor, through the main queue so they arrive in order (and before Shell.run returns).
final class LineReader: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let handle: @MainActor (String) -> Void

    init(_ handle: @escaping @MainActor (String) -> Void) {
        self.handle = handle
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        var lines: [String] = []
        lock.withLock {
            pending.append(data)
            while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                if !line.isEmpty {
                    lines.append(line)
                }
                pending.removeSubrange(pending.startIndex...end)
            }
        }
        deliver(lines)
    }

    func flush() {
        let rest: [String] = lock.withLock {
            defer { pending = Data() }
            return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
        }
        deliver(rest)
    }

    private func deliver(_ lines: [String]) {
        guard !lines.isEmpty else {
            return
        }
        let handle = handle
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for line in lines {
                    handle(line)
                }
            }
        }
    }
}
