import Foundation

/// The build platform a device needs. Several devices of the same platform share one build.
enum BuildPlatform: String, Codable, Hashable, CaseIterable, Sendable {
    case macOS
    case iOS
    case iOSSimulator
    case tvOS
    case tvOSSimulator
    case watchOS
    case watchOSSimulator
    case visionOS
    case visionOSSimulator

    var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .iOS: "iOS"
        case .iOSSimulator: "iOS Simulator"
        case .tvOS: "tvOS"
        case .tvOSSimulator: "tvOS Simulator"
        case .watchOS: "watchOS"
        case .watchOSSimulator: "watchOS Simulator"
        case .visionOS: "visionOS"
        case .visionOSSimulator: "visionOS Simulator"
        }
    }

    /// `xcodebuild -destination` value used to build once for every device of this platform.
    var genericDestination: String {
        switch self {
        case .macOS: "platform=macOS"
        default: "generic/platform=\(displayName)"
        }
    }

    /// `PLATFORM_NAME` build setting of products built for this platform.
    var platformName: String {
        switch self {
        case .macOS: "macosx"
        case .iOS: "iphoneos"
        case .iOSSimulator: "iphonesimulator"
        case .tvOS: "appletvos"
        case .tvOSSimulator: "appletvsimulator"
        case .watchOS: "watchos"
        case .watchOSSimulator: "watchsimulator"
        case .visionOS: "xros"
        case .visionOSSimulator: "xrsimulator"
        }
    }

    var isSimulator: Bool { rawValue.hasSuffix("Simulator") }

    /// Whether apps for this platform are signed with a profile that lists the devices they run on.
    var needsDeviceProvisioning: Bool { !isSimulator && self != .macOS }

    /// Maps devicectl / simctl platform names (`iOS`, `xrOS`, …) to a build platform.
    init?(devicePlatform: String, simulator: Bool) {
        switch (devicePlatform.lowercased(), simulator) {
        case ("ios", false), ("ipados", false): self = .iOS
        case ("ios", true), ("ipados", true): self = .iOSSimulator
        case ("tvos", false): self = .tvOS
        case ("tvos", true): self = .tvOSSimulator
        case ("watchos", false): self = .watchOS
        case ("watchos", true): self = .watchOSSimulator
        case ("visionos", false), ("xros", false): self = .visionOS
        case ("visionos", true), ("xros", true): self = .visionOSSimulator
        case ("macos", _): self = .macOS
        default: return nil
        }
    }
}

enum DeviceKind: String, Codable, Hashable, Sendable {
    case thisMac
    case physical
    case simulator
}

/// A deploy target. Stored in the pipeline so selections survive devices going offline.
struct Device: Codable, Hashable, Identifiable, Sendable {
    /// devicectl identifier for physical devices, simulator UDID, or "this-mac".
    var id: String
    var name: String
    var model: String
    var kind: DeviceKind
    var platform: BuildPlatform
    var osVersion: String
    /// Hardware UDID of a physical device, as provisioning profiles list it (`id` is devicectl's
    /// own identifier). Optional so devices saved before it existed decode.
    var udid: String?

    static let thisMac = Device(
        id: "this-mac",
        name: Host.current().localizedName ?? "This Mac",
        model: "This Mac",
        kind: .thisMac,
        platform: .macOS,
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString
    )

    var symbolName: String {
        switch kind {
        case .thisMac: return "desktopcomputer"
        case .simulator, .physical:
            switch platform {
            case .iOS, .iOSSimulator: return model.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone"
            case .tvOS, .tvOSSimulator: return "appletv"
            case .watchOS, .watchOSSimulator: return "applewatch"
            case .visionOS, .visionOSSimulator: return "visionpro"
            case .macOS: return "desktopcomputer"
            }
        }
    }
}

/// Everything the user configures for one repo → devices pipeline.
struct PipelineConfig: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name = "New Pipeline"
    /// Local clone the user picked. Orchard builds in its own worktree, never in this folder.
    var repoPath: String?
    var branch: String?
    /// Path of the .xcworkspace / .xcodeproj relative to the repo root, or nil for a root Package.swift.
    var containerPath: String?
    var scheme: String?
    var configuration = "Debug"
    var devices: [Device] = []
    var pollInterval: TimeInterval = 60
    var isEnabled = false
    /// How many builds the deploy list and log keep; nil means the default.
    /// Optional so older saved configs decode.
    var historyLimit: Int?
    var keptRuns: Int { max(1, historyLimit ?? 20) }

    /// Last commit installed on every device (launching it may have failed, e.g. on a locked phone).
    var lastDeployedCommit: String?
    var lastDeployedAt: Date?
    /// Last commit a run was attempted for, so a broken commit isn't rebuilt on every poll.
    var lastAttemptedCommit: String?

    /// The app the last successful run installed, so crash reports of it can be found and
    /// symbolicated after a relaunch. Optional so older saved configs decode.
    var deployedApps: [DeployedApp]?
    /// Crash reports written before this time are ignored: they predate watching this app.
    var crashesSince: Date?
    /// Keys (`CrashReports.key`) of crash reports already logged, newest last, capped at
    /// `CrashReports.reportedLimit`.
    var reportedCrashes: [String]?

    var repoURL: URL? { repoPath.map { URL(fileURLWithPath: $0) } }

    var missingSetup: String? {
        if repoPath == nil { return "Choose a repository" }
        if branch == nil { return "Choose a branch" }
        if scheme == nil { return "Choose a scheme" }
        if devices.isEmpty { return "Choose at least one device" }
        return nil
    }
}

struct DeployedApp: Codable, Hashable, Sendable {
    var platform: BuildPlatform
    var appPath: String
    var executableName: String
}

enum DeployOutcome: Equatable, Sendable, Codable {
    case pending
    case running
    case succeeded
    /// Installed, but launching it failed (e.g. the device was locked).
    case warning(String)
    case failed(String)
}

struct CommitSummary: Identifiable, Hashable, Sendable, Codable {
    var sha: String
    var author: String
    var subject: String
    var id: String { sha }
}

struct RunRecord: Identifiable, Sendable, Codable {
    var id = UUID()
    var commit: String
    var subject: String?
    /// Commit deployed before this run, which `changes` are counted from.
    var baseCommit: String?
    /// Commits since `baseCommit`, newest first; nil when unknown (first deploy, or git couldn't tell).
    var changes: [CommitSummary]?
    var startedAt = Date()
    var finishedAt: Date?
    var outcome: DeployOutcome = .running
    var deviceOutcomes: [String: DeployOutcome] = [:]
    var logFile: URL?
    var timings: RunTimings?
    /// The apps this run built, by `BuildPlatform` raw value, while they're still in DerivedData:
    /// building a platform again overwrites its app, so a newer run removes it from older ones.
    /// Optional so older saved runs decode.
    var products: [String: BuiltProduct]?

    func product(for platform: BuildPlatform) -> BuiltProduct? { products?[platform.rawValue] }

    /// A run saved while still going, which Orchard quit in the middle of.
    func interruptedIfUnfinished() -> RunRecord {
        guard outcome == .running else { return self }
        var run = self
        run.outcome = .failed("Interrupted")
        run.markUnfinishedDevices(.failed("Interrupted"))
        return run
    }

    /// Gives devices the run never finished with `outcome`, so they count as failed.
    mutating func markUnfinishedDevices(_ outcome: DeployOutcome) {
        deviceOutcomes = deviceOutcomes.mapValues { $0 == .running || $0 == .pending ? outcome : $0 }
    }

    /// The run's outcome once every device is done: failed if any device failed, otherwise a
    /// warning naming the devices the app was installed on but not launched.
    func finalOutcome(devices: [Device]) -> DeployOutcome {
        func matching(_ isMatch: (DeployOutcome) -> Bool) -> [Device] {
            devices.filter { deviceOutcomes[$0.id].map(isMatch) ?? false }
        }
        let failed = matching { if case .failed = $0 { true } else { false } }
        if !failed.isEmpty { return .failed("\(failed.count) of \(devices.count) device(s) failed") }
        let notLaunched = matching { if case .warning = $0 { true } else { false } }
        if !notLaunched.isEmpty {
            return .warning("Installed, but failed to launch on \(notLaunched.map(\.name).joined(separator: ", "))")
        }
        return .succeeded
    }
}

extension DeployOutcome {
    /// A device that didn't end up with the app running, so deploying again may help.
    var canRetry: Bool {
        switch self {
        case .failed, .warning: true
        default: false
        }
    }
}

extension [RunRecord] {
    /// Drops the apps of every run but `keeping`, because a new build overwrites what DerivedData
    /// holds: not just its own platform's app, but embedded ones too (an iOS build writes its
    /// watch app to the watchOS products folder).
    mutating func forgetProducts(keeping id: RunRecord.ID) {
        for index in indices where self[index].id != id && self[index].products != nil {
            self[index].products = nil
        }
    }
}

struct LogLine: Identifiable, Sendable, Codable {
    enum Level: String, Sendable, Codable { case info, step, warning, error, success }
    let id = UUID()
    var date = Date()
    let level: Level
    let text: String
    /// Marks the first line of a build, so the log can keep a number of builds.
    var startsRun: Bool?

    private enum CodingKeys: String, CodingKey { case date, level, text, startsRun }
}

extension [LogLine] {
    /// The lines from the start of the last `count` runs on.
    func keepingRuns(_ count: Int) -> [LogLine] {
        let starts = indices.filter { self[$0].startsRun == true }
        guard starts.count > count else { return self }
        return count == 0 ? [] : Array(self[starts[starts.count - count]...])
    }

    /// At most the newest `limit` lines, starting at a run when one starts among them, so a
    /// cut never leaves half a build at the top.
    func keepingLines(_ limit: Int) -> [LogLine] {
        guard count > limit else { return self }
        let kept = suffix(limit)
        guard let start = kept.firstIndex(where: { $0.startsRun == true }) else { return Array(kept) }
        return Array(self[start...])
    }
}

/// How long each phase of a run took, for the log.
struct RunTimings: Equatable, Sendable, Codable {
    var checkout: TimeInterval = 0
    var build: TimeInterval = 0
    var deploy: TimeInterval = 0

    /// "checkout 3s", "build 4m 10s", … for the phases that ran.
    var phases: [String] {
        [("checkout", checkout), ("build", build), ("deploy", deploy)]
            .filter { $0.1 > 0 }
            .map { "\($0.0) \($0.1.formattedDuration)" }
    }

    /// "4m 52s (checkout 3s, build 4m 10s, deploy 39s)".
    func summary(total: TimeInterval) -> String {
        phases.isEmpty ? total.formattedDuration
            : "\(total.formattedDuration) (\(phases.joined(separator: ", ")))"
    }
}

extension TimeInterval {
    /// "12s", "4m 10s" or "1h 5m".
    var formattedDuration: String {
        let seconds = Int(rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}

extension String {
    var shortSHA: String { String(prefix(8)) }
}
