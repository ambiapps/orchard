import Foundation

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
}

/// What `GET /v1/builds` returns.
struct BuildCatalog: Codable, Sendable {
    var builder: String
    /// Whether the builder can hand out the package with `devicectl` (it has Xcode).
    var hasDeviceSupport: Bool
    var pipelines: [SharedPipeline]
}

/// The address a client enters: `http://host:port`. Links from Orchard 1.0.14 and earlier end in
/// `#token`; that part is ignored, because each client now gets its own token by being approved.
struct BuilderLink: Equatable, Sendable {
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

    static func directory(pipeline id: UUID, root: URL = Paths.pipelines) -> URL {
        root.appendingPathComponent("\(id.uuidString)/Shared", isDirectory: true)
    }

    /// Zips `product` and makes it the pipeline's shared build for `platform`.
    @discardableResult
    static func publish(_ product: BuiltProduct, platform: BuildPlatform, commit: String, subject: String?,
                        pipeline: PipelineConfig, root: URL = Paths.pipelines) async throws -> SharedBuild {
        let directory = directory(pipeline: pipeline.id, root: root)
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
        try JSONEncoder().encode(Entry(pipeline: pipeline.name, build: build)).write(to: json, options: .atomic)
        // A download of the old archive that's under way keeps its open file.
        if let previous { try? fm.removeItem(at: archiveURL(previous.id, in: directory)) }
        return build
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
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            if let id = UUID(uuidString: name) { remove(pipeline: id, root: root) }
        }
    }

    static func catalog(root: URL = Paths.pipelines) -> [SharedPipeline] {
        let fm = FileManager.default
        let ids = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).compactMap(UUID.init(uuidString:))
        return ids.compactMap { id -> SharedPipeline? in
            let directory = directory(pipeline: id, root: root)
            let entries = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
                .compactMap { try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0)) }
                .sorted { $0.build.builtAt > $1.build.builtAt }
            guard let newest = entries.first else { return nil }
            return SharedPipeline(id: id, name: newest.pipeline, builds: entries.map(\.build))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The archive of `build`, if it's still one the pipeline shares.
    static func archive(pipeline id: UUID, build: UUID, root: URL = Paths.pipelines) -> URL? {
        let archive = archiveURL(build, in: directory(pipeline: id, root: root))
        return FileManager.default.fileExists(atPath: archive.path) ? archive : nil
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
        case .notConnected: "No builder link. Add one in Settings."
        case .unauthorized: "The builder didn't accept this Mac. If it runs Orchard 1.0.14 or earlier, update it there."
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

    /// Downloads `build`'s archive to `file`.
    func download(_ build: SharedBuild, pipeline: UUID, to file: URL) async throws {
        try await download("v1/builds/\(pipeline.uuidString)/\(build.id.uuidString).zip", to: file)
    }

    func downloadDeviceSupport(to file: URL) async throws {
        try await download("v1/device-support.pkg", to: file)
    }

    private func download(_ path: String, to file: URL) async throws {
        let request = request(path)
        let (temporary, response) = try await Self.cancellable { try await URLSession.shared.download(for: request) }
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

/// The header a client sends its name in (percent-encoded), and the one a builder marks a
/// declined client's 401 with.
enum ClientHeader {
    static let name = "X-Orchard-Client"
    static let access = "X-Orchard-Access"
}
