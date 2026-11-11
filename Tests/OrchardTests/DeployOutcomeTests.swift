import Foundation
import Testing
@testable import Orchard

struct DeployOutcomeTests {
    private let phone = Device(id: "phone", name: "iPhone", model: "iPhone", kind: .physical,
                               platform: .iOS, osVersion: "26.0")
    private let pad = Device(id: "pad", name: "iPad", model: "iPad", kind: .physical,
                             platform: .iOS, osVersion: "26.0")

    private func run(_ outcomes: [String: DeployOutcome]) -> RunRecord {
        var run = RunRecord(commit: String(repeating: "a", count: 40))
        run.deviceOutcomes = outcomes
        return run
    }

    @Test func installedButNotLaunchedIsAWarningNotAFailure() {
        #expect(run([phone.id: .succeeded, pad.id: .succeeded]).finalOutcome(devices: [phone, pad]) == .succeeded)
        #expect(run([phone.id: .warning("locked"), pad.id: .succeeded]).finalOutcome(devices: [phone, pad])
            == .warning("Installed, but failed to launch on iPhone"))
        #expect(run([phone.id: .warning("locked"), pad.id: .warning("locked")]).finalOutcome(devices: [phone, pad])
            == .warning("Installed, but failed to launch on iPhone, iPad"))
        #expect(run([phone.id: .warning("locked"), pad.id: .failed("Build failed")]).finalOutcome(devices: [phone, pad])
            == .failed("1 of 2 device(s) failed"))
    }

    @Test func onlyAFailedLaunchCommandMeansInstalledNotLaunched() async {
        let locked = ShellError(command: "devicectl", status: 1, output: "BSErrorCodeDescription = Locked\n")
        await #expect(throws: DeployError.launchFailed("the device was locked")) {
            try await Deployer.launching { throw locked }
        }
        await #expect(throws: CancellationError.self) {
            try await Deployer.launching { throw CancellationError() }
        }
        await #expect(throws: CocoaError.self) {
            try await Deployer.launching { throw CocoaError(.fileNoSuchFile) }
        }
    }

    @Test func explainsALockedDevice() {
        // devicectl's output when the phone is locked (trimmed).
        let locked = """
            ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002 (0x2712))
                   BundleIdentifier = com.example.app
                       The operation couldn’t be completed. Unable to launch com.example.app because the device was not, or could not be, unlocked. (FBSOpenApplicationErrorDomain error 7 (0x07))
                       BSErrorCodeDescription = Locked
                       NSLocalizedFailureReason = Unable to launch com.example.app because the device was not, or could not be, unlocked.

            """
        #expect(Deployer.launchFailureReason(locked) == "the device was locked")
        #expect(Deployer.launchFailureReason("first\n  Something else went wrong  \n\n") == "Something else went wrong")
        #expect(DeployError.launchFailed("the device was locked").localizedDescription
            == "Installed, but failed to launch: the device was locked")
    }

    @Test func aNewBuildForgetsOlderRunsApps() {
        let app = BuiltProduct(appURL: URL(fileURLWithPath: "/tmp/App.app"), bundleIdentifier: "com.example.app")
        var older = run([:])
        // An iOS build can rewrite the watchOS folder too (an embedded watch app), so all go.
        older.products = [BuildPlatform.iOS.rawValue: app, BuildPlatform.watchOS.rawValue: app]
        var newer = run([:])
        newer.products = [BuildPlatform.iOS.rawValue: app]
        var runs = [newer, older]
        runs.forgetProducts(keeping: newer.id)
        #expect(runs[0].product(for: .iOS) == app)
        #expect(runs[1].products == nil)
    }

    @Test func devicesACancelledRunNeverReachedCountAsFailed() {
        var cancelled = run([phone.id: .failed("locked"), pad.id: .running, "mac": .pending])
        cancelled.markUnfinishedDevices(.failed("Cancelled"))
        #expect(cancelled.deviceOutcomes == [phone.id: .failed("locked"), pad.id: .failed("Cancelled"),
                                             "mac": .failed("Cancelled")])
        // So redeploying the phone alone can't make the run look deployed.
        cancelled.deviceOutcomes[phone.id] = .succeeded
        #expect(cancelled.finalOutcome(devices: [phone, pad]) == .failed("1 of 2 device(s) failed"))
    }

    @Test func runsSavedBeforeProductsStillDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","commit":"abc","startedAt":0,"outcome":{"succeeded":{}},"deviceOutcomes":{}}"#
        let run = try JSONDecoder().decode(RunRecord.self, from: Data(old.utf8))
        #expect(run.products == nil)
        #expect(run.product(for: .iOS) == nil)
    }

    @MainActor
    @Test func onlyAFailedDeviceWhoseBuildIsStillThereCanBeRedeployed() throws {
        let dir = try TemporaryDirectory()
        try dir.makeDirectories("App.app")
        let app = BuiltProduct(appURL: dir.url.appendingPathComponent("App.app"), bundleIdentifier: "com.example.app")
        let watch = Device(id: "watch", name: "Watch", model: "Apple Watch", kind: .physical,
                           platform: .watchOS, osVersion: "26.0")
        var failed = run([phone.id: .failed("Device not connected"), pad.id: .succeeded,
                          watch.id: .failed("Build failed")])
        failed.products = [BuildPlatform.iOS.rawValue: app]
        failed.finishedAt = Date()
        let runner = PipelineRunner(config: PipelineConfig())
        runner.runs = [failed]

        #expect(runner.canRedeploy(phone, from: failed))
        #expect(!runner.canRedeploy(pad, from: failed))  // Already running the build.
        #expect(!runner.canRedeploy(watch, from: failed))  // Nothing was built for it.
        var locked = failed
        locked.deviceOutcomes[phone.id] = .warning("the device was locked")
        #expect(runner.canRedeploy(phone, from: locked))
        try FileManager.default.removeItem(at: app.appURL)
        #expect(!runner.canRedeploy(phone, from: failed))  // The build is gone.
    }
}
