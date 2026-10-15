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
            try await Shell.xcrun(
                ["devicectl", "device", "install", "app", "--device", device.id, product.appURL.path],
                onLine: log)
            try await Shell.xcrun(
                ["devicectl", "device", "process", "launch", "--device", device.id,
                 "--terminate-existing", product.bundleIdentifier],
                onLine: log)
        case .simulator:
            try await Shell.xcrun(["simctl", "install", device.id, product.appURL.path], onLine: log)
            try await Shell.xcrun(
                ["simctl", "launch", "--terminate-running-process", device.id, product.bundleIdentifier],
                onLine: log)
        }
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
