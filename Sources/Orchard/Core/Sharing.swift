import Foundation
import os

/// A build a builder shares with other Macs: one zipped .app per pipeline and platform.
struct SharedBuild: Codable, Hashable, Sendable, Identifiable {
    /// New for every build, also of a commit that was built before (say, with a refreshed
    /// provisioning profile), so clients install it again.
    var id = UUID()
    var platform: BuildPlatform
    var commit: String
    var subject: String?
    var bundleIdentifier: String
    var builtAt = Date()
    var size: Int64 = 0
}

struct SharedPipeline: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var builds: [SharedBuild]
    /// Builds of the branch's open pull requests, when the builder builds them; nil from a
    /// builder that doesn't (or runs Orchard 1.0.21 or earlier).
    var pullRequests: [SharedPullRequest]?
}

/// A pull request the builder built, with the builds of its newest head that built.
struct SharedPullRequest: Codable, Hashable, Sendable, Identifiable {
    var number: Int
    var title: String
    var author: String?
    var url: String?
    var branch: String?
    /// The head commit last built. A platform that failed to build for it may still have the
    /// build of an earlier commit; each build says which commit it is.
    var commit: String
    var builds: [SharedBuild]

    var id: Int { number }
}

/// What `GET /v1/builds` returns.
struct BuildCatalog: Codable, Sendable {
    var builder: String
    /// Whether the builder can hand out the package with `devicectl` (it has Xcode).
    var hasDeviceSupport: Bool
    var pipelines: [SharedPipeline]
}

/// What a client sends with `POST /v1/devices`: please register this device with your team
/// and build the pipeline again.
struct DeviceRegistrationRequest: Codable, Equatable, Sendable {
    var pipeline: UUID
    var name: String
    var udid: String
    var platform: BuildPlatform
}

/// The builder's answer to a `DeviceRegistrationRequest`.
struct DeviceRegistrationResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case registered
        case alreadyRegistered
        /// The builder can't register devices: it has no App Store Connect key, or runs an
        /// Orchard that doesn't know the request.
        case unavailable
        case failed

        /// A status a later version adds counts as a failure.
        init(from decoder: Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
        }
    }
    var status: Status
    var message: String?
    /// Whether the builder started a new build for the pipeline.
    var rebuilding: Bool?

    static let unavailable = DeviceRegistrationResult(status: .unavailable)
}

/// The address a client enters: `http://host:port`. Links from Orchard 1.0.15 and earlier end in
/// `#token`; that part is ignored, because each client now gets its own token by being approved.
struct BuilderLink: Hashable, Sendable {
    static let defaultPort = 8642

    var baseURL: URL

    /// Nil unless `string` has a host. The scheme and port may be left out.
    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              components.scheme == "http" || components.scheme == "https"
        else { return nil }
        if components.port == nil, components.scheme == "http" { components.port = Self.defaultPort }
        components.fragment = nil
        components.path = ""
        components.query = nil
        guard let url = components.url else { return nil }
        baseURL = url
    }

    static func string(host: String, port: Int) -> String {
        "http://\(host):\(port)"
    }

    static func newToken() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// The shared builds on disk: `Pipelines/<id>/Shared/<build id>.zip`, described by a
/// `<platform>.json` next to it. An archive is named after its build, so a request for a build
/// can never get another one's archive. The server reads these files and nothing else, so a build that's being replaced
/// in DerivedData is never what a client downloads.
enum SharedBuilds {
    private struct Entry: Codable {
        var pipeline: String
        var build: SharedBuild
    }

    /// A pipeline the builder has, whether or not it has built anything yet.
    struct Listed: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
    }

    private static func listURL(root: URL) -> URL {
        root.appendingPathComponent("SharedPipelines.json")
    }

    /// Says which pipelines the builder has, so clients see them before their first build.
    static func list(_ pipelines: [Listed], root: URL = Paths.pipelines) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(pipelines).write(to: listURL(root: root), options: .atomic)
    }

    static func listed(root: URL = Paths.pipelines) -> [Listed] {
        (try? JSONDecoder().decode([Listed].self, from: Data(contentsOf: listURL(root: root)))) ?? []
    }

    static func directory(pipeline id: UUID, root: URL = Paths.pipelines) -> URL {
        root.appendingPathComponent("\(id.uuidString)/Shared", isDirectory: true)
    }

    /// Zips `product` and makes it the pipeline's shared build for `platform`.
    @discardableResult
    static func publish(_ product: BuiltProduct, platform: BuildPlatform, commit: String, subject: String?,
                        pipeline: PipelineConfig, root: URL = Paths.pipelines) async throws -> SharedBuild {
        try await publish(product, platform: platform, commit: commit, subject: subject, pipelineName: pipeline.name,
                          in: directory(pipeline: pipeline.id, root: root))
    }

    /// Zips `product` into `directory` as its build for `platform`, replacing the one before.
    private static func publish(_ product: BuiltProduct, platform: BuildPlatform, commit: String, subject: String?,
                                pipelineName: String, in directory: URL) async throws -> SharedBuild {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appendingPathComponent("\(platform.rawValue).json")
        let previous = (try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: json)))?.build
        var build = SharedBuild(platform: platform, commit: commit, subject: subject,
                                bundleIdentifier: product.bundleIdentifier)
        let staging = directory.appendingPathComponent("\(build.id.uuidString).zip.new")
        do {
            try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", product.appURL.path, staging.path])
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        build.size = (try? fm.attributesOfItem(atPath: staging.path)[.size] as? Int64) ?? 0
        try fm.moveItem(at: staging, to: archiveURL(build.id, in: directory))
        try JSONEncoder().encode(Entry(pipeline: pipelineName, build: build)).write(to: json, options: .atomic)
        // A download of the old archive that's under way keeps its open file.
        if let previous { try? fm.removeItem(at: archiveURL(previous.id, in: directory)) }
        return build
    }

    /// The builds in `directory`, newest first.
    private static func entries(in directory: URL) -> [Entry] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.build.builtAt > $1.build.builtAt }
    }

    // MARK: Pull requests

    /// `Pipelines/<id>/PullRequests/<number>/`: a pull request's builds, like the branch's,
    /// and `pull-request.info` (JSON) once one of its heads has built. Outside `Shared`, so that
    /// pruning the branch's platforms leaves them alone.
    static func pullRequestsDirectory(pipeline id: UUID, root: URL = Paths.pipelines) -> URL {
        root.appendingPathComponent("\(id.uuidString)/PullRequests", isDirectory: true)
    }

    private static func pullRequestDirectory(_ number: Int, pipeline id: UUID, root: URL) -> URL {
        pullRequestsDirectory(pipeline: id, root: root).appendingPathComponent("\(number)", isDirectory: true)
    }

    private static func pullRequestInfoURL(in directory: URL) -> URL {
        directory.appendingPathComponent("pull-request.info")
    }

    /// Zips `product` as the pull request's build for `platform`. Call `finishPullRequest`
    /// after its platforms are built.
    @discardableResult
    static func publish(_ product: BuiltProduct, platform: BuildPlatform, subject: String?, pullRequest: PullRequest,
                        pipeline: PipelineConfig, root: URL = Paths.pipelines) async throws -> SharedBuild {
        try await publish(product, platform: platform, commit: pullRequest.headCommit, subject: subject,
                          pipelineName: pipeline.name,
                          in: pullRequestDirectory(pullRequest.number, pipeline: pipeline.id, root: root))
    }

    /// Records `pullRequest`'s head as built, so clients see the pull request and the builder
    /// doesn't build that head again.
    static func finishPullRequest(_ pullRequest: PullRequest, pipeline id: UUID, root: URL = Paths.pipelines) throws {
        let directory = pullRequestDirectory(pullRequest.number, pipeline: id, root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(pullRequest).write(to: pullRequestInfoURL(in: directory), options: .atomic)
    }

    /// The pipeline's built pull requests, most recently built first.
    static func pullRequests(pipeline id: UUID, root: URL = Paths.pipelines) -> [SharedPullRequest] {
        let base = pullRequestsDirectory(pipeline: id, root: root)
        return ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { directory -> (SharedPullRequest, Date)? in
                guard let info = try? JSONDecoder().decode(
                    PullRequest.self, from: Data(contentsOf: pullRequestInfoURL(in: directory))) else { return nil }
                let builds = entries(in: directory).map(\.build)
                guard let newest = builds.first else { return nil }
                return (SharedPullRequest(number: info.number, title: info.title, author: info.author, url: info.url,
                                          branch: info.headBranch, commit: info.headCommit, builds: builds),
                        newest.builtAt)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// The head commit last built of each pull request, by number.
    static func builtPullRequests(pipeline id: UUID, root: URL = Paths.pipelines) -> [Int: String] {
        Dictionary(pullRequests(pipeline: id, root: root).map { ($0.number, $0.commit) }) { first, _ in first }
    }

    /// Deletes the builds of pull requests not in `keeping` (closed, merged, or no longer among
    /// the most recently updated); of all of them when it's empty.
    static func removePullRequests(pipeline id: UUID, keeping: Set<Int> = [], root: URL = Paths.pipelines) {
        let fm = FileManager.default
        let base = pullRequestsDirectory(pipeline: id, root: root)
        guard !keeping.isEmpty else {
            try? fm.removeItem(at: base)
            return
        }
        for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? []
        where !(Int(name).map(keeping.contains) ?? false) {
            try? fm.removeItem(at: base.appendingPathComponent(name))
        }
    }

    private static func archiveURL(_ build: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(build.uuidString).zip")
    }

    /// Stops sharing a pipeline's builds, or only those of platforms not in `keeping`.
    static func remove(pipeline id: UUID, keeping: Set<BuildPlatform> = [], root: URL = Paths.pipelines) {
        let fm = FileManager.default
        let directory = directory(pipeline: id, root: root)
        guard !keeping.isEmpty else {
            try? fm.removeItem(at: directory)
            return
        }
        for json in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where json.pathExtension == "json" {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: json)),
                  !keeping.contains(entry.build.platform) else { continue }
            try? fm.removeItem(at: json)
            try? fm.removeItem(at: archiveURL(entry.build.id, in: directory))
        }
    }

    /// Stops sharing every pipeline's builds.
    static func removeAll(root: URL = Paths.pipelines) {
        try? FileManager.default.removeItem(at: listURL(root: root))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let id = UUID(uuidString: name) else { continue }
            remove(pipeline: id, root: root)
            removePullRequests(pipeline: id, root: root)
        }
    }

    /// Every listed pipeline, with the builds it has (none before its first build), and any
    /// other pipeline that has builds.
    static func catalog(root: URL = Paths.pipelines) -> [SharedPipeline] {
        let fm = FileManager.default
        let listed = listed(root: root)
        let names = Dictionary(listed.map { ($0.id, $0.name) }) { first, _ in first }
        var ids = listed.map(\.id)
        for id in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).compactMap(UUID.init(uuidString:))
        where names[id] == nil { ids.append(id) }
        return ids.compactMap { id -> SharedPipeline? in
            let entries = entries(in: directory(pipeline: id, root: root))
            guard let name = names[id] ?? entries.first?.pipeline else { return nil }
            let pullRequests = pullRequests(pipeline: id, root: root)
            return SharedPipeline(id: id, name: name, builds: entries.map(\.build),
                                  pullRequests: pullRequests.isEmpty ? nil : pullRequests)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The archive of `build`, if it's still one the pipeline shares.
    static func archive(pipeline id: UUID, build: UUID, root: URL = Paths.pipelines) -> URL? {
        let fm = FileManager.default
        let pullRequests = pullRequestsDirectory(pipeline: id, root: root)
        let directories = [directory(pipeline: id, root: root)]
            + ((try? fm.contentsOfDirectory(atPath: pullRequests.path)) ?? [])
                .filter { Int($0) != nil }
                .map { pullRequests.appendingPathComponent($0, isDirectory: true) }
        return directories.map { archiveURL(build, in: $0) }.first { fm.fileExists(atPath: $0.path) }
    }

    /// Unpacks a downloaded archive into `directory` (replacing what's there) and returns its app.
    static func unpack(_ zip: URL, into directory: URL) async throws -> BuiltProduct {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path])
        let apps = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard let app = apps.first, let bundleID = Xcode.bundleIdentifier(of: app)
        else { throw BuilderError.badArchive }
        return BuiltProduct(appURL: app, bundleIdentifier: bundleID)
    }
}

enum BuilderError: LocalizedError, Equatable {
    case notConnected
    case unauthorized
    case declined
    case awaitingApproval
    case notFound
    case status(Int)
    case notShared
    case noBuild
    case badArchive
    case notAppleSigned

    var errorDescription: String? {
        switch self {
        case .notConnected: "This pipeline's builder isn't in Settings. Add its link there."
        case .unauthorized: "The builder didn't accept this Mac. If it runs Orchard 1.0.15 or earlier, update it there."
        case .declined: "The builder declined this Mac."
        case .awaitingApproval: "Waiting for the builder to approve this Mac."
        case .notFound: "The builder no longer has that build."
        case .status(let code): "The builder answered with HTTP \(code)."
        case .notShared: "The builder doesn't share this pipeline any more."
        case .noBuild: "The builder has no build for the chosen devices yet."
        case .badArchive: "The downloaded build doesn't contain an app."
        case .notAppleSigned: "The device support package isn't signed by Apple, so it wasn't installed."
        }
    }
}

/// Talks to a builder's `BuildServer`.
struct BuilderClient: Equatable, Sendable {
    var link: BuilderLink
    var identity: ClientIdentity

    /// Asks the builder to register a device with its team and build again. A builder that
    /// doesn't know the request (Orchard 1.0.18 or earlier) counts as one that can't register.
    func registerDevice(_ registration: DeviceRegistrationRequest) async throws -> DeviceRegistrationResult {
        var request = request("v1/devices")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(registration)
        // Registering talks to Apple before the builder answers.
        request.timeoutInterval = 90
        let (data, response) = try await Self.cancellable { try await URLSession.shared.data(for: request) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 405 {
            return DeviceRegistrationResult(
                status: .unavailable, message: "The builder runs an older Orchard that can't register devices.")
        }
        try check(response)
        return try JSONDecoder().decode(DeviceRegistrationResult.self, from: data)
    }

    func catalog() async throws -> BuildCatalog {
        var request = request("v1/builds")
        request.timeoutInterval = 20
        let (data, response) = try await Self.cancellable { try await URLSession.shared.data(for: request) }
        try check(response)
        return try JSONDecoder().decode(BuildCatalog.self, from: data)
    }

    /// URLSession reports a cancelled task as `URLError.cancelled`; callers expect `CancellationError`.
    private static func cancellable<T>(_ load: () async throws -> T) async throws -> T {
        do {
            return try await load()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    /// Downloads `build`'s archive to `file`. `progress` gets the fraction done, 0 to 1, each
    /// time it grows by a percent; it may be called on any thread.
    func download(_ build: SharedBuild, pipeline: UUID, to file: URL,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await download("v1/builds/\(pipeline.uuidString)/\(build.id.uuidString).zip", to: file, progress: progress)
    }

    func downloadDeviceSupport(to file: URL) async throws {
        try await download("v1/device-support.pkg", to: file)
    }

    private func download(_ path: String, to file: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let request = request(path)
        let delegate = progress.map(DownloadProgress.init)
        let (temporary, response) = try await Self.cancellable {
            try await URLSession.shared.download(for: request, delegate: delegate)
        }
        try check(response)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: link.baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(identity.token)", forHTTPHeaderField: "Authorization")
        // Lets the builder show who's asking.
        let name = identity.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        request.setValue(name, forHTTPHeaderField: ClientHeader.name)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func check(_ response: URLResponse) throws {
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return
        case 401:
            let access = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: ClientHeader.access)
            throw access == "declined" ? BuilderError.declined : BuilderError.unauthorized
        case 403: throw BuilderError.awaitingApproval
        case 404: throw BuilderError.notFound
        case let code: throw BuilderError.status(code)
        }
    }
}

/// Reports a download's progress from the task's own `Progress`, a whole percent at a time.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: @Sendable (Double) -> Void
    private let state = OSAllocatedUnfairLock<(observation: NSKeyValueObservation?, percent: Int)>(
        uncheckedState: (nil, 0))

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.progress.observe(\.fractionCompleted) { [report, state] progress, _ in
            let fraction = progress.fractionCompleted
            let percent = Int(fraction * 100)
            let grew = state.withLockUnchecked { state -> Bool in
                guard percent > state.percent else { return false }
                state.percent = percent
                return true
            }
            if grew { report(fraction) }
        }
        state.withLockUnchecked { $0.observation = observation }
    }

    /// The observation and this object hold on to each other until it's invalidated.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        state.withLockUnchecked {
            $0.observation?.invalidate()
            $0.observation = nil
        }
    }
}

/// The header a client sends its name in (percent-encoded), and the one a builder marks a
/// declined client's 401 with.
enum ClientHeader {
    static let name = "X-Orchard-Client"
    static let access = "X-Orchard-Access"
}
