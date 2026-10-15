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
        case deploying(String)

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
            case .deploying(let device): "Deploying to \(device)…"
            }
        }
    }

    var config: PipelineConfig {
        didSet {
            guard config != oldValue else { return }
            onChange?()
            if config.isEnabled != oldValue.isEnabled { config.isEnabled ? start() : stop() }
        }
    }
    private(set) var status: Status = .disabled
    private(set) var log: [LogLine] = []
    private(set) var runs: [RunRecord] = []
    private(set) var lastCheck: Date?
    private(set) var nextCheck: Date?
    private(set) var lastError: String?
    private(set) var remoteHead: String?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    nonisolated var id: UUID { _id }
    @ObservationIgnored private nonisolated let _id: UUID

    init(config: PipelineConfig) {
        self._id = config.id
        self.config = config
        if config.isEnabled { start() }
    }

    var lastRun: RunRecord? { runs.first }

    // MARK: Control

    private func start() {
        guard loopTask == nil else { return }
        status = .idle
        append(.info, "Enabled — polling \(config.branch ?? "?") every \(Int(config.pollInterval))s")
        Notifier.requestAuthorization()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check(force: false)
                let interval = max(10, self.config.pollInterval)
                self.nextCheck = Date().addingTimeInterval(interval)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func stop() {
        loopTask?.cancel()
        loopTask = nil
        nextCheck = nil
        if !status.isBusy { status = .disabled }
        append(.info, "Disabled")
    }

    /// Build and deploy the branch head right now, even if it was already deployed.
    func buildNow() {
        guard runTask == nil else { return }
        Task { await check(force: true) }
    }

    func cancelRun() {
        runTask?.cancel()
    }

    func clearLog() { log.removeAll() }

    // MARK: Polling

    private func check(force: Bool) async {
        guard runTask == nil else { return }
        if let missing = config.missingSetup {
            lastError = missing
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
            guard force || isNew else { return }
            if !force { append(.step, "New commit on \(branch): \(head.shortSHA)") }

            let snapshot = config
            let task = Task { await self.run(commit: head, config: snapshot) }
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

    private func run(commit: String, config: PipelineConfig) async {
        guard let repo = config.repoURL, let branch = config.branch, let scheme = config.scheme else { return }
        self.config.lastAttemptedCommit = commit

        let logFile = LogFile(pipeline: config, commit: commit)
        var record = RunRecord(commit: commit, logFile: logFile.url)
        for device in config.devices { record.deviceOutcomes[device.id] = .pending }
        runs.insert(record, at: 0)
        if runs.count > 50 { runs.removeLast() }

        func update(_ change: (inout RunRecord) -> Void) {
            guard let index = runs.firstIndex(where: { $0.id == record.id }) else { return }
            change(&runs[index])
        }

        let raw = logger(file: logFile, condensed: false)
        let build = logger(file: logFile, condensed: true)
        let dirs = Paths.pipeline(config.id)

        do {
            status = .preparing
            append(.step, "Checking out \(branch) @ \(commit.shortSHA)")
            try await Git.prepareWorktree(at: dirs.checkout, repo: repo, branch: branch, commit: commit, log: raw)
            let subject = await Git.subject(of: commit, in: dirs.checkout)
            update { $0.subject = subject }
            if let subject { append(.info, "“\(subject)”") }

            let groups = Dictionary(grouping: config.devices, by: \.platform)
            for platform in BuildPlatform.allCases {
                guard let devices = groups[platform] else { continue }
                try Task.checkCancellation()

                status = .building(platform)
                append(.step, "Building \(scheme) (\(config.configuration)) for \(platform.displayName)")
                let product: BuiltProduct
                do {
                    product = try await Xcode.build(
                        container: config.containerPath, scheme: scheme,
                        configuration: config.configuration, platform: platform,
                        in: dirs.checkout, derivedData: dirs.derivedData, log: build)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    append(.error, "Build for \(platform.displayName) failed")
                    for device in devices {
                        update { $0.deviceOutcomes[device.id] = .failed("Build failed") }
                    }
                    raw("BUILD FAILED: \(error.localizedDescription)")
                    continue
                }
                append(.success, "Built \(product.appURL.lastPathComponent)")

                for device in devices {
                    try Task.checkCancellation()
                    status = .deploying(device.name)
                    update { $0.deviceOutcomes[device.id] = .running }
                    append(.step, "Deploying to \(device.name)")
                    do {
                        try await Deployer.deploy(product, to: device, log: raw)
                        update { $0.deviceOutcomes[device.id] = .succeeded }
                        append(.success, "Launched on \(device.name)")
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let message = (error as? ShellError).map { lastMeaningfulLine($0.output) }
                            ?? error.localizedDescription
                        update { $0.deviceOutcomes[device.id] = .failed(message) }
                        append(.error, "\(device.name): \(message)")
                    }
                }
            }

            let failures = runs.first(where: { $0.id == record.id })?.deviceOutcomes.values
                .filter { if case .failed = $0 { true } else { false } }.count ?? 0
            if failures == 0 {
                self.config.lastDeployedCommit = commit
                self.config.lastDeployedAt = Date()
                update { $0.outcome = .succeeded }
                append(.success, "Deployed \(commit.shortSHA) to \(config.devices.count) device(s)")
                Notifier.post(title: "Deployed \(config.name)",
                              body: "\(commit.shortSHA) is running on \(config.devices.count) device(s).")
            } else {
                let summary = "\(failures) of \(config.devices.count) device(s) failed"
                update { $0.outcome = .failed(summary) }
                append(.error, summary)
                Notifier.post(title: "\(config.name) failed", body: "\(commit.shortSHA): \(summary)")
            }
        } catch is CancellationError {
            update { $0.outcome = .failed("Cancelled") }
            append(.warning, "Cancelled")
        } catch {
            update { $0.outcome = .failed(error.localizedDescription) }
            append(.error, error.localizedDescription)
            Notifier.post(title: "\(config.name) failed", body: error.localizedDescription)
        }
        update { $0.finishedAt = Date() }
        logFile.close()
    }

    /// Removes Orchard's checkout and build products for this pipeline.
    func cleanUp() async {
        loopTask?.cancel()
        runTask?.cancel()
        let dirs = Paths.pipeline(config.id)
        if let repo = config.repoURL { await Git.removeWorktree(at: dirs.checkout, repo: repo) }
        try? FileManager.default.removeItem(at: dirs.root)
    }

    // MARK: Logging

    private func append(_ level: LogLine.Level, _ text: String) {
        log.append(LogLine(level: level, text: text))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
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

    static let logs: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/Orchard", isDirectory: true)
    }()

    struct PipelineDirs {
        var root: URL
        var checkout: URL { root.appendingPathComponent("checkout", isDirectory: true) }
        var derivedData: URL { root.appendingPathComponent("DerivedData", isDirectory: true) }
    }

    static func pipeline(_ id: UUID) -> PipelineDirs {
        PipelineDirs(root: appSupport.appendingPathComponent("Pipelines/\(id.uuidString)", isDirectory: true))
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

    func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        try? handle?.write(contentsOf: Data((line + "\n").utf8))
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
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
