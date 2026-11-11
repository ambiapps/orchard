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

/// The one string a client needs: `http://host:port/#token`.
struct BuilderLink: Equatable, Sendable {
    static let defaultPort = 8642

    var baseURL: URL
    var token: String

    /// Nil unless `string` has a host and a token. The scheme and port may be left out.
    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              let token = components.fragment, !token.isEmpty,
              components.scheme == "http" || components.scheme == "https"
        else { return nil }
        if components.port == nil, components.scheme == "http" { components.port = Self.defaultPort }
        components.fragment = nil
        components.path = ""
        components.query = nil
        guard let url = components.url else { return nil }
        baseURL = url
        self.token = token
    }

    static func string(host: String, port: Int, token: String) -> String {
        "http://\(host):\(port)/#\(token)"
    }

    static func newToken() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// The shared builds on disk: `Pipelines/<id>/Shared/<platform>.zip` with a `<platform>.json`
/// next to it. The server reads these files and nothing else, so a build that's being replaced
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
        let zip = directory.appendingPathComponent("\(platform.rawValue).zip")
        let json = directory.appendingPathComponent("\(platform.rawValue).json")
        let staging = directory.appendingPathComponent("\(platform.rawValue).zip.new")
        try? fm.removeItem(at: staging)
        try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", product.appURL.path, staging.path])

        var build = SharedBuild(platform: platform, commit: commit, subject: subject,
                                bundleIdentifier: product.bundleIdentifier)
        build.size = (try? fm.attributesOfItem(atPath: staging.path)[.size] as? Int64) ?? 0
        // Without its description the old build is gone for clients, so none of them gets the
        // new archive under the old build's id.
        try? fm.removeItem(at: json)
        try? fm.removeItem(at: zip)
        try fm.moveItem(at: staging, to: zip)
        try JSONEncoder().encode(Entry(pipeline: pipeline.name, build: build)).write(to: json, options: .atomic)
        return build
    }

    static func remove(pipeline id: UUID, root: URL = Paths.pipelines) {
        try? FileManager.default.removeItem(at: directory(pipeline: id, root: root))
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

    /// The archive of `build`, if it's still the pipeline's current one.
    static func archive(pipeline id: UUID, build: UUID, root: URL = Paths.pipelines) -> URL? {
        guard let shared = catalog(root: root).first(where: { $0.id == id })?.builds.first(where: { $0.id == build })
        else { return nil }
        return directory(pipeline: id, root: root).appendingPathComponent("\(shared.platform.rawValue).zip")
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
    case notFound
    case status(Int)
    case notShared
    case noBuild
    case badArchive
    case notAppleSigned

    var errorDescription: String? {
        switch self {
        case .notConnected: "No builder link. Add one in Settings."
        case .unauthorized: "The builder didn't accept the link's token."
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

    func catalog() async throws -> BuildCatalog {
        var request = request("v1/builds")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        return try JSONDecoder().decode(BuildCatalog.self, from: data)
    }

    /// Downloads `build`'s archive to `file`.
    func download(_ build: SharedBuild, pipeline: UUID, to file: URL) async throws {
        try await download("v1/builds/\(pipeline.uuidString)/\(build.id.uuidString).zip", to: file)
    }

    func downloadDeviceSupport(to file: URL) async throws {
        try await download("v1/device-support.pkg", to: file)
    }

    private func download(_ path: String, to file: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(for: request(path))
        try check(response)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: link.baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func check(_ response: URLResponse) throws {
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return
        case 401: throw BuilderError.unauthorized
        case 404: throw BuilderError.notFound
        case let code: throw BuilderError.status(code)
        }
    }
}
