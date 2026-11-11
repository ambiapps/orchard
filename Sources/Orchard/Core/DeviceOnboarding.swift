import Foundation

/// Where automatic setup is with one device. Shown on its row in the device list.
enum OnboardingState: Hashable, Sendable {
    /// Asked the device to pair; someone has to unlock it and tap Trust.
    case waitingForTrust
    /// Not paired yet and no longer on the cable, which pairing needs.
    case waitingForCable
    /// Paired, but Developer Mode is off. Only the person holding the device can turn it on.
    case developerModeOff
    /// Paired, but neither on the cable nor on this Mac's network.
    case unreachable
    /// Mounting the developer disk image.
    case preparing
    /// A step failed; it's tried again on the next poll.
    case failed(String)

    var label: String {
        switch self {
        case .waitingForTrust: "Unlock it and tap Trust"
        case .waitingForCable: "Connect it with a cable to pair"
        case .developerModeOff: "Turn on Developer Mode in Settings → Privacy & Security"
        case .unreachable: "Paired — connect it to this Mac's network to finish setup"
        case .preparing: "Preparing for development…"
        case .failed(let reason): "Setup failed, retrying: \(reason)"
        }
    }
}

/// The Mac-side steps that make a device plugged into a headless Mac deployable, with nobody at
/// the Mac: pair, then mount the developer disk image. Pairing over the cable is also what makes
/// the device installable over Wi-Fi afterwards: CoreDevice finds paired devices on the local
/// network by Bonjour and connects on demand, so there's nothing more to switch on.
enum DeviceOnboarding {
    enum Step: Equatable, Sendable {
        case pair
        case prepare
        case wait(OnboardingState)
    }

    /// Setup starts for a device that shows up unpaired on a cable. Devices that were already
    /// paired are the user's own and are left alone.
    static func shouldStart(_ device: PhysicalDevice) -> Bool {
        device.pairing != .paired && device.isWired
    }

    /// What to do next for a device being set up, from what devicectl reports about it.
    static func nextStep(for device: PhysicalDevice) -> Step {
        switch device.pairing {
        case .inProgress: return .wait(.waitingForTrust)
        case .unpaired: return device.isWired ? .pair : .wait(.waitingForCable)
        case .paired: break
        }
        if device.developerMode == false { return .wait(.developerModeOff) }
        if !device.isReachable { return .wait(.unreachable) }
        // Also the step for an unknown Developer Mode: mounting fails and says so if it's off.
        return .prepare
    }

    /// The state after a step failed with `output` from devicectl.
    static func failureState(of step: Step, output: String) -> OnboardingState {
        switch step {
        // Until Trust is tapped, pairing fails or times out. That's waiting, not an error.
        case .pair: return .waitingForTrust
        default:
            if output.localizedCaseInsensitiveContains("Developer Mode") { return .developerModeOff }
            let reason = output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty } ?? "unknown error"
            return .failed(reason)
        }
    }

    /// The devicectl commands, replaceable in tests. Each takes a device identifier.
    struct Commands: Sendable {
        typealias Command = @Sendable (String) async throws -> Void
        var pair: Command
        var prepare: Command

        static let devicectl = Commands(
            pair: { id in
                // Shows the Trust dialog on the device and waits for the answer.
                try await Shell.xcrun(["devicectl", "manage", "pair", "--device", id, "--timeout", "120"])
            },
            prepare: { id in
                // Connects to the device and mounts the developer disk image if it isn't.
                try await Shell.xcrun(
                    ["devicectl", "device", "info", "ddiServices", "--device", id, "--timeout", "120"])
            })
    }
}

/// `~/Library/Logs/Orchard/devices.log`: every step of automatic setup, for a Mac nobody looks at.
final class DeviceLog: Sendable {
    static let shared = DeviceLog(url: Paths.logs.appendingPathComponent("devices.log"))
    private let url: URL
    private let queue = DispatchQueue(label: "se.ambi.Orchard.DeviceLog")

    init(url: URL) { self.url = url }

    func write(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        queue.async { [url] in
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
        }
    }

    /// Waits for the lines written so far to reach the file.
    func flush() { queue.sync {} }
}
