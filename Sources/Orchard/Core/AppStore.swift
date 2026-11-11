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
    // MARK: Builder and client

    /// Builder: other Macs can download this Mac's builds. Off by default.
    var sharesBuilds: Bool {
        didSet {
            guard sharesBuilds != oldValue else { return }
            defaults?.set(sharesBuilds, forKey: sharesBuildsKey)
            pipelines.forEach { $0.sharesBuilds = sharesBuilds }
            // Clients must not keep getting builds this Mac no longer means to share.
            if !sharesBuilds, discoversDevices { SharedBuilds.removeAll() }
            updateServer()
            updateActivity()
        }
    }
    /// Why the builder isn't serving, e.g. its port is taken.
    private(set) var sharingError: String?
    /// What clients paste into their Settings: this Mac's address and the token.
    var sharingLink: String {
        BuilderLink.string(host: ProcessInfo.processInfo.hostName, port: BuilderLink.defaultPort, token: sharingToken)
    }

    enum BuilderStatus: Equatable {
        case none
        case invalidLink
        case connecting
        case connected(name: String, pipelines: Int)
        case failed(String)
    }
    /// Client: the link of the builder to install builds from; empty for none.
    var builderLink: String {
        didSet {
            guard builderLink != oldValue else { return }
            defaults?.set(builderLink, forKey: builderLinkKey)
            // Nothing changes while the link is edited without becoming another builder's.
            let link = BuilderLink(builderLink)
            guard link != BuilderLink(oldValue) || link == nil else { return }
            // Pipelines removed here come back when the link is entered again.
            if link?.baseURL != BuilderLink(oldValue)?.baseURL { knownRemotePipelines = [] }
            updateBuilder()
        }
    }
    var builderStatus: BuilderStatus = .none
    var builder: BuilderClient? { BuilderLink(builderLink).map(BuilderClient.init) }

    enum DeviceSupportState: Equatable {
        case installed
        case missing
        case installing
        case failed(String)
    }
    /// Whether this Mac can talk to devices: it has Xcode, or the package a builder hands out.
    var deviceSupport: DeviceSupportState = .installed
    /// False on a Mac that only installs a builder's builds. Checked once, at launch.
    let hasXcode: Bool
    /// Whether the builder can hand out that package.
    private(set) var builderHasDeviceSupport = false

    /// Devices automatic setup is working on, by identifier. Saved, so a device that restarts to
    /// turn on Developer Mode is still finished after Orchard relaunches.
    private(set) var onboarding: [String: OnboardingState] = [:]

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let defaultsKey = "pipelines"
    @ObservationIgnored private let automaticSetupKey = "setsUpDevicesAutomatically"
    @ObservationIgnored private let onboardingKey = "onboardingDevices"
    @ObservationIgnored private let sharesBuildsKey = "sharesBuilds"
    @ObservationIgnored private let sharingTokenKey = "sharingToken"
    @ObservationIgnored private let builderLinkKey = "builderLink"
    @ObservationIgnored private let knownRemoteKey = "knownBuilderPipelines"
    @ObservationIgnored private var server: BuildServer?
    @ObservationIgnored private var serverTask: Task<Void, Never>?
    @ObservationIgnored private var builderTask: Task<Void, Never>?
    @ObservationIgnored private lazy var sharingToken: String = {
        if let token = defaults?.string(forKey: sharingTokenKey) { return token }
        let token = BuilderLink.newToken()
        defaults?.set(token, forKey: sharingTokenKey)
        return token
    }()
    /// The builder's pipelines this Mac has added, so one the user deleted isn't added again.
    @ObservationIgnored private var knownRemotePipelines: Set<String> {
        get { Set(defaults?.stringArray(forKey: knownRemoteKey) ?? inMemoryKnownRemote) }
        set {
            inMemoryKnownRemote = Array(newValue)
            defaults?.set(newValue.sorted(), forKey: knownRemoteKey)
        }
    }
    @ObservationIgnored private var inMemoryKnownRemote: [String] = []

    /// How often a client asks its builder which pipelines it shares.
    static let builderPollInterval: Duration = .seconds(60)
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
        sharesBuilds = defaults?.bool(forKey: sharesBuildsKey) ?? false
        hasXcode = discoversDevices ? DeviceSupport.hasXcode : true
        builderLink = defaults?.string(forKey: builderLinkKey) ?? ""
        if setsUpDevicesAutomatically {
            // The real state comes with the first poll.
            for id in defaults?.stringArray(forKey: onboardingKey) ?? [] { onboarding[id] = .unreachable }
        }
        let configs = defaults?.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode([PipelineConfig].self, from: $0) } ?? []
        pipelines = configs.map(makeRunner)
        updateActivity()
        if discoversDevices {
            if DeviceSupport.tool() == nil { deviceSupport = .missing }
            Task { await refreshDevices() }
            updateServer()
            updateBuilder()
        }
        updatePolling()
    }

    /// Starts or stops serving builds. Only the real store serves; tests use `BuildServer` directly.
    private func updateServer() {
        guard discoversDevices else { return }
        serverTask?.cancel()
        server?.stop()
        server = nil
        sharingError = nil
        guard sharesBuilds else { return }
        let service = BuildService(name: Host.current().localizedName ?? "Builder", token: sharingToken,
                                   deviceSupport: DeviceSupport.package())
        serverTask = Task { [weak self] in
            // The port of a server that was just stopped takes a moment to come free, so a
            // quick off-and-on tries a few times before giving up.
            for attempt in 1...5 {
                do {
                    let server = try BuildServer(service: service, port: BuilderLink.defaultPort)
                    try await server.start()
                    guard let self, !Task.isCancelled, self.sharesBuilds else { return server.stop() }
                    self.server = server
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if attempt == 5 {
                        self?.sharingError = "Couldn't listen on port \(BuilderLink.defaultPort): \(error.localizedDescription)"
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// Follows the builder's list of shared pipelines while there's a link.
    private func updateBuilder() {
        builderTask?.cancel()
        builderTask = nil
        let builder = builder
        pipelines.forEach { $0.builder = builder }
        guard let builder else {
            builderStatus = builderLink.trimmingCharacters(in: .whitespaces).isEmpty ? .none : .invalidLink
            return
        }
        builderStatus = .connecting
        guard discoversDevices else { return }
        builderTask = Task { [weak self] in
            while !Task.isCancelled {
                let result: Result<BuildCatalog, Error>
                do { result = .success(try await builder.catalog()) } catch { result = .failure(error) }
                guard let self, !Task.isCancelled else { return }
                self.sync(with: result)
                try? await Task.sleep(for: Self.builderPollInterval)
            }
        }
    }

    /// Adds a pipeline for each one the builder shares that this Mac hasn't seen before. They
    /// start disabled, with no devices: the user picks devices and enables them.
    func sync(with result: Result<BuildCatalog, Error>) {
        switch result {
        case .failure(let error):
            builderStatus = .failed(error.localizedDescription)
        case .success(let catalog):
            builderStatus = .connected(name: catalog.builder, pipelines: catalog.pipelines.count)
            builderHasDeviceSupport = catalog.hasDeviceSupport
            var known = knownRemotePipelines
            for shared in catalog.pipelines where !known.contains(shared.id.uuidString) {
                known.insert(shared.id.uuidString)
                guard !pipelines.contains(where: { $0.config.remoteID == shared.id }) else { continue }
                var config = PipelineConfig()
                config.name = shared.name
                config.remoteID = shared.id
                pipelines.append(makeRunner(config))
                save()
            }
            if known != knownRemotePipelines { knownRemotePipelines = known }
        }
    }

    /// Downloads the builder's device support package and installs it, so this Mac can install
    /// apps on devices without Xcode. Asks for an administrator password.
    func installDeviceSupport() {
        guard deviceSupport != .installing, let builder else { return }
        deviceSupport = .installing
        Task {
            let package = FileManager.default.temporaryDirectory
                .appendingPathComponent("orchard-device-support-\(UUID().uuidString).pkg")
            defer { try? FileManager.default.removeItem(at: package) }
            do {
                try await builder.downloadDeviceSupport(to: package)
                try await DeviceSupport.install(package)
                deviceSupport = DeviceSupport.tool() == nil ? .failed("The package installed, but devicectl is still missing.") : .installed
                log("Installed device support from the builder")
                await refreshDevices()
            } catch {
                let reason = (error as? ShellError).map { $0.output.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ?? error.localizedDescription
                deviceSupport = .failed(reason)
                log("Installing device support failed: \(reason)")
            }
        }
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
        // A failed listing says nothing about the devices: no physical ones are listed, as
        // before, but the ones being set up aren't forgotten.
        if let physical = found.physical {
            onboard(physical)
        } else {
            physical = []
            updateDevices()
        }
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
                // A retry keeps showing why the last try failed, instead of flipping to
                // "Preparing…" and back (and logging both) on every poll.
                switch (step, onboarding[id]) {
                case (.pair, _): setOnboarding(.waitingForTrust, for: device)
                case (_, .failed), (_, .developerModeOff): break
                default: setOnboarding(.preparing, for: device)
                }
                let command = step == .pair ? commands.pair : commands.prepare
                onboardingTasks[id] = Task { [weak self] in
                    let result: Result<Void, Error>
                    do {
                        try await command(id)
                        result = .success(())
                    } catch {
                        result = .failure(error)
                    }
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
        runner.sharesBuilds = sharesBuilds
        runner.builder = builder
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
        let polls = anyEnabled || setsUpDevicesAutomatically || sharesBuilds
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
