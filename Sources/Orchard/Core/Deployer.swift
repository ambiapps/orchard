import AppKit
import Foundation

enum Deployer {
    /// Installs the app on `device` and (re)launches it.
    static func deploy(_ product: BuiltProduct, to device: Device,
                       log: @escaping @Sendable (String) -> Void) async throws {
        switch device.kind {
        case .thisMac:
            try await deployToThisMac(product, log: log)
        case .physical:
            try await Shell.devicectl(
                ["device", "install", "app", "--device", device.id, product.appURL.path],
                onLine: log)
            try await launching {
                try await Shell.devicectl(
                    ["device", "process", "launch", "--device", device.id,
                     "--terminate-existing", product.bundleIdentifier],
                    onLine: log)
            }
        case .simulator:
            try await Shell.xcrun(["simctl", "install", device.id, product.appURL.path], onLine: log)
            try await launching {
                try await Shell.xcrun(
                    ["simctl", "launch", "--terminate-running-process", device.id, product.bundleIdentifier],
                    onLine: log)
            }
        }
    }

    /// Runs a launch command after a successful install, so its failure means "installed, not launched".
    static func launching(_ launch: () async throws -> Void) async throws {
        do {
            try await launch()
        } catch let error as ShellError {
            throw DeployError.launchFailed(launchFailureReason(error.output))
        }
    }

    /// Why a launch failed, from devicectl or simctl output.
    static func launchFailureReason(_ output: String) -> String {
        if output.contains("BSErrorCodeDescription = Locked") { return "the device was locked" }
        return output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? "unknown error"
    }

    private static func deployToThisMac(_ product: BuiltProduct,
                                        log: @escaping @Sendable (String) -> Void) async throws {
        if product.bundleIdentifier == Bundle.main.bundleIdentifier {
            log("Skipping relaunch: the built app is Orchard itself.")
            return
        }
        await terminateRunningInstances(of: product.bundleIdentifier, log: log)
        try await Shell.run("/usr/bin/open", ["-n", product.appURL.path], onLine: log)
    }

    @MainActor
    private static func terminateRunningInstances(of bundleID: String,
                                                  log: @Sendable (String) -> Void) async {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return }
        log("Quitting running \(bundleID)…")
        running.forEach { $0.terminate() }
        for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }
}

enum DeployError: LocalizedError, Equatable {
    /// The app was installed, but launching it failed.
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): "Installed, but failed to launch: \(reason)"
        }
    }
}
