import Foundation

struct ShellError: LocalizedError {
    let command: String
    let status: Int32
    let output: String

    var errorDescription: String? {
        let tail = output.split(separator: "\n").suffix(15).joined(separator: "\n")
        return "`\(command)` exited with status \(status)\n\(tail)"
    }
}

/// Runs command-line tools with the user's login-shell PATH, streaming output line by line.
enum Shell {
    /// PATH from the user's login shell, so build-phase tools (swiftlint, brew, mise, …) resolve
    /// the same way they do in Terminal even when the app is launched from Finder.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let path = String(data: data, encoding: .utf8), !path.isEmpty {
                env["PATH"] = path
            }
        }
        if env["PATH"].map({ !$0.contains("/usr/bin") }) ?? true {
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        env["NSUnbufferedIO"] = "YES"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }()

    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        in directory: URL? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let box = ProcessBox()
        let commandLine = ([executable] + arguments).joined(separator: " ")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                if let directory { process.currentDirectoryURL = directory }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice

                let collector = OutputCollector(onLine: onLine)
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        collector.append(data)
                    }
                }
                process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    let output = collector.finish()
                    if box.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(throwing: ShellError(
                            command: commandLine, status: process.terminationStatus, output: output))
                    }
                }
                do {
                    try process.run()
                    box.set(process)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    @discardableResult
    static func xcrun(_ arguments: [String], in directory: URL? = nil,
                      onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await run("/usr/bin/xcrun", arguments, in: directory, onLine: onLine)
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await run("/usr/bin/git", arguments, in: directory, onLine: onLine)
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var cancelled = false

    func set(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        if cancelled { process.terminate() }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        process?.terminate()
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        all.append(data)
        guard let onLine else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<newline]
            onLine(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
    }

    func finish() -> String {
        lock.lock(); defer { lock.unlock() }
        if let onLine, !pending.isEmpty {
            onLine(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
        return String(decoding: all, as: UTF8.self)
    }
}
