import Foundation
import Observation
import SystemConfiguration

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
            listedPipelines = nil
            listSharedPipelines()
            updateServer()
            updateActivity()
        }
    }
    /// Why the builder isn't serving, e.g. its port is taken.
    private(set) var sharingError: String?
    /// What clients paste into their Settings: this Mac's address.
    var sharingLink: String {
        BuilderLink.string(host: ProcessInfo.processInfo.hostName, port: BuilderLink.defaultPort)
    }
    /// Macs that may download this Mac's builds, and those waiting for the user to enter their code.
    private(set) var approvedClients: [ApprovedClient] = []
    private(set) var pairingRequests: [PairingRequest] = []

    enum BuilderStatus: Equatable {
        case none
        case invalidLink
        case connecting
        case connected(name: String, pipelines: Int)
        /// The builder's user has to enter `code` to approve this Mac.
        case awaitingApproval(code: String)
        /// The builder declined this Mac; `requestApprovalAgain()` starts over.
        case declined
        case failed(String)
    }
    /// Client: this Mac's token (and so its code), the same for every builder, so correcting a
    /// builder's host name keeps the approval.
    private(set) var builderIdentity: ClientIdentity {
        didSet { defaults?.set(try? JSONEncoder().encode(builderIdentity), forKey: builderIdentityKey) }
    }
    /// Client: the links of the builders to install builds from, one per row in Settings. A
    /// blank row is an empty string; there's always at least one row.
    var builderLinks: [String] {
        didSet {
            guard builderLinks != oldValue else { return }
            defaults?.set(builderLinks.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                          forKey: builderLinksKey)
            updateBuilders()
        }
    }
    /// What each builder last answered, by its link's address.
    private(set) var builderStatuses: [URL: BuilderStatus] = [:]
    /// The builders that can hand out the device support package.
    private(set) var deviceSupportBuilders: Set<URL> = []

    /// The usable links, each builder once.
    var builders: [BuilderLink] {
        var seen = Set<URL>()
        return builderLinks.compactMap(BuilderLink.init).filter { seen.insert($0.baseURL).inserted }
    }

    /// The state of one row in Settings.
    func builderStatus(for link: String) -> BuilderStatus {
        if link.trimmingCharacters(in: .whitespaces).isEmpty { return .none }
        guard let link = BuilderLink(link) else { return .invalidLink }
        return builderStatuses[link.baseURL] ?? .connecting
    }

    /// Removes a row. The builder's pipelines stay until the user deletes them, and those of
    /// its pipelines that were deleted earlier come back if its link is added again.
    func removeBuilderLink(at index: Int) {
        guard builderLinks.indices.contains(index) else { return }
        var links = builderLinks
        let removed = links.remove(at: index)
        if let address = BuilderLink(removed)?.baseURL, !links.compactMap(BuilderLink.init).contains(where: { $0.baseURL == address }) {
            knownRemotePipelines.subtract(catalogPipelines[address] ?? [])
        }
        builderLinks = links.isEmpty ? [""] : links
    }

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
    /// Whether a builder can hand out that package.
    var builderHasDeviceSupport: Bool { !deviceSupportBuilders.isEmpty }

    /// Devices automatic setup is working on, by identifier. Saved, so a device that restarts to
    /// turn on Developer Mode is still finished after Orchard relaunches.
    private(set) var onboarding: [String: OnboardingState] = [:]

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let defaultsKey = "pipelines"
    @ObservationIgnored private let automaticSetupKey = "setsUpDevicesAutomatically"
    @ObservationIgnored private let onboardingKey = "onboardingDevices"
    @ObservationIgnored private let sharesBuildsKey = "sharesBuilds"
    @ObservationIgnored private let approvedClientsKey = "approvedClients"
    @ObservationIgnored private let declinedClientsKey = "declinedClients"
    @ObservationIgnored private let builderIdentityKey = "builderIdentity"
    @ObservationIgnored private var lastRequestNotification: Date?
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    /// The one link of versions before there could be several; read once, never written.
    @ObservationIgnored private let builderLinkKey = "builderLink"
    @ObservationIgnored private let builderLinksKey = "builderLinks"
    @ObservationIgnored private let knownRemoteKey = "knownBuilderPipelines"
    @ObservationIgnored private var server: BuildServer?
    @ObservationIgnored private var serverTask: Task<Void, Never>?
    @ObservationIgnored private var builderTasks: [BuilderLink: Task<Void, Never>] = [:]
    /// The links being followed, to tell a new one from one that's still there.
    @ObservationIgnored private var followed: [BuilderLink] = []
    /// The pipelines each builder last listed, so removing a builder forgets only its own.
    @ObservationIgnored private var catalogPipelines: [URL: Set<String>] = [:]
    /// What `SharedPipelines.json` was last written with.
    @ObservationIgnored private var listedPipelines: [SharedBuilds.Listed]?
    /// Decides which clients the server lets in; lives as long as the store, across server restarts.
    @ObservationIgnored private(set) lazy var clientAccess: ClientAccess = ClientAccess(
        approved: defaults?.data(forKey: approvedClientsKey)
            .flatMap { try? JSONDecoder().decode([ApprovedClient].self, from: $0) } ?? [],
        declined: defaults?.stringArray(forKey: declinedClientsKey) ?? []
    ) { [weak self] request in
        Task { @MainActor in self?.accessChanged(newRequest: request) }
    }
    /// The builder's pipelines this Mac has added, so one the user deleted isn't added again.
    @ObservationIgnored private var knownRemotePipelines: Set<String> {
        get { Set(defaults?.stringArray(forKey: knownRemoteKey) ?? inMemoryKnownRemote) }
        set {
            inMemoryKnownRemote = Array(newValue)
            defaults?.set(newValue.sorted(), forKey: knownRemoteKey)
        }
    }
    @ObservationIgnored private var inMemoryKnownRemote: [String] = []

    /// How often a client asks each builder which pipelines it shares.
    static let builderPollInterval: Duration = .seconds(60)
    /// How often a client asks a builder while it waits for its user to approve it.
    static let approvalPollInterval: Duration = .seconds(3)
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
        let identity = defaults?.data(forKey: "builderIdentity")
            .flatMap { try? JSONDecoder().decode(ClientIdentity.self, from: $0) }
        builderIdentity = identity ?? .new(name: Self.computerName)
        setsUpDevicesAutomatically = defaults?.bool(forKey: automaticSetupKey) ?? false
        sharesBuilds = defaults?.bool(forKey: sharesBuildsKey) ?? false
        hasXcode = discoversDevices ? DeviceSupport.hasXcode : true
        let links = defaults?.stringArray(forKey: builderLinksKey)
            ?? [defaults?.string(forKey: builderLinkKey) ?? ""].filter { !$0.isEmpty }
        builderLinks = links.isEmpty ? [""] : links
        // Builders up to 1.0.15 let in anyone with this token; clients now have to be approved.
        defaults?.removeObject(forKey: "sharingToken")
        approvedClients = clientAccess.approvedClients
        if identity == nil { defaults?.set(try? JSONEncoder().encode(builderIdentity), forKey: builderIdentityKey) }
        if setsUpDevicesAutomatically {
            // The real state comes with the first poll.
            for id in defaults?.stringArray(forKey: onboardingKey) ?? [] { onboarding[id] = .unreachable }
        }
        let configs = defaults?.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode([PipelineConfig].self, from: $0) } ?? []
        pipelines = configs.map(makeRunner)
        // Saved when there could only be one builder: that's the one they're on.
        if builders.count == 1 {
            for runner in pipelines where runner.config.isRemote && runner.config.builderURL == nil {
                runner.config.builderURL = builders[0].baseURL.absoluteString
            }
        }
        updateActivity()
        if discoversDevices {
            if DeviceSupport.tool() == nil { deviceSupport = .missing }
            Task { await refreshDevices() }
            updateServer()
        }
        listSharedPipelines()
        updateBuilders()
        updatePolling()
    }

    /// Starts or stops serving builds. Only the real store serves; tests use `BuildServer` directly.
    private func updateServer() {
        guard discoversDevices else { return }
        serverTask?.cancel()
        server?.stop()
        server = nil
        sharingError = nil
        pruneTask?.cancel()
        pruneTask = nil
        guard sharesBuilds else { return }
        // Requests from Macs that stopped asking leave the list even when no other Mac asks.
        pruneTask = Task { [clientAccess] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                clientAccess.prune()
            }
        }
        let service = BuildService(name: Self.computerName, access: clientAccess,
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

    /// Tells clients which pipelines this builder has, so they show up there before their
    /// first build. Only pipelines that are set up, so a client doesn't get one that's still
    /// being created; pipelines this Mac itself gets from a builder aren't passed on.
    private func listSharedPipelines() {
        guard discoversDevices, sharesBuilds else { return }
        let list = pipelines.filter { !$0.config.isRemote && $0.config.missingSetup == nil }
            .map { SharedBuilds.Listed(id: $0.id, name: $0.config.name) }
        guard list != listedPipelines else { return }
        listedPipelines = list
        SharedBuilds.list(list)
    }

    /// Follows each builder's list of pipelines while its link is there.
    private func updateBuilders() {
        let links = builders
        for (link, task) in builderTasks where !links.contains(link) {
            task.cancel()
            builderTasks[link] = nil
        }
        let addresses = Set(links.map(\.baseURL))
        builderStatuses = builderStatuses.filter { addresses.contains($0.key) }
        deviceSupportBuilders.formIntersection(addresses)
        catalogPipelines = catalogPipelines.filter { addresses.contains($0.key) }
        // A new link, or a new token for the same address, hasn't been answered yet.
        for link in links where !followed.contains(link) { builderStatuses[link.baseURL] = .connecting }
        followed = links
        for link in links where builderTasks[link] == nil {
            guard discoversDevices else { continue }
            builderTasks[link] = Task { [weak self] in
                while !Task.isCancelled {
                    // Read each time: asking again after a decline changes the token.
                    guard let builder = self?.client(for: link) else { return }
                    let result: Result<BuildCatalog, Error>
                    do { result = .success(try await builder.catalog()) } catch { result = .failure(error) }
                    guard let self, !Task.isCancelled else { return }
                    self.sync(with: result, from: link)
                    // While the builder's user enters the code, the answer should come quickly.
                    let waiting = if case .awaitingApproval = self.builderStatuses[link.baseURL] { true } else { false }
                    try? await Task.sleep(for: waiting ? Self.approvalPollInterval : Self.builderPollInterval)
                }
            }
        }
        assignBuilders()
    }

    /// The builder a remote pipeline gets its builds from.
    private func builder(for config: PipelineConfig) -> BuilderClient? {
        guard config.isRemote else { return nil }
        let links = builders
        if let address = config.builderURL {
            return links.first { $0.baseURL.absoluteString == address }.map(client)
        }
        // Saved when there could only be one builder; `sync` records which it is.
        return links.count == 1 ? client(for: links[0]) : nil
    }

    func client(for link: BuilderLink) -> BuilderClient {
        BuilderClient(link: link, identity: builderIdentity)
    }

    private func assignBuilders() {
        for runner in pipelines {
            runner.builder = builder(for: runner.config)
            // Without a builder there's nothing to wait for.
            if runner.builder == nil, runner.remote != nil { runner.remote = nil }
        }
    }

    /// Takes a builder's answer: adds a pipeline for each of its pipelines this Mac hasn't seen
    /// before, and tells the ones it has what the builder has built. New ones start disabled,
    /// with no devices: the user picks devices and enables them.
    func sync(with result: Result<BuildCatalog, Error>, from link: BuilderLink) {
        guard builders.contains(link) else { return }
        switch result {
        case .failure(let error):
            builderStatuses[link.baseURL] = switch error {
            case BuilderError.awaitingApproval: .awaitingApproval(code: builderIdentity.code)
            case BuilderError.declined: .declined
            default: .failed(error.localizedDescription)
            }
            // What it had is no longer known, so its pipelines don't claim to wait for a build.
            for runner in pipelines where runner.config.builderURL == link.baseURL.absoluteString {
                runner.remote = nil
            }
        case .success(let catalog):
            let address = link.baseURL.absoluteString
            let addresses = Set(builders.map(\.baseURL.absoluteString))
            builderStatuses[link.baseURL] = .connected(name: catalog.builder, pipelines: catalog.pipelines.count)
            if catalog.hasDeviceSupport {
                deviceSupportBuilders.insert(link.baseURL)
            } else {
                deviceSupportBuilders.remove(link.baseURL)
            }
            catalogPipelines[link.baseURL] = Set(catalog.pipelines.map(\.id.uuidString))
            var known = knownRemotePipelines
            for shared in catalog.pipelines {
                if let runner = pipelines.first(where: { $0.config.remoteID == shared.id }) {
                    // A pipeline whose builder's link is gone (its address changed, or it was
                    // saved before links were recorded) belongs to the builder that has it.
                    if !addresses.contains(runner.config.builderURL ?? "") { runner.config.builderURL = address }
                } else if !known.contains(shared.id.uuidString) {
                    var config = PipelineConfig()
                    config.name = shared.name
                    config.remoteID = shared.id
                    config.builderURL = address
                    pipelines.append(makeRunner(config))
                    save()
                }
                known.insert(shared.id.uuidString)
            }
            if known != knownRemotePipelines { knownRemotePipelines = known }
            for runner in pipelines where runner.config.builderURL == address {
                if runner.config.builderName != catalog.builder { runner.config.builderName = catalog.builder }
                runner.remote = catalog.pipelines.first { $0.id == runner.config.remoteID }
            }
            assignBuilders()
        }
    }

    /// After a builder declined this Mac: asks again, with a new token and code. Builders that
    /// approved the old token have to approve the new one too.
    func requestApprovalAgain() {
        builderIdentity = .new(name: Self.computerName)
        for (link, status) in builderStatuses where status == .declined { builderStatuses[link] = .connecting }
        builderTasks.values.forEach { $0.cancel() }
        builderTasks = [:]
        updateBuilders()
    }

    /// Lets the Mac behind `request` download builds, if `code` is the one it shows.
    @discardableResult
    func approve(_ request: PairingRequest, code: String) -> Bool {
        let approved = clientAccess.approve(request.id, code: code)
        if approved { log("Approved \(request.name) to download builds") }
        accessChanged(newRequest: nil)
        return approved
    }

    func decline(_ request: PairingRequest) {
        clientAccess.decline(request.id)
        log("Declined \(request.name)")
        accessChanged(newRequest: nil)
    }

    func removeClient(_ client: ApprovedClient) {
        clientAccess.remove(client.id)
        log("Removed \(client.name); it can no longer download builds")
        accessChanged(newRequest: nil)
    }

    /// Mirrors `clientAccess` for the UI and saves who's approved and declined.
    func accessChanged(newRequest: PairingRequest?) {
        let approved = clientAccess.approvedClients
        if approved != approvedClients {
            approvedClients = approved
            defaults?.set(try? JSONEncoder().encode(approved), forKey: approvedClientsKey)
        }
        pairingRequests = clientAccess.pairingRequests
        defaults?.set(clientAccess.declinedTokens, forKey: declinedClientsKey)
        // At most one notification a minute, however many Macs ask.
        if let newRequest, discoversDevices,
           lastRequestNotification.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            lastRequestNotification = Date()
            log("\(newRequest.name) asks to download builds")
            Notifier.post(title: "\(newRequest.name) wants this Mac's builds",
                          body: "To let it in, enter the code it shows in Orchard's Settings.")
        }
    }

    /// The name people gave this Mac, e.g. "Office Mac".
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    /// Downloads the builder's device support package and installs it, so this Mac can install
    /// apps on devices without Xcode. Asks for an administrator password.
    func installDeviceSupport() {
        guard deviceSupport != .installing,
              let link = builders.first(where: { deviceSupportBuilders.contains($0.baseURL) }) else { return }
        let builder = client(for: link)
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
        runner.builder = builder(for: config)
        runner.onChange = { [weak self] in
            self?.save()
            self?.updateActivity()
        }
        return runner
    }

    private func save() {
        let data = try? JSONEncoder().encode(pipelines.map(\.config))
        defaults?.set(data, forKey: defaultsKey)
        listSharedPipelines()
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
