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

    nonisolated var id: UUID { _id }
    @ObservationIgnored private nonisolated let _id: UUID

    static let maxLogLines = 2000

    /// `history` keeps deploys and the log across launches; without it they live only in memory.
    init(config: PipelineConfig, history: PipelineHistory? = nil) {
        self._id = config.id
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
        append(.info, "Enabled — polling \(config.branch ?? "?") every \(Int(config.pollInterval))s")
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

    private func check(force: Bool, newDevice: Device? = nil) async {
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
            for platform in BuildPlatform.allCases {
                guard let devices = groups[platform] else { continue }
                try Task.checkCancellation()

                status = .building(platform)
                append(.step, "Building \(scheme) (\(config.configuration)) for \(platform.displayName)")
                let buildStart = Date()
                let product: BuiltProduct
                do {
                    defer {
                        timings.build += Date().timeIntervalSince(buildStart)
                        update { $0.timings = timings }
                    }
                    product = try await Xcode.build(
                        container: config.containerPath, scheme: scheme,
                        configuration: config.configuration, platform: platform,
                        registering: newDevice?.platform == platform ? newDevice?.udid : nil,
                        in: dirs.checkout, derivedData: dirs.derivedData, log: build)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let elapsed = Date().timeIntervalSince(buildStart).formattedDuration
                    append(.error, "Build for \(platform.displayName) failed after \(elapsed)")
                    for device in devices {
                        update { $0.deviceOutcomes[device.id] = .failed("Build failed") }
                    }
                    raw("BUILD FAILED: \(error.localizedDescription)")
                    continue
                }
                append(.success, "Built \(product.appURL.lastPathComponent) in \(Date().timeIntervalSince(buildStart).formattedDuration)")

                for device in devices {
                    try Task.checkCancellation()
                    status = .deploying(device.name)
                    update { $0.deviceOutcomes[device.id] = .running }
                    append(.step, "Deploying to \(device.name)")
                    let deployStart = Date()
                    defer {
                        timings.deploy += Date().timeIntervalSince(deployStart)
                        update { $0.timings = timings }
                    }
                    do {
                        try await Deployer.deploy(product, to: device, log: raw)
                        update { $0.deviceOutcomes[device.id] = .succeeded }
                        append(.success, "Launched on \(device.name) in \(Date().timeIntervalSince(deployStart).formattedDuration)")
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as DeployError {
                        update { $0.deviceOutcomes[device.id] = .warning(error.localizedDescription) }
                        append(.warning, "\(device.name): \(error.localizedDescription) (\(Date().timeIntervalSince(deployStart).formattedDuration))")
                    } catch {
                        let message = (error as? ShellError).map { lastMeaningfulLine($0.output) }
                            ?? error.localizedDescription
                        update { $0.deviceOutcomes[device.id] = .failed(message) }
                        append(.error, "\(device.name): \(message) (\(Date().timeIntervalSince(deployStart).formattedDuration))")
                    }
                }
            }

            let outcome = runs.first(where: { $0.id == record.id })?.finalOutcome(devices: config.devices)
                ?? .succeeded
            update { $0.outcome = outcome }
            let took = timings.summary(total: Date().timeIntervalSince(runStart))
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
                append(.success, "Deployed \(commit.shortSHA) to \(config.devices.count) device(s) in \(took)")
                Notifier.post(title: "Deployed \(config.name)",
                              body: "\(commit.shortSHA) is running on \(config.devices.count) device(s).")
            }
        } catch is CancellationError {
            update { $0.outcome = .failed("Cancelled") }
            append(.warning, "Cancelled after \(Date().timeIntervalSince(runStart).formattedDuration)")
        } catch {
            update { $0.outcome = .failed(error.localizedDescription) }
            append(.error, "\(error.localizedDescription) (after \(Date().timeIntervalSince(runStart).formattedDuration))")
            Notifier.post(title: "\(config.name) failed", body: error.localizedDescription)
        }
        update { $0.finishedAt = Date() }
        logFile.close()
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
