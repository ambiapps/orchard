import Foundation

struct BuiltProduct: Hashable, Sendable, Codable {
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
    /// With `registering`, a device's hardware UDID, that device is the destination instead of
    /// the generic one: xcodebuild only registers its destination device with the team
    /// (`-allowProvisioningDeviceRegistration`), and a generic destination has none.
    static func build(
        container: String?, scheme: String, configuration: String, platform: BuildPlatform,
        registering udid: String? = nil,
        in checkout: URL, derivedData: URL,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> BuiltProduct {
        var common = containerArguments(container) + [
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", udid.map { "id=\($0)" } ?? platform.genericDestination,
            "-derivedDataPath", derivedData.path,
        ]
        if platform.needsDeviceProvisioning {
            common += ["-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration"]
        }

        removeCompilationCache(derivedData: derivedData)
        let buildStart = Date()
        try await Shell.run("/usr/bin/xcodebuild", common + buildSettingOverrides + ["build"],
                            in: checkout, onLine: log)

        // `-showBuildSettings` reloads the whole workspace, which can take a minute for big ones.
        let products = productsDirectory(derivedData: derivedData, configuration: configuration, platform: platform)
        if let product = builtApp(in: products, signedSince: buildStart) { return product }

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

    /// Build settings every build overrides.
    static let buildSettingOverrides = [
        // Deploys don't need dSYMs, and generating one for a large app takes tens of seconds.
        "DEBUG_INFORMATION_FORMAT=dwarf",
        // Each pipeline keeps its own DerivedData, so builds are already incremental, and Xcode
        // never trims the compilation cache: it grew to 20 GB for one pipeline.
        "COMPILATION_CACHE_ENABLE_CACHING=NO",
    ]

    /// Deletes the compilation cache that builds before caching was turned off left in
    /// `derivedData`, so upgraded Macs get the space back. Errors are ignored: it's only cleanup.
    static func removeCompilationCache(derivedData: URL) {
        try? FileManager.default.removeItem(at: compilationCache(derivedData: derivedData))
    }

    static func compilationCache(derivedData: URL) -> URL {
        derivedData.appendingPathComponent("CompilationCache.noindex", isDirectory: true)
    }

    /// The device platforms (not simulators) `scheme`'s app supports, from `SUPPORTED_PLATFORMS`.
    /// A builder with no devices of its own builds all of them for its clients. This reloads the
    /// workspace (`-showBuildSettings`), so it's only asked when there's no device to go by.
    static func supportedPlatforms(container: String?, scheme: String, in checkout: URL) async throws -> Set<BuildPlatform> {
        let output = try await Shell.run(
            "/usr/bin/xcodebuild", containerArguments(container) + ["-scheme", scheme, "-showBuildSettings", "-json"],
            in: checkout)
        guard let data = jsonPayload(in: output, opening: "[") else { throw XcodeError.noBuildSettings }
        let platforms = try supportedPlatforms(inBuildSettings: data, scheme: scheme)
        guard !platforms.isEmpty else { throw XcodeError.noSupportedPlatforms(scheme: scheme) }
        return platforms
    }

    /// The device platforms of the scheme's app target in `-showBuildSettings -json` output: the
    /// target named like the scheme, else the first app. Other apps (an embedded watch app) are
    /// built as part of it, not on their own. Mac Catalyst doesn't count as macOS.
    static func supportedPlatforms(inBuildSettings data: Data, scheme: String) throws -> Set<BuildPlatform> {
        let targets = try JSONDecoder().decode([TargetSettings].self, from: data)
        let apps = targets.filter { $0.buildSettings["WRAPPER_EXTENSION"] == "app" }
        guard let app = apps.first(where: { $0.target == scheme }) ?? apps.first else { return [] }
        var names = Set((app.buildSettings["SUPPORTED_PLATFORMS"] ?? "").split(separator: " ").map(String.init))
        // An iOS app that also runs as Mac Catalyst lists `macosx` too, but building it for
        // `platform=macOS` makes a Catalyst app nobody asked for, in a folder `builtApp` doesn't look in.
        if app.buildSettings["SUPPORTS_MACCATALYST"] == "YES" { names.remove("macosx") }
        return Set(BuildPlatform.allCases.filter { !$0.isSimulator && names.contains($0.platformName) })
    }

    /// Where xcodebuild puts products by default for `-derivedDataPath`.
    static func productsDirectory(derivedData: URL, configuration: String, platform: BuildPlatform) -> URL {
        let name = platform == .macOS ? configuration : "\(configuration)-\(platform.platformName)"
        return derivedData.appendingPathComponent("Build/Products/\(name)", isDirectory: true)
    }

    /// The one .app in `products` that was signed since `date`, i.e. by the build that just ran.
    /// Apps left over from earlier schemes or build settings aren't re-signed, so they're ignored.
    /// Nil when there's none (a no-op or unsigned build, a custom build folder) or several, so the
    /// caller asks xcodebuild instead.
    static func builtApp(in products: URL, signedSince date: Date) -> BuiltProduct? {
        let apps = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" && (signingDate(of: $0).map { $0 >= date } ?? false) } ?? []
        guard apps.count == 1, let app = apps.first else { return nil }
        guard let bundleID = bundleIdentifier(of: app) else { return nil }
        return BuiltProduct(appURL: app, bundleIdentifier: bundleID)
    }

    static func bundleIdentifier(of app: URL) -> String? {
        let info = ["Contents/Info.plist", "Info.plist"].lazy
            .compactMap { NSDictionary(contentsOf: app.appendingPathComponent($0)) }.first
        return info?["CFBundleIdentifier"] as? String
    }

    private static func signingDate(of app: URL) -> Date? {
        ["Contents/_CodeSignature/CodeResources", "_CodeSignature/CodeResources"].lazy.compactMap {
            try? FileManager.default.attributesOfItem(atPath: app.appendingPathComponent($0).path)[.modificationDate] as? Date
        }.first
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
    case noSupportedPlatforms(scheme: String)

    var errorDescription: String? {
        switch self {
        case .noBuildSettings:
            "Couldn't read build settings from xcodebuild."
        case .noAppProduct(let scheme, let platform):
            "Scheme “\(scheme)” doesn't produce a \(platform.displayName) app."
        case .productMissing(let url):
            "Build succeeded but \(url.path) is missing."
        case .noSupportedPlatforms(let scheme):
            "Scheme “\(scheme)” doesn't build an app for any device platform."
        }
    }
}
