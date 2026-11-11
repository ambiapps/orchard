import Foundation
import Observation
import UserNotifications

/// Owns one pipeline: polls its branch while enabled, and builds + deploys new commits.
@MainActor
@Observable
final class PipelineRunner: Identifiable {
    enum Status: Equatable {
        case disabled
        case idle
        case checking
        case preparing
        case building(BuildPlatform)
        /// A client fetching the build from its builder.
        case downloading(BuildPlatform)
        /// Names of the devices still being deployed to; they're deployed to at the same time.
        case deploying([String])

        var isBusy: Bool {
            switch self {
            case .disabled, .idle: false
            default: true
            }
        }

        var label: String {
            switch self {
            case .disabled: "Disabled"
            case .idle: "Watching"
            case .checking: "Checking for changes…"
            case .preparing: "Checking out…"
            case .building(let platform): "Building for \(platform.displayName)…"
            case .downloading(let platform): "Downloading the \(platform.displayName) build…"
            case .deploying(let devices):
                devices.count == 1 ? "Deploying to \(devices[0])…" : "Deploying to \(devices.count) devices…"
            }
        }
    }

    var config: PipelineConfig {
        didSet {
            guard config != oldValue else { return }
            onChange?()
            if config.isEnabled != oldValue.isEnabled { config.isEnabled ? start() : stop() }
            if config.keptRuns < oldValue.keptRuns {
                runs = Array(runs.prefix(config.keptRuns))
                log = log.keepingRuns(config.keptRuns)
                history?.replaceLog(with: log)
            }
        }
    }
    private(set) var status: Status = .disabled
    private(set) var log: [LogLine] = []
    var runs: [RunRecord] = [] {
        didSet { history?.saveRuns(runs) }
    }
    private(set) var lastCheck: Date?
    private(set) var nextCheck: Date?
    private(set) var lastError: String?
    private(set) var remoteHead: String?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private let history: PipelineHistory?
    /// Devices that automatic setup just added and that still need their first deploy.
    @ObservationIgnored private var newDevices: [Device] = []
    @ObservationIgnored private let deployer: DeployAction
    /// Whether this Mac is a builder: each build is then also zipped for its clients. Set by `AppStore`.
    @ObservationIgnored var sharesBuilds = false
    /// The builder a remote pipeline (`config.remoteID`) gets its builds from. Set by `AppStore`.
    @ObservationIgnored var builder: BuilderClient?
    @ObservationIgnored private let sharedRoot: URL

    /// Installs and launches an app on a device, logging the tools' output line by line.
    typealias DeployAction = @Sendable (BuiltProduct, Device, @escaping @Sendable (String) -> Void) async throws -> Void

    nonisolated var id: UUID { _id }
    @ObservationIgnored private nonisolated let _id: UUID

    static let maxLogLines = 2000

    /// `history` keeps deploys and the log across launches; without it they live only in memory.
    /// Tests replace `deployer`, which otherwise needs real devices.
    /// `sharedRoot` is where a builder keeps the builds it shares, and a client its downloads.
    init(config: PipelineConfig, history: PipelineHistory? = nil, sharedRoot: URL = Paths.pipelines,
         deployer: @escaping DeployAction = { try await Deployer.deploy($0, to: $1, log: $2) }) {
        self._id = config.id
        self.deployer = deployer
        self.sharedRoot = sharedRoot
        self.config = config
        // Before `history` is set, so loading doesn't trigger a save (which would wipe a file
        // that failed to decode).
        runs = history?.loadRuns() ?? []
        log = history?.loadLog() ?? []
        self.history = history
        if config.isEnabled { start() }
    }

    var lastRun: RunRecord? { runs.first }

    // MARK: Control

    private func start() {
        guard loopTask == nil else { return }
        status = .idle
        append(.info, config.isRemote
               ? "Enabled — asking the builder for new builds every \(Int(config.pollInterval))s"
               : "Enabled — polling \(config.branch ?? "?") every \(Int(config.pollInterval))s")
        Notifier.requestAuthorization()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check(force: false)
                await self.deployToNewDevices()
                let interval = max(10, self.config.pollInterval)
                self.nextCheck = Date().addingTimeInterval(interval)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func stop() {
        loopTask?.cancel()
        loopTask = nil
        newDevices = []
        nextCheck = nil
        if !status.isBusy { status = .disabled }
        append(.info, "Disabled")
    }

    /// Build and deploy the branch head right now, even if it was already deployed.
    func buildNow() {
        guard runTask == nil else { return }
        Task { await check(force: true) }
    }

    /// Deploys the branch head to a device that automatic setup just added, without waiting for
    /// the next commit. An enabled pipeline only; a disabled one deploys nothing by itself.
    func deploy(toNew device: Device) {
        guard config.isEnabled else { return }
        newDevices.append(device)
        Task { await deployToNewDevices() }
    }

    /// Waits while the pipeline is busy; the poll loop comes back to it. A device stays queued
    /// until a run for it starts, so a check that fails (no network) is tried again.
    private func deployToNewDevices() async {
        while config.isEnabled, !status.isBusy, runTask == nil {
            // The user may have unticked it since.
            newDevices.removeAll { device in !config.devices.contains { $0.id == device.id } }
            guard let device = newDevices.first else { return }
            await check(force: true, newDevice: device)
            if newDevices.first?.id == device.id { return }
        }
    }

    func cancelRun() {
        runTask?.cancel()
    }

    func clearLog() {
        log.removeAll()
        history?.replaceLog(with: [])
    }

    // MARK: Polling

    func check(force: Bool, newDevice: Device? = nil) async {
        guard runTask == nil else { return }
        if let missing = config.missingSetup {
            lastError = missing
            return
        }
        if let remoteID = config.remoteID {
            await checkRemote(remoteID, force: force, newDevice: newDevice)
            return
        }
        guard let repo = config.repoURL, let branch = config.branch else { return }

        status = .checking
        defer { status = config.isEnabled ? .idle : .disabled }
        do {
            let head = try await Git.headCommit(of: branch, in: repo)
            lastCheck = Date()
            remoteHead = head
            lastError = nil
            let isNew = head != config.lastDeployedCommit && head != config.lastAttemptedCommit
            // Another check may have started a run while this one was asking for the head.
            guard force || isNew, runTask == nil else { return }
            log = log.keepingRuns(config.keptRuns - 1)
            history?.replaceLog(with: log)
            var snapshot = config
            if let newDevice {
                newDevices.removeAll { $0.id == newDevice.id }
                // The others already run this commit. A commit they don't have yet goes to everyone.
                if head == config.lastDeployedCommit { snapshot.devices = [newDevice] }
                append(.step, "Deploying \(branch) @ \(head.shortSHA) to new device \(newDevice.name)", startsRun: true)
            } else {
                append(.step, force ? "Deploying \(branch) @ \(head.shortSHA) on request"
                                    : "New commit on \(branch): \(head.shortSHA)", startsRun: true)
            }

            let task = Task { await self.run(commit: head, config: snapshot, newDevice: newDevice) }
            runTask = task
            await task.value
            runTask = nil
        } catch is CancellationError {
        } catch {
            lastCheck = Date()
            lastError = error.localizedDescription
            append(.error, "Couldn't check \(branch): \(error.localizedDescription)")
        }
    }

    // MARK: Build & deploy

    /// `newDevice` is the destination of its platform's build, so xcodebuild registers it with the team.
    private func run(commit: String, config: PipelineConfig, newDevice: Device? = nil) async {
        guard let repo = config.repoURL, let branch = config.branch, let scheme = config.scheme else { return }
        self.config.lastAttemptedCommit = commit

        let logFile = LogFile(pipeline: config, commit: commit)
        var record = RunRecord(commit: commit, baseCommit: config.lastDeployedCommit, logFile: logFile.url)
        for device in config.devices { record.deviceOutcomes[device.id] = .pending }
        runs.insert(record, at: 0)
        if runs.count > config.keptRuns { runs.removeLast(runs.count - config.keptRuns) }

        func update(_ change: (inout RunRecord) -> Void) {
            guard let index = runs.firstIndex(where: { $0.id == record.id }) else { return }
            change(&runs[index])
        }

        let raw = logger(file: logFile, condensed: false)
        let build = logger(file: logFile, condensed: true)
        let dirs = Paths.pipeline(config.id)
        let runStart = Date()
        var timings = RunTimings()
        var buildFailed = false

        do {
            status = .preparing
            append(.step, "Checking out \(branch) @ \(commit.shortSHA)")
            try await Git.prepareWorktree(at: dirs.checkout, repo: repo, branch: branch, commit: commit, log: raw)
            let subject = await Git.subject(of: commit, in: dirs.checkout)
            update { $0.subject = subject }
            if let subject { append(.info, "“\(subject)”") }
            if let base = config.lastDeployedCommit {
                let changes = await Git.changes(from: base, to: commit, in: dirs.checkout)
                update { $0.changes = changes }
            }
            timings.checkout = Date().timeIntervalSince(runStart)
            update { $0.timings = timings }

            let groups = Dictionary(grouping: config.devices, by: \.platform)
            // A builder also builds a platform none of its own devices needs, for its clients.
            let platforms = sharesBuilds ? config.buildPlatforms : Set(groups.keys)
            for platform in BuildPlatform.allCases where platforms.contains(platform) {
                var devices = groups[platform] ?? []
                try Task.checkCancellation()

                /// Builds the platform; nil when the build failed, which fails its devices unless
                /// `failingDevices` is false.
                func buildProduct(failingDevices: Bool = true) async throws -> BuiltProduct? {
                    let buildStart = Date()
                    defer {
                        timings.build += Date().timeIntervalSince(buildStart)
                        update { $0.timings = timings }
                    }
                    do {
                        let product = try await Xcode.build(
                            container: config.containerPath, scheme: scheme,
                            configuration: config.configuration, platform: platform,
                            registering: newDevice?.platform == platform ? newDevice?.udid : nil,
                            in: dirs.checkout, derivedData: dirs.derivedData, log: build)
                        append(.success, "Built \(product.appURL.lastPathComponent) in \(Date().timeIntervalSince(buildStart).formattedDuration)")
                        return product
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let elapsed = Date().timeIntervalSince(buildStart).formattedDuration
                        append(.error, "Build for \(platform.displayName) failed after \(elapsed)")
                        if failingDevices {
                            buildFailed = true
                            for device in devices {
                                update { $0.deviceOutcomes[device.id] = .failed("Build failed") }
                            }
                        }
                        raw("BUILD FAILED: \(error.localizedDescription)")
                        return nil
                    }
                }

                status = .building(platform)
                runs.forgetProducts(keeping: record.id)
                append(.step, "Building \(scheme) (\(config.configuration)) for \(platform.displayName)")
                guard var product = try await buildProduct() else { continue }

                // The generic destination gives xcodebuild no reason to refresh a cached profile
                // that predates a device, so check it here and refresh it once ourselves.
                if platform.needsDeviceProvisioning {
                    devices = await rememberingUDIDs(of: devices)
                    let missing = Provisioning.devicesMissing(fromProfilesIn: product.appURL, devices: devices)
                    // Building again only helps when the profile is one Xcode will download anew.
                    if !missing.isEmpty, Provisioning.canRefreshProfiles(in: product.appURL, missing: missing) {
                        let removed = Provisioning.removeXcodeManagedProfiles()
                        if removed > 0 {
                            let names = missing.map(\.name).joined(separator: ", ")
                            append(.warning, "The provisioning profile doesn't include \(names). Removed \(removed) cached Xcode-managed profile(s); building again")
                            try Task.checkCancellation()
                            if let rebuilt = try await buildProduct(failingDevices: false) {
                                product = rebuilt
                            } else if !FileManager.default.fileExists(atPath: product.appURL.path) {
                                buildFailed = true
                                for device in devices {
                                    update { $0.deviceOutcomes[device.id] = .failed("Build failed") }
                                }
                                continue
                            }
                            // Otherwise the first build is still there for the devices it covers.
                        }
                    }
                }
                update { $0.products = ($0.products ?? [:]).merging([platform.rawValue: product]) { $1 } }

                if sharesBuilds, !platform.isSimulator {
                    do {
                        let shared = try await SharedBuilds.publish(
                            product, platform: platform, commit: commit, subject: subject,
                            pipeline: self.config, root: sharedRoot)
                        append(.info, "Sharing the \(platform.displayName) build with clients (\(shared.size.formattedSize))")
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        append(.warning, "Couldn't share the \(platform.displayName) build: \(error.localizedDescription)")
                    }
                }
                guard !devices.isEmpty else { continue }

                try Task.checkCancellation()
                let deployStart = Date()
                defer {
                    timings.deploy += Date().timeIntervalSince(deployStart)
                    update { $0.timings = timings }
                }
                try await deployAll(product, to: devices, run: record.id, log: raw)
            }

            conclude(record.id, commit: commit, config: config, buildFailed: buildFailed,
                     took: timings.summary(total: Date().timeIntervalSince(runStart)))
        } catch is CancellationError {
            update {
                $0.outcome = .failed("Cancelled")
                $0.markUnfinishedDevices(.failed("Cancelled"))
            }
            append(.warning, "Cancelled after \(Date().timeIntervalSince(runStart).formattedDuration)")
        } catch {
            update { $0.outcome = .failed(error.localizedDescription) }
            append(.error, "\(error.localizedDescription) (after \(Date().timeIntervalSince(runStart).formattedDuration))")
            Notifier.post(title: "\(config.name) failed", body: error.localizedDescription)
        }
        update { $0.finishedAt = Date() }
        logFile.close()
    }

    /// Sets a finished run's outcome from its devices', logs it and notifies.
    private func conclude(_ id: RunRecord.ID, commit: String, config: PipelineConfig,
                          buildFailed: Bool = false, took: String) {
        var outcome = runs.first(where: { $0.id == id })?.finalOutcome(devices: config.devices) ?? .succeeded
        // With no device of its own (a builder that only shares), a failed build fails nothing else.
        if buildFailed, outcome == .succeeded { outcome = .failed("Build failed") }
        if let index = runs.firstIndex(where: { $0.id == id }) { runs[index].outcome = outcome }
        switch outcome {
        case .failed(let summary):
            append(.error, "\(summary) after \(took)")
            Notifier.post(title: "\(config.name) failed", body: "\(commit.shortSHA): \(summary)")
        case .warning(let summary):
            // The build is on every device, so it counts as deployed.
            self.config.lastDeployedCommit = commit
            self.config.lastDeployedAt = Date()
            append(.warning, "\(summary) after \(took)")
            Notifier.post(title: "Installed \(config.name)", body: "\(commit.shortSHA): \(summary)")
        default:
            self.config.lastDeployedCommit = commit
            self.config.lastDeployedAt = Date()
            if config.devices.isEmpty {
                append(.success, "Built \(commit.shortSHA) for clients in \(took)")
            } else {
                append(.success, "Deployed \(commit.shortSHA) to \(config.devices.count) device(s) in \(took)")
                Notifier.post(title: "Deployed \(config.name)",
                              body: "\(commit.shortSHA) is running on \(config.devices.count) device(s).")
            }
        }
    }

    // MARK: Builds from a builder

    /// A client's check: asks the builder for its newest builds and installs the ones this
    /// pipeline's devices don't have yet.
    private func checkRemote(_ remoteID: UUID, force: Bool, newDevice: Device?) async {
        status = .checking
        defer { status = config.isEnabled ? .idle : .disabled }
        do {
            guard let builder else { throw BuilderError.notConnected }
            let catalog = try await builder.catalog()
            lastCheck = Date()
            guard let shared = catalog.pipelines.first(where: { $0.id == remoteID }) else { throw BuilderError.notShared }
            func builds(for devices: [Device]) -> [SharedBuild] {
                let platforms = Set(devices.map(\.platform))
                return shared.builds.filter { platforms.contains($0.platform) }.sorted { $0.builtAt > $1.builtAt }
            }
            let wanted = builds(for: config.devices)
            guard let newest = wanted.first else { throw BuilderError.noBuild }
            remoteHead = newest.commit
            lastError = nil
            // Build ids, not commits: the builder may build a commit again with a new profile.
            let signature = wanted.map(\.id.uuidString).sorted().joined(separator: ",")
            let isNew = signature != config.lastRemoteBuild
            guard force || isNew, runTask == nil else { return }
            log = log.keepingRuns(config.keptRuns - 1)
            history?.replaceLog(with: log)
            var snapshot = config
            if let newDevice {
                newDevices.removeAll { $0.id == newDevice.id }
                // The others already run these builds. Builds they don't have yet go to everyone.
                if !isNew, newest.commit == config.lastDeployedCommit { snapshot.devices = [newDevice] }
                append(.step, "Installing \(newest.commit.shortSHA) on new device \(newDevice.name)", startsRun: true)
            } else {
                append(.step, isNew ? "New build on \(catalog.builder): \(newest.commit.shortSHA)"
                                    : "Installing \(newest.commit.shortSHA) on request", startsRun: true)
            }
            config.lastRemoteBuild = signature

            let task = Task {
                await self.runRemote(builds(for: snapshot.devices), from: builder, pipeline: remoteID, config: snapshot)
            }
            runTask = task
            await task.value
            runTask = nil
        } catch is CancellationError {
        } catch {
            lastCheck = Date()
            // The same answer on every poll (no build yet, builder asleep) is logged once.
            if lastError != error.localizedDescription {
                append(.error, "Couldn't get builds: \(error.localizedDescription)")
            }
            lastError = error.localizedDescription
        }
    }

    /// Downloads each platform's build and deploys it to that platform's devices. `builds` are
    /// newest first, one per platform.
    private func runRemote(_ builds: [SharedBuild], from builder: BuilderClient, pipeline remoteID: UUID,
                           config: PipelineConfig) async {
        guard let newest = builds.first else { return }
        self.config.lastAttemptedCommit = newest.commit
        let logFile = LogFile(pipeline: config, commit: newest.commit)
        var record = RunRecord(commit: newest.commit, subject: newest.subject,
                               baseCommit: config.lastDeployedCommit, logFile: logFile.url)
        for device in config.devices { record.deviceOutcomes[device.id] = .pending }
        runs.insert(record, at: 0)
        if runs.count > config.keptRuns { runs.removeLast(runs.count - config.keptRuns) }

        func update(_ change: (inout RunRecord) -> Void) {
            guard let index = runs.firstIndex(where: { $0.id == record.id }) else { return }
            change(&runs[index])
        }
        let raw = logger(file: logFile, condensed: false)
        let downloads = Paths.PipelineDirs(root: sharedRoot.appendingPathComponent(config.id.uuidString)).downloads
        let runStart = Date()
        var timings = RunTimings()
        if let subject = newest.subject { append(.info, "“\(subject)”") }

        do {
            for build in builds {
                try Task.checkCancellation()
                let platform = build.platform
                var devices = config.devices.filter { $0.platform == platform }
                status = .downloading(platform)
                // The download replaces the app an older run could still be deployed from.
                runs.forgetProducts(keeping: record.id)
                append(.step, "Downloading \(build.commit.shortSHA) for \(platform.displayName) (\(build.size.formattedSize))")
                let downloadStart = Date()
                let archive = downloads.appendingPathComponent("\(platform.rawValue).zip")
                try await builder.download(build, pipeline: remoteID, to: archive)
                let product = try await SharedBuilds.unpack(
                    archive, into: downloads.appendingPathComponent(platform.rawValue, isDirectory: true))
                try? FileManager.default.removeItem(at: archive)
                timings.download = (timings.download ?? 0) + Date().timeIntervalSince(downloadStart)
                update {
                    $0.timings = timings
                    $0.products = ($0.products ?? [:]).merging([platform.rawValue: product]) { $1 }
                }

                if platform.needsDeviceProvisioning { devices = await rememberingUDIDs(of: devices) }
                try Task.checkCancellation()
                let deployStart = Date()
                defer {
                    timings.deploy += Date().timeIntervalSince(deployStart)
                    update { $0.timings = timings }
                }
                try await deployAll(product, to: devices, run: record.id, log: raw)
            }
            // A platform the builder has no build for.
            update { $0.markUnfinishedDevices(.failed("The builder has no build for this device")) }
            conclude(record.id, commit: newest.commit, config: config,
                     took: timings.summary(total: Date().timeIntervalSince(runStart)))
        } catch is CancellationError {
            update {
                $0.outcome = .failed("Cancelled")
                $0.markUnfinishedDevices(.failed("Cancelled"))
            }
            append(.warning, "Cancelled after \(Date().timeIntervalSince(runStart).formattedDuration)")
        } catch {
            update {
                $0.outcome = .failed(error.localizedDescription)
                $0.markUnfinishedDevices(.failed("Download failed"))
            }
            append(.error, "\(error.localizedDescription) (after \(Date().timeIntervalSince(runStart).formattedDuration))")
            Notifier.post(title: "\(config.name) failed", body: error.localizedDescription)
        }
        update { $0.finishedAt = Date() }
        logFile.close()
    }

    /// Deploys a device again from a run's build, if that build is still in DerivedData.
    func canRedeploy(_ device: Device, from run: RunRecord) -> Bool {
        guard !status.isBusy, run.deviceOutcomes[device.id]?.canRetry == true,
              let product = run.product(for: device.platform) else { return false }
        return FileManager.default.fileExists(atPath: product.appURL.path)
    }

    /// Installs and launches `run`'s build on `device` again, e.g. after it failed because the
    /// device was locked or disconnected. Doesn't build anything.
    func redeploy(_ device: Device, from runID: RunRecord.ID) {
        guard runTask == nil, let run = runs.first(where: { $0.id == runID }),
              canRedeploy(device, from: run), let product = run.product(for: device.platform) else { return }
        runTask = Task {
            await redeploy(product, to: device, run: run)
            runTask = nil
        }
    }

    private func redeploy(_ product: BuiltProduct, to device: Device, run: RunRecord) async {
        defer { status = config.isEnabled ? .idle : .disabled }
        func update(_ change: (inout RunRecord) -> Void) {
            guard let index = runs.firstIndex(where: { $0.id == run.id }) else { return }
            change(&runs[index])
        }
        let device = await rememberingUDIDs(of: [device]).first ?? device
        let logFile = run.logFile.flatMap(LogFile.init(appendingTo:))
        defer { logFile?.close() }
        let raw: @Sendable (String) -> Void
        if let logFile { raw = logger(file: logFile, condensed: false) } else { raw = { _ in } }
        append(.step, "Deploying \(run.commit.shortSHA) to \(device.name) again")
        do {
            try await deployAll(product, to: [device], run: run.id, log: raw, announce: false)
        } catch {
            // Nothing changed on the device that matters; keep what the run recorded.
            update { $0.deviceOutcomes[device.id] = run.deviceOutcomes[device.id] }
            append(.warning, "Cancelled")
            return
        }
        guard let updated = runs.first(where: { $0.id == run.id }), updated.finishedAt != nil else { return }
        let devices = config.devices.filter { updated.deviceOutcomes[$0.id] != nil }
        let outcome = updated.finalOutcome(devices: devices)
        update { $0.outcome = outcome }
        // The newest attempt is now installed on every device, so it counts as deployed.
        let failed = if case .failed = outcome { true } else { false }
        if !failed, runs.first?.id == run.id, run.commit == config.lastAttemptedCommit {
            config.lastDeployedCommit = run.commit
            config.lastDeployedAt = Date()
        }
    }

    /// `devices` with their hardware UDIDs, saving the ones found for devices chosen before
    /// Orchard stored them, so devicectl is asked only once.
    private func rememberingUDIDs(of devices: [Device]) async -> [Device] {
        let filled = await DeviceDiscovery.fillingUDIDs(devices)
        for device in filled where device.udid != nil {
            guard let index = config.devices.firstIndex(where: { $0.id == device.id && $0.udid == nil }) else { continue }
            config.devices[index].udid = device.udid
        }
        return filled
    }

    /// Installs and launches `product` on all of `devices` at the same time, recording each
    /// device's outcome on the run. Throws only `CancellationError`, which stops every deploy;
    /// a failed deploy is an outcome and doesn't affect the other devices.
    func deployAll(_ product: BuiltProduct, to devices: [Device], run: RunRecord.ID,
                   log: @escaping @Sendable (String) -> Void, announce: Bool = true) async throws {
        var remaining = devices.map(\.name)
        status = .deploying(remaining)
        try await withThrowingTaskGroup(of: String.self) { group in
            for device in devices {
                // Several devices write to the log at once, so say whose line each one is.
                let deviceLog = devices.count > 1 ? Self.prefixing(log, with: device.name) : log
                group.addTask {
                    try await self.deploy(product, to: device, run: run, log: deviceLog, announce: announce)
                    return device.name
                }
            }
            for try await finished in group {
                if let index = remaining.firstIndex(of: finished) { remaining.remove(at: index) }
                if !remaining.isEmpty { status = .deploying(remaining) }
            }
        }
    }

    /// Installs and launches `product` on `device`, recording its outcome on the run as it goes.
    /// A device the app's provisioning profile doesn't list fails without an install attempt.
    /// Throws only `CancellationError`; a failed deploy is an outcome.
    private func deploy(_ product: BuiltProduct, to device: Device, run: RunRecord.ID,
                        log: @escaping @Sendable (String) -> Void, announce: Bool) async throws {
        func report(_ outcome: DeployOutcome) {
            guard let index = runs.firstIndex(where: { $0.id == run }) else { return }
            runs[index].deviceOutcomes[device.id] = outcome
        }
        report(.running)
        if announce { append(.step, "Deploying to \(device.name)") }
        // Installing would fail with an opaque ApplicationVerificationFailed; say why instead.
        if !Provisioning.devicesMissing(fromProfilesIn: product.appURL, devices: [device]).isEmpty {
            let message = Provisioning.unregisteredMessage(for: device)
            report(.failed(message))
            append(.error, message)
            return
        }
        let start = Date()
        do {
            try await deployer(product, device, log)
            report(.succeeded)
            append(.success, "Launched on \(device.name) in \(Date().timeIntervalSince(start).formattedDuration)")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DeployError {
            report(.warning(error.localizedDescription))
            append(.warning, "\(device.name): \(error.localizedDescription) (\(Date().timeIntervalSince(start).formattedDuration))")
        } catch {
            let message = (error as? ShellError).map { lastMeaningfulLine($0.output) }
                ?? error.localizedDescription
            report(.failed(message))
            append(.error, "\(device.name): \(message) (\(Date().timeIntervalSince(start).formattedDuration))")
        }
    }

    /// `log`, with each line marked as coming from the device called `name`.
    nonisolated static func prefixing(_ log: @escaping @Sendable (String) -> Void,
                                      with name: String) -> @Sendable (String) -> Void {
        { line in log(line.allSatisfy(\.isWhitespace) ? line : "[\(name)] \(line)") }
    }

    /// Removes Orchard's checkout and build products for this pipeline.
    func cleanUp() async {
        history?.close()
        loopTask?.cancel()
        runTask?.cancel()
        let dirs = Paths.pipeline(config.id)
        if let repo = config.repoURL { await Git.removeWorktree(at: dirs.checkout, repo: repo) }
        try? FileManager.default.removeItem(at: dirs.root)
    }

    // MARK: Logging

    private func append(_ level: LogLine.Level, _ text: String, startsRun: Bool = false) {
        let line = LogLine(level: level, text: text, startsRun: startsRun ? true : nil)
        log.append(line)
        if log.count > Self.maxLogLines { log = log.keepingLines(Self.maxLogLines) }
        history?.appendLog(line)
    }

    /// Writes every line to the run's log file; the UI only gets lines worth reading.
    /// `condensed` keeps just errors and results from xcodebuild's very chatty output.
    private nonisolated func logger(file: LogFile, condensed: Bool) -> @Sendable (String) -> Void {
        { [weak self] line in
            file.write(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let level: LogLine.Level
            if trimmed.contains("error:") || trimmed.hasPrefix("** BUILD FAILED") {
                level = .error
            } else if trimmed.hasPrefix("** BUILD SUCCEEDED") {
                level = .success
            } else if condensed {
                return
            } else {
                level = .info
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.append(level, trimmed) }
            }
        }
    }

    private func lastMeaningfulLine(_ output: String) -> String {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? "Failed"
    }
}

// MARK: - Support

enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Orchard", isDirectory: true)
    }()

    static let pipelines = appSupport.appendingPathComponent("Pipelines", isDirectory: true)

    static let logs: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/Orchard", isDirectory: true)
    }()

    struct PipelineDirs {
        var root: URL
        var checkout: URL { root.appendingPathComponent("checkout", isDirectory: true) }
        var derivedData: URL { root.appendingPathComponent("DerivedData", isDirectory: true) }
        /// Builds a client downloaded from its builder, one folder per platform.
        var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    }

    static func pipeline(_ id: UUID) -> PipelineDirs {
        PipelineDirs(root: pipelines.appendingPathComponent(id.uuidString, isDirectory: true))
    }
}

final class LogFile: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle?
    private let lock = NSLock()

    init(pipeline: PipelineConfig, commit: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = Paths.logs.appendingPathComponent(pipeline.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("\(formatter.string(from: Date()))_\(commit.shortSHA).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    /// Appends to an existing run log, for deploying that run again.
    init?(appendingTo url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        self.url = url
        self.handle = handle
    }

    func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        try? handle?.write(contentsOf: Data((line + "\n").utf8))
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
    }
}

/// A pipeline's deploys and window log, kept on disk so they survive relaunches.
/// The log is JSON lines, appended as lines come in; once the file holds twice `logLimit` lines
/// it's cut back to at most `logLimit`, by whole runs. Deploys are one JSON file, rewritten on
/// every change. Encoding happens on the main actor, file I/O on one background queue shared by
/// every pipeline, so a new instance reads only after an old one's writes have landed.
@MainActor
final class PipelineHistory {
    let directory: URL
    let logLimit: Int
    private static let io = DispatchQueue(label: "se.ambi.Orchard.PipelineHistory")
    private let files: HistoryFiles
    private var lineCount = 0

    init(directory: URL, logLimit: Int = PipelineRunner.maxLogLines) {
        self.directory = directory
        self.logLimit = logLimit
        self.files = HistoryFiles(directory: directory)
    }

    convenience init(pipeline id: UUID) {
        self.init(directory: Paths.logs.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    /// Saved deploys; ones that were still going when Orchard quit are marked interrupted.
    /// A file that doesn't decode (say, from a newer Orchard) is moved aside, not overwritten.
    func loadRuns() -> [RunRecord] {
        guard let data = Self.io.sync(execute: { files.readRuns() }) else { return [] }
        guard let runs = try? JSONDecoder().decode([RunRecord].self, from: data) else {
            Self.io.sync { files.setAsideRuns() }
            return []
        }
        return runs.map { $0.interruptedIfUnfinished() }
    }

    func saveRuns(_ runs: [RunRecord]) {
        guard let data = try? JSONEncoder().encode(runs) else { return }
        let files = files
        Self.io.async { files.writeRuns(data) }
    }

    /// The newest lines, at most `logLimit` and starting at a run; rewrites the file without the
    /// older ones.
    func loadLog() -> [LogLine] {
        guard let data = Self.io.sync(execute: { files.readLog() }) else { return [] }
        let lines = Self.decode(data)
        let kept = lines.keepingLines(logLimit)
        if kept.count < lines.count { replaceLog(with: kept) } else { lineCount = kept.count }
        return kept
    }

    func appendLog(_ line: LogLine) {
        guard let data = try? JSONEncoder().encode(line) else { return }
        let files = files
        Self.io.async { files.appendLog(data + Data("\n".utf8)) }
        lineCount += 1
        if lineCount >= 2 * logLimit {
            let limit = logLimit
            Self.io.async {
                guard let data = files.readLog() else { return }
                files.writeLog(Self.encode(Self.decode(data).keepingLines(limit)))
            }
            lineCount = logLimit
        }
    }

    func replaceLog(with lines: [LogLine]) {
        let data = Self.encode(lines)
        let files = files
        Self.io.async { files.writeLog(data) }
        lineCount = lines.count
    }

    /// Closes the log file, for a pipeline that's being removed.
    func close() {
        let files = files
        Self.io.async { files.closeLog() }
    }

    /// Waits for pending writes, so tests can read the files.
    func flush() { Self.io.sync {} }

    private nonisolated static func decode(_ data: Data) -> [LogLine] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(LogLine.self, from: Data($0))
        }
    }

    private nonisolated static func encode(_ lines: [LogLine]) -> Data {
        let encoder = JSONEncoder()
        var data = Data()
        for line in lines {
            guard let encoded = try? encoder.encode(line) else { continue }
            data.append(encoded + Data("\n".utf8))
        }
        return data
    }
}

/// `PipelineHistory`'s files. Only touched on `PipelineHistory.io`, which serializes access.
private final class HistoryFiles: @unchecked Sendable {
    let directory: URL
    private var logURL: URL { directory.appendingPathComponent("activity.jsonl") }
    private var runsURL: URL { directory.appendingPathComponent("runs.json") }
    private var handle: FileHandle?

    init(directory: URL) { self.directory = directory }

    func readRuns() -> Data? { try? Data(contentsOf: runsURL) }

    func writeRuns(_ data: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: runsURL, options: .atomic)
    }

    /// Keeps an unreadable `runs.json` as `runs-unreadable.json`, replacing an older one.
    func setAsideRuns() {
        let aside = directory.appendingPathComponent("runs-unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: runsURL, to: aside)
    }

    func readLog() -> Data? {
        try? handle?.synchronize()
        return try? Data(contentsOf: logURL)
    }

    func appendLog(_ data: Data) {
        if handle == nil {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: logURL)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: data)
    }

    func writeLog(_ data: Data) {
        closeLog()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: logURL, options: .atomic)
    }

    func closeLog() {
        try? handle?.close()
        handle = nil
    }
}

enum Notifier {
    /// Notifications need a real app bundle; skip them when run via `swift run`.
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
