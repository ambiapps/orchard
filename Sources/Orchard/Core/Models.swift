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

    /// Last commit successfully deployed to every device.
    var lastDeployedCommit: String?
    var lastDeployedAt: Date?
    /// Last commit a run was attempted for, so a broken commit isn't rebuilt on every poll.
    var lastAttemptedCommit: String?

    var repoURL: URL? { repoPath.map { URL(fileURLWithPath: $0) } }

    var missingSetup: String? {
        if repoPath == nil { return "Choose a repository" }
        if branch == nil { return "Choose a branch" }
        if scheme == nil { return "Choose a scheme" }
        if devices.isEmpty { return "Choose at least one device" }
        return nil
    }
}

enum DeployOutcome: Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed(String)
}

struct RunRecord: Identifiable, Sendable {
    let id = UUID()
    var commit: String
    var subject: String?
    var startedAt = Date()
    var finishedAt: Date?
    var outcome: DeployOutcome = .running
    var deviceOutcomes: [String: DeployOutcome] = [:]
    var logFile: URL?
}

struct LogLine: Identifiable, Sendable {
    enum Level: Sendable { case info, step, warning, error, success }
    let id = UUID()
    let date = Date()
    let level: Level
    let text: String
}

extension String {
    var shortSHA: String { String(prefix(8)) }
}
