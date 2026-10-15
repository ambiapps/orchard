import Foundation

struct BuiltProduct: Sendable {
    var appURL: URL
    var bundleIdentifier: String
}

enum Xcode {
    private static let skippedDirectories: Set<String> = [
        ".git", ".build", "build", "Pods", "Carthage", "node_modules", "DerivedData", ".swiftpm",
    ]

    /// Workspaces, projects and a root Package.swift, as paths relative to the repo root.
    /// Package.swift is reported as "" because xcodebuild needs no flag for it.
    static func findContainers(in repo: URL, maxDepth: Int = 3) -> [String] {
        var found: [String] = []
        let fm = FileManager.default

        func visit(_ dir: URL, relative: String, depth: Int) {
            guard let children = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in children.sorted() {
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                if name.hasSuffix(".xcworkspace") || name.hasSuffix(".xcodeproj") {
                    found.append(path)
                    continue // don't descend into the bundle (skips project.xcworkspace)
                }
                var isDir: ObjCBool = false
                if depth < maxDepth, !name.hasPrefix("."), !skippedDirectories.contains(name),
                   fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue {
                    visit(dir.appendingPathComponent(name), relative: path, depth: depth + 1)
                }
            }
        }
        visit(repo, relative: "", depth: 0)
        // Prefer workspaces (CocoaPods / multi-project setups), then shallower paths.
        found.sort {
            let a = ($0.hasSuffix(".xcworkspace") ? 0 : 1, $0.split(separator: "/").count, $0)
            let b = ($1.hasSuffix(".xcworkspace") ? 0 : 1, $1.split(separator: "/").count, $1)
            return a < b
        }
        if fm.fileExists(atPath: repo.appendingPathComponent("Package.swift").path) {
            found.append("")
        }
        return found
    }

    static func displayName(forContainer path: String?) -> String {
        guard let path, !path.isEmpty else { return "Package.swift" }
        return path
    }

    static func schemes(container: String?, in repo: URL) async throws -> [String] {
        let output = try await Shell.run(
            "/usr/bin/xcodebuild", ["-list", "-json"] + containerArguments(container), in: repo)
        guard let data = jsonPayload(in: output, opening: "{"),
              let list = try? JSONDecoder().decode(ListResponse.self, from: data)
        else { return [] }
        return (list.workspace ?? list.project)?.schemes ?? []
    }

    /// Builds `scheme` once for `platform` and returns the .app it produced.
    static func build(
        container: String?, scheme: String, configuration: String, platform: BuildPlatform,
        in checkout: URL, derivedData: URL,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> BuiltProduct {
        var common = containerArguments(container) + [
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", platform.genericDestination,
            "-derivedDataPath", derivedData.path,
        ]
        if !platform.isSimulator && platform != .macOS {
            common += ["-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration"]
        }

        try await Shell.run("/usr/bin/xcodebuild", common + ["build"], in: checkout, onLine: log)

        let settingsOutput = try await Shell.run(
            "/usr/bin/xcodebuild", common + ["-showBuildSettings", "-json"], in: checkout)
        guard let data = jsonPayload(in: settingsOutput, opening: "[")
        else { throw XcodeError.noBuildSettings }
        let targets = try JSONDecoder().decode([TargetSettings].self, from: data)

        let apps = targets.filter {
            $0.buildSettings["WRAPPER_EXTENSION"] == "app"
                && $0.buildSettings["PLATFORM_NAME"] == platform.platformName
        }
        // Prefer the target named like the scheme, which is the usual app target.
        guard let app = apps.first(where: { $0.target == scheme }) ?? apps.first,
              let dir = app.buildSettings["TARGET_BUILD_DIR"],
              let name = app.buildSettings["FULL_PRODUCT_NAME"],
              let bundleID = app.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"]
        else { throw XcodeError.noAppProduct(scheme: scheme, platform: platform) }

        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XcodeError.productMissing(url)
        }
        return BuiltProduct(appURL: url, bundleIdentifier: bundleID)
    }

    /// xcodebuild may print warnings before its JSON; skip to the first line that opens it.
    private static func jsonPayload(in output: String, opening: Character) -> Data? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.firstIndex(where: { $0.first == opening }) else { return nil }
        return lines[index...].joined(separator: "\n").data(using: .utf8)
    }

    private static func containerArguments(_ container: String?) -> [String] {
        guard let container, !container.isEmpty else { return [] }
        return [container.hasSuffix(".xcworkspace") ? "-workspace" : "-project", container]
    }

    private struct ListResponse: Decodable {
        struct Entry: Decodable { var schemes: [String]? }
        var project: Entry?
        var workspace: Entry?
    }

    private struct TargetSettings: Decodable {
        var target: String
        var buildSettings: [String: String]
    }
}

enum XcodeError: LocalizedError {
    case noBuildSettings
    case noAppProduct(scheme: String, platform: BuildPlatform)
    case productMissing(URL)

    var errorDescription: String? {
        switch self {
        case .noBuildSettings:
            "Couldn't read build settings from xcodebuild."
        case .noAppProduct(let scheme, let platform):
            "Scheme “\(scheme)” doesn't produce a \(platform.displayName) app."
        case .productMissing(let url):
            "Build succeeded but \(url.path) is missing."
        }
    }
}
