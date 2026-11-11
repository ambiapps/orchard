import Foundation

/// Where `devicectl` comes from. Xcode's copy is a wrapper around the real one, which lives in
/// `/Library/Developer/PrivateFrameworks/CoreDevice.framework` and is installed by the
/// `XcodeSystemResources.pkg` inside Xcode. A Mac that only installs builds from a builder gets
/// that package from the builder, so it needs no Xcode.
enum DeviceSupport {
    enum Tool: Equatable, Sendable {
        /// Through `xcrun`, as Xcode intends.
        case xcode
        /// The real `devicectl`, run directly on a Mac without Xcode.
        case standalone
    }

    static let standalonePath =
        "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"

    /// How to run `devicectl` on this Mac; nil when it has neither Xcode nor the package.
    static func tool(developerDirectory: URL? = developerDirectory(),
                     standalonePath: String = standalonePath) -> Tool? {
        let fm = FileManager.default
        if let developerDirectory,
           fm.fileExists(atPath: developerDirectory.appendingPathComponent("usr/bin/devicectl").path) {
            return .xcode
        }
        return fm.fileExists(atPath: standalonePath) ? .standalone : nil
    }

    /// Whether this Mac has Xcode. Without it `/usr/bin/xcrun` and `/usr/bin/git` are stubs that
    /// ask the user to install developer tools, so nothing may call them.
    static var hasXcode: Bool { tool() == .xcode }

    /// The selected developer directory, if any. `xcode-select -p` only prints; it never prompts.
    static func developerDirectory() -> URL? {
        if let directory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !directory.isEmpty {
            return URL(fileURLWithPath: directory)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !path.isEmpty ? URL(fileURLWithPath: path) : nil
    }

    /// The package a builder hands to clients: the one its own Xcode installed `devicectl` from.
    static func package(developerDirectory: URL? = developerDirectory()) -> URL? {
        guard let package = developerDirectory?.deletingLastPathComponent()
            .appendingPathComponent("Resources/Packages/XcodeSystemResources.pkg"),
              FileManager.default.fileExists(atPath: package.path)
        else { return nil }
        return package
    }

    /// Whether `pkgutil --check-signature` says the package is Apple's own software. It's
    /// installed as root, so one that came over the network is checked first.
    static func isAppleSoftware(signature output: String) -> Bool {
        output.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == "Status: signed Apple Software"
        }
    }

    /// Installs a downloaded package after checking it's Apple's. Asks for an administrator password.
    static func install(_ package: URL) async throws {
        let signature = (try? await Shell.run("/usr/sbin/pkgutil", ["--check-signature", package.path])) ?? ""
        guard isAppleSoftware(signature: signature) else { throw BuilderError.notAppleSigned }
        try await Shell.run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script \"/usr/sbin/installer -pkg \" & quoted form of (item 1 of argv) & \" -target /\" with administrator privileges",
            "-e", "end run",
            package.path,
        ])
    }
}

struct DeviceSupportMissing: LocalizedError {
    var errorDescription: String? { "Device support isn't installed on this Mac." }
}

extension Shell {
    /// Runs `devicectl`, through Xcode when there is one.
    @discardableResult
    static func devicectl(_ arguments: [String],
                          onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        switch DeviceSupport.tool() {
        case .xcode: try await xcrun(["devicectl"] + arguments, onLine: onLine)
        case .standalone: try await run(DeviceSupport.standalonePath, arguments, onLine: onLine)
        case nil: throw DeviceSupportMissing()
        }
    }
}
