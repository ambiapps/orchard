import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    private(set) var pipelines: [PipelineRunner] = []
    private(set) var devices: [DiscoveredDevice]
    private(set) var isRefreshingDevices = false
    /// "Set up connected devices automatically", for a headless Mac. Off by default; while it's
    /// off nothing is paired, and no device is added to a pipeline, on its own.
    var setsUpDevicesAutomatically: Bool {
        didSet {
            guard setsUpDevicesAutomatically != oldValue else { return }
            defaults?.set(setsUpDevicesAutomatically, forKey: automaticSetupKey)
            log("Automatic device setup turned \(setsUpDevicesAutomatically ? "on" : "off")")
            if !setsUpDevicesAutomatically {
                onboardingTasks.values.forEach { $0.cancel() }
                onboardingTasks = [:]
                onboarding = [:]
                saveOnboarding()
                updateDevices()
            }
            updatePolling()
            updateActivity()
        }
    }
    /// Devices automatic setup is working on, by identifier. Saved, so a device that restarts to
    /// turn on Developer Mode is still finished after Orchard relaunches.
    private(set) var onboarding: [String: OnboardingState] = [:]

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let defaultsKey = "pipelines"
    @ObservationIgnored private let automaticSetupKey = "setsUpDevicesAutomatically"
    @ObservationIgnored private let onboardingKey = "onboardingDevices"
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private let discoversDevices: Bool
    @ObservationIgnored private let commands: DeviceOnboarding.Commands
    @ObservationIgnored private let deviceLog: DeviceLog?
    @ObservationIgnored private var physical: [PhysicalDevice] = []
    @ObservationIgnored private var simulators: [DiscoveredDevice] = []
    @ObservationIgnored private var onboardingTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastFailure: [String: String] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// How often connected devices are checked while automatic setup is on.
    static let devicePollInterval: Duration = .seconds(10)

    /// Tests pass `defaults: nil` to keep pipelines in memory, so they never read or overwrite
    /// the user's pipelines, and `discoversDevices: false` so they don't depend on the host's devices
    /// (optionally staging `devices` instead).
    /// `commands` are the devicectl calls automatic setup makes, and `deviceLog` where it logs
    /// (by default `devices.log`, or nowhere for an in-memory store).
    init(defaults: UserDefaults? = .standard, discoversDevices: Bool = true, devices: [DiscoveredDevice] = [],
         commands: DeviceOnboarding.Commands = .devicectl, deviceLog: DeviceLog? = nil) {
        self.defaults = defaults
        self.devices = devices
        self.discoversDevices = discoversDevices
        self.commands = commands
        self.deviceLog = deviceLog ?? (defaults == nil ? nil : .shared)
        setsUpDevicesAutomatically = defaults?.bool(forKey: automaticSetupKey) ?? false
        if setsUpDevicesAutomatically {
            // The real state comes with the first poll.
            for id in defaults?.stringArray(forKey: onboardingKey) ?? [] { onboarding[id] = .unreachable }
        }
        let configs = defaults?.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode([PipelineConfig].self, from: $0) } ?? []
        pipelines = configs.map(makeRunner)
        updateActivity()
        if discoversDevices { Task { await refreshDevices() } }
        updatePolling()
    }

    var anyEnabled: Bool { pipelines.contains { $0.config.isEnabled } }
    var anyBusy: Bool { pipelines.contains { $0.status.isBusy } }

    @discardableResult
    func addPipeline() -> PipelineRunner {
        var config = PipelineConfig()
        config.name = "Pipeline \(pipelines.count + 1)"
        let runner = makeRunner(config)
        pipelines.append(runner)
        save()
        return runner
    }

    func remove(_ runner: PipelineRunner) {
        runner.config.isEnabled = false
        pipelines.removeAll { $0.id == runner.id }
        save()
        Task { await runner.cleanUp() }
    }

    func refreshDevices() async {
        isRefreshingDevices = true
        await discoverDevices()
        isRefreshingDevices = false
    }

    private func discoverDevices() async {
        let found = await DeviceDiscovery.discover()
        simulators = found.simulators
        onboard(found.physical)
    }

    // MARK: Automatic setup

    /// Takes the physical devices devicectl reports and, with automatic setup on, moves each
    /// device being set up one step on. Runs on every poll, so a step that failed or is waiting
    /// for the person holding the device is tried again by itself.
    func onboard(_ physical: [PhysicalDevice]) {
        self.physical = physical
        defer { updateDevices() }
        guard setsUpDevicesAutomatically else { return }

        // An unpaired device that was unplugged is gone from the list; setup starts over when it's back.
        for id in onboarding.keys where !physical.contains(where: { $0.device.id == id }) {
            onboarding[id] = nil
            lastFailure[id] = nil
            saveOnboarding()
        }
        for device in physical {
            let id = device.device.id
            guard onboardingTasks[id] == nil else { continue }
            if onboarding[id] == nil {
                guard DeviceOnboarding.shouldStart(device) else { continue }
                log("\(device.device.name) (\(id)): connected by cable, setting it up")
            }
            let step = DeviceOnboarding.nextStep(for: device)
            switch step {
            case .wait(let state):
                setOnboarding(state, for: device)
            case .pair, .prepare:
                setOnboarding(step == .pair ? .waitingForTrust : .preparing, for: device)
                let command = step == .pair ? commands.pair : commands.prepare
                onboardingTasks[id] = Task { [weak self] in
                    let result = await Result { try await command(id) }
                    guard let self, !Task.isCancelled else { return }
                    self.onboardingTasks[id] = nil
                    self.finished(step, for: device, result: result)
                    self.updateDevices()
                }
            }
        }
    }

    /// Waits for the setup commands that are running. For tests.
    func onboardingSettled() async {
        for task in Array(onboardingTasks.values) { await task.value }
    }

    private func finished(_ step: DeviceOnboarding.Step, for device: PhysicalDevice, result: Result<Void, Error>) {
        let id = device.device.id
        switch result {
        case .failure(let error):
            let output = (error as? ShellError)?.output ?? error.localizedDescription
            // The same failure on every poll (Trust not tapped yet) is logged once.
            if lastFailure[id] != output {
                lastFailure[id] = output
                log("\(device.device.name): \(step == .pair ? "pairing" : "preparing") failed, will retry:\n\(output)")
            }
            setOnboarding(DeviceOnboarding.failureState(of: step, output: output), for: device)
        case .success where step == .pair:
            lastFailure[id] = nil
            log("\(device.device.name): paired")
        case .success:
            onboarding[id] = nil
            lastFailure[id] = nil
            saveOnboarding()
            log("\(device.device.name): ready. It can be unplugged; deploys reach it over Wi-Fi on this Mac's network")
            for runner in pipelines
            where runner.config.addsNewDevices && !runner.config.devices.contains(where: { $0.id == id }) {
                runner.config.devices.append(device.device)
                log("\(device.device.name): added to pipeline \(runner.config.name)")
                runner.deploy(toNew: device.device)
            }
        }
    }

    private func setOnboarding(_ state: OnboardingState, for device: PhysicalDevice) {
        guard onboarding[device.device.id] != state else { return }
        onboarding[device.device.id] = state
        saveOnboarding()
        log("\(device.device.name): \(state.label)")
    }

    private func saveOnboarding() {
        defaults?.set(onboarding.keys.sorted(), forKey: onboardingKey)
    }

    private func updateDevices() {
        devices = DeviceDiscovery.devices(physical: physical, simulators: simulators, onboarding: onboarding)
    }

    private func log(_ line: String) {
        deviceLog?.write(line)
    }

    /// Checks connected devices on a timer while automatic setup is on.
    private func updatePolling() {
        pollTask?.cancel()
        pollTask = nil
        guard setsUpDevicesAutomatically, discoversDevices else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.discoverDevices()
                try? await Task.sleep(for: Self.devicePollInterval)
            }
        }
    }

    func isConnected(_ device: Device) -> Bool {
        devices.first { $0.id == device.id }?.isConnected ?? false
    }

    private func makeRunner(_ config: PipelineConfig) -> PipelineRunner {
        // Only the real store keeps history on disk; tests' in-memory stores leave no files behind.
        let runner = PipelineRunner(
            config: config, history: defaults == nil ? nil : PipelineHistory(pipeline: config.id))
        runner.onChange = { [weak self] in
            self?.save()
            self?.updateActivity()
        }
        return runner
    }

    private func save() {
        let data = try? JSONEncoder().encode(pipelines.map(\.config))
        defaults?.set(data, forKey: defaultsKey)
    }

    /// Keeps App Nap from throttling the poll timers while any pipeline is enabled or devices are
    /// set up automatically.
    private func updateActivity() {
        let polls = anyEnabled || setsUpDevicesAutomatically
        if polls, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Watching branches and devices for changes")
        } else if !polls, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
