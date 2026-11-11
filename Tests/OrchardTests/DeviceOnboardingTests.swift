import Foundation
import Testing
@testable import Orchard

@MainActor
struct DeviceOnboardingTests {
    private func phone(_ pairing: PhysicalDevice.Pairing = .unpaired, wired: Bool = true, reachable: Bool = true,
                       developerMode: Bool? = nil, id: String = "phone") -> PhysicalDevice {
        PhysicalDevice(
            device: Device(id: id, name: "iPhone", model: "iPhone 17", kind: .physical, platform: .iOS,
                           osVersion: "27.0", udid: "00008160-0000"),
            pairing: pairing, isWired: wired, isReachable: reachable, isConnected: reachable,
            developerMode: developerMode)
    }

    /// Records the devicectl calls automatic setup makes, and fails the ones a test asks it to.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String] = []
        private var failure: String?
        var all: [String] { lock.withLock { made } }
        func fail(with output: String?) { lock.withLock { failure = output } }
        func record(_ call: String) throws {
            try lock.withLock {
                made.append(call)
                if let failure { throw ShellError(command: call, status: 1, output: failure) }
            }
        }
        var commands: DeviceOnboarding.Commands {
            .init(pair: { try self.record("pair \($0)") }, prepare: { try self.record("prepare \($0)") })
        }
    }

    private func makeStore(_ calls: Calls, automatic: Bool, log: DeviceLog? = nil) -> AppStore {
        let store = AppStore(defaults: nil, discoversDevices: false, commands: calls.commands, deviceLog: log)
        store.setsUpDevicesAutomatically = automatic
        return store
    }

    // MARK: State machine

    @Test func startsOnlyForUnpairedDevicesOnACable() {
        #expect(DeviceOnboarding.shouldStart(phone(.unpaired, wired: true)))
        #expect(!DeviceOnboarding.shouldStart(phone(.unpaired, wired: false)))
        // Devices the user paired themself are theirs to manage.
        #expect(!DeviceOnboarding.shouldStart(phone(.paired, wired: true)))
    }

    @Test func stepsFollowWhatTheDeviceReports() {
        #expect(DeviceOnboarding.nextStep(for: phone(.unpaired, wired: true)) == .pair)
        #expect(DeviceOnboarding.nextStep(for: phone(.unpaired, wired: false)) == .wait(.waitingForCable))
        #expect(DeviceOnboarding.nextStep(for: phone(.inProgress)) == .wait(.waitingForTrust))
        #expect(DeviceOnboarding.nextStep(for: phone(.paired, developerMode: false)) == .wait(.developerModeOff))
        #expect(DeviceOnboarding.nextStep(for: phone(.paired, wired: false, reachable: false, developerMode: true))
                == .wait(.unreachable))
        #expect(DeviceOnboarding.nextStep(for: phone(.paired, developerMode: true)) == .prepare)
        // Unplugged but on the network, and Developer Mode not reported yet: preparing finds out.
        #expect(DeviceOnboarding.nextStep(for: phone(.paired, wired: false, developerMode: nil)) == .prepare)
    }

    @Test func failuresBecomeStatesThatAreRetried() {
        #expect(DeviceOnboarding.failureState(of: .pair, output: "ERROR: The user has not responded") == .waitingForTrust)
        #expect(DeviceOnboarding.failureState(
            of: .prepare, output: "ERROR: The operation failed since Developer Mode is turned off on the device.")
            == .developerModeOff)
        #expect(DeviceOnboarding.failureState(of: .prepare, output: "ERROR: boom\n  \n") == .failed("ERROR: boom"))
    }

    // MARK: The setting

    @Test func offByDefaultAndThenNothingIsPairedOrAdded() async {
        let calls = Calls()
        let store = AppStore(defaults: nil, discoversDevices: false, commands: calls.commands)
        #expect(!store.setsUpDevicesAutomatically)
        let runner = store.addPipeline()

        store.onboard([phone(.unpaired, wired: true), phone(.paired, developerMode: true, id: "paired")])
        await store.onboardingSettled()

        #expect(calls.all.isEmpty)
        #expect(store.onboarding.isEmpty)
        #expect(runner.config.devices.isEmpty)
        // As before: only this Mac and the paired device are listed, without a setup state.
        #expect(store.devices.map(\.id) == [Device.thisMac.id, "paired"])
        #expect(store.devices.allSatisfy { $0.onboarding == nil })
    }

    @Test func pairsPreparesAndAddsToPipelinesThatWantNewDevices() async {
        let calls = Calls()
        let store = makeStore(calls, automatic: true)
        let wanting = store.addPipeline()
        let other = store.addPipeline()
        other.config.deploysToNewDevices = false

        // Plugged in: pairing is asked for, and the device is listed while it waits.
        store.onboard([phone(.unpaired, wired: true)])
        #expect(store.onboarding["phone"] == .waitingForTrust)
        #expect(store.devices.first { $0.id == "phone" }?.onboarding == .waitingForTrust)
        await store.onboardingSettled()
        #expect(calls.all == ["pair phone"])
        #expect(wanting.config.devices.isEmpty)

        // Trusted, and already unplugged: the rest happens over the network.
        store.onboard([phone(.paired, wired: false, developerMode: true)])
        #expect(store.onboarding["phone"] == .preparing)
        await store.onboardingSettled()
        #expect(calls.all == ["pair phone", "prepare phone"])
        #expect(store.onboarding.isEmpty)
        #expect(wanting.config.devices.map(\.id) == ["phone"])
        #expect(other.config.devices.isEmpty)

        // Done: later polls leave it alone and don't add it twice.
        store.onboard([phone(.paired, wired: false, developerMode: true)])
        await store.onboardingSettled()
        #expect(calls.all.count == 2)
        #expect(wanting.config.devices.count == 1)
    }

    @Test func leavesAlreadyPairedDevicesAlone() async {
        let calls = Calls()
        let store = makeStore(calls, automatic: true)
        let runner = store.addPipeline()
        store.onboard([phone(.paired, wired: true, developerMode: true)])
        await store.onboardingSettled()
        #expect(calls.all.isEmpty)
        #expect(runner.config.devices.isEmpty)
    }

    @Test func retriesPairingOnEveryPollUntilTrusted() async {
        let calls = Calls()
        let store = makeStore(calls, automatic: true)
        calls.fail(with: "ERROR: The device is locked")
        for _ in 0..<2 {
            store.onboard([phone(.unpaired, wired: true)])
            await store.onboardingSettled()
            #expect(store.onboarding["phone"] == .waitingForTrust)
        }
        #expect(calls.all == ["pair phone", "pair phone"])
    }

    @Test func waitsForDeveloperModeAndCarriesOn() async {
        let calls = Calls()
        let store = makeStore(calls, automatic: true)
        let runner = store.addPipeline()
        store.onboard([phone(.unpaired, wired: true)])
        await store.onboardingSettled()

        // devicectl doesn't know Developer Mode yet; mounting the disk image says it's off.
        calls.fail(with: "ERROR: The operation failed since Developer Mode is turned off on the device.")
        store.onboard([phone(.paired, developerMode: nil)])
        await store.onboardingSettled()
        #expect(store.onboarding["phone"] == .developerModeOff)

        // Reported off: nothing to run, just wait.
        store.onboard([phone(.paired, developerMode: false)])
        await store.onboardingSettled()
        #expect(calls.all == ["pair phone", "prepare phone"])
        #expect(runner.config.devices.isEmpty)

        // Turned on (the device restarted): setup finishes by itself.
        calls.fail(with: nil)
        store.onboard([phone(.paired, wired: false, developerMode: true)])
        await store.onboardingSettled()
        #expect(store.onboarding.isEmpty)
        #expect(runner.config.devices.map(\.id) == ["phone"])
    }

    @Test func aFailedStepIsShownAndRetried() async {
        let calls = Calls()
        let store = makeStore(calls, automatic: true)
        let runner = store.addPipeline()
        store.onboard([phone(.unpaired, wired: true)])
        await store.onboardingSettled()

        calls.fail(with: "ERROR: The developer disk image could not be mounted")
        store.onboard([phone(.paired, developerMode: true)])
        await store.onboardingSettled()
        #expect(store.onboarding["phone"] == .failed("ERROR: The developer disk image could not be mounted"))
        #expect(runner.config.devices.isEmpty)
        // The retry keeps the reason on the row rather than flipping back to "Preparing…".
        store.onboard([phone(.paired, developerMode: true)])
        #expect(store.onboarding["phone"] == .failed("ERROR: The developer disk image could not be mounted"))
        await store.onboardingSettled()

        calls.fail(with: nil)
        store.onboard([phone(.paired, developerMode: true)])
        await store.onboardingSettled()
        #expect(store.onboarding.isEmpty)
        #expect(runner.config.devices.map(\.id) == ["phone"])
    }

    @Test func unpluggingBeforeTrustStartsOverNextTime() async {
        let calls = Calls()
        let store = makeStore(calls, automatic: true)
        calls.fail(with: "ERROR: timed out")
        store.onboard([phone(.unpaired, wired: true)])
        await store.onboardingSettled()
        // An unpaired device that's unplugged disappears from devicectl's list.
        store.onboard([])
        #expect(store.onboarding.isEmpty)
        #expect(!store.devices.contains { $0.id == "phone" })
        store.onboard([phone(.unpaired, wired: true)])
        await store.onboardingSettled()
        #expect(calls.all == ["pair phone", "pair phone"])
    }

    @Test func turningTheSettingOffStopsSetup() async {
        let calls = Calls()
        let store = makeStore(calls, automatic: true)
        let runner = store.addPipeline()
        store.onboard([phone(.unpaired, wired: true)])
        await store.onboardingSettled()
        store.setsUpDevicesAutomatically = false
        #expect(store.onboarding.isEmpty)
        store.onboard([phone(.paired, developerMode: true)])
        await store.onboardingSettled()
        #expect(calls.all == ["pair phone"])
        #expect(runner.config.devices.isEmpty)
    }

    @Test func logsEveryStepOnceToTheDeviceLog() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("devices.log")
        let log = DeviceLog(url: url)
        let calls = Calls()
        let store = makeStore(calls, automatic: true, log: log)
        store.addPipeline()
        calls.fail(with: "ERROR: The device is locked")
        for _ in 0..<3 {
            store.onboard([phone(.unpaired, wired: true)])
            await store.onboardingSettled()
        }
        calls.fail(with: "ERROR: mount failed")
        for _ in 0..<3 {
            store.onboard([phone(.paired, wired: false, developerMode: true)])
            await store.onboardingSettled()
        }
        calls.fail(with: nil)
        store.onboard([phone(.paired, wired: false, developerMode: true)])
        await store.onboardingSettled()
        log.flush()

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("connected by cable, setting it up"))
        #expect(text.contains("Unlock it and tap Trust"))
        // The same failure on every poll isn't repeated.
        #expect(text.components(separatedBy: "The device is locked").count == 2)
        #expect(text.components(separatedBy: "Preparing for development").count == 2)
        #expect(text.components(separatedBy: "Setup failed, retrying: ERROR: mount failed").count == 2)
        #expect(text.contains("iPhone: ready"))
        #expect(text.contains("added to pipeline Pipeline 1"))
    }
}
