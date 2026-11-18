import CryptoKit
import Foundation

/// An App Store Connect API key, with which a builder registers its clients' devices with its team.
struct AppStoreConnectKey: Codable, Equatable, Sendable {
    var issuerID: String
    var keyID: String
    /// The contents of the `AuthKey_<key id>.p8` file: a PKCS #8 PEM.
    var privateKey: String

    /// Throws when `privateKey` isn't a P-256 key.
    func validate() throws {
        _ = try signingKey()
    }

    private func signingKey() throws -> P256.Signing.PrivateKey {
        do {
            return try P256.Signing.PrivateKey(pemRepresentation: privateKey)
        } catch {
            throw AppStoreConnectError.badKey
        }
    }

    /// A JSON Web Token for the API, valid for `lifetime` (at most 20 minutes).
    func token(now: Date = Date(), lifetime: TimeInterval = 600) throws -> String {
        struct Header: Encodable { var alg = "ES256"; var kid: String; var typ = "JWT" }
        struct Claims: Encodable { var iss: String; var iat: Int; var exp: Int; var aud = "appstoreconnect-v1" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let issued = Int(now.timeIntervalSince1970)
        let input = try encoder.encode(Header(kid: keyID)).base64URL + "."
            + encoder.encode(Claims(iss: issuerID, iat: issued, exp: issued + Int(lifetime))).base64URL
        let signature = try signingKey().signature(for: Data(input.utf8))
        return input + "." + signature.rawRepresentation.base64URL
    }

    /// The key id in a file Apple named `AuthKey_<key id>.p8`.
    static func keyID(fromFileName name: String) -> String? {
        guard name.hasPrefix("AuthKey_"), name.hasSuffix(".p8") else { return nil }
        let id = String(name.dropFirst(8).dropLast(3))
        return id.isEmpty ? nil : id
    }
}

/// Where the builder keeps its key: a file only this user can read, in Orchard's Application
/// Support folder. Not the keychain: Orchard is signed ad hoc, so every update would make the
/// keychain ask for permission, and a headless builder has nobody to click Allow.
struct AppStoreConnectKeyStore: Sendable {
    var directory: URL = Paths.appSupport.appendingPathComponent("AppStoreConnect", isDirectory: true)

    private var file: URL { directory.appendingPathComponent("key.json") }

    func load() -> AppStoreConnectKey? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(AppStoreConnectKey.self, from: $0) }
    }

    func save(_ key: AppStoreConnectKey) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(key)
        // Created with owner-only permissions, so the key is never readable by others, not even briefly.
        let staging = directory.appendingPathComponent("key.json.new")
        try? fm.removeItem(at: staging)
        guard fm.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try fm.replaceItemAt(file, withItemAt: staging)
    }

    func remove() {
        try? FileManager.default.removeItem(at: file)
    }
}

enum AppStoreConnectError: LocalizedError, Equatable {
    case badKey
    case notAccepted
    case notAllowed
    case status(Int, String?)

    var errorDescription: String? {
        switch self {
        case .badKey: "That file isn't an App Store Connect API key (.p8)."
        case .notAccepted: "App Store Connect didn't accept the key. Check the issuer ID and key ID."
        case .notAllowed: "The key isn't allowed to register devices. Give it the Admin role in App Store Connect."
        case .status(let code, let detail): detail ?? "App Store Connect answered with HTTP \(code)."
        }
    }
}

/// The part of the App Store Connect API that registers devices.
struct AppStoreConnect: Sendable {
    enum Registration: Equatable, Sendable {
        /// Newly added to the team.
        case registered
        /// It was there but disabled, and is enabled again.
        case enabled
        case alreadyRegistered
    }

    typealias Send = @Sendable (URLRequest) async throws -> (Data, Int)

    var key: AppStoreConnectKey
    var send: Send = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static let baseURL = URL(string: "https://api.appstoreconnect.apple.com/v1/")!
    /// The portal rejects longer device names.
    static let maxNameLength = 50

    /// Checks that the key works, by listing one device.
    func verify() async throws {
        _ = try await devices(query: [URLQueryItem(name: "limit", value: "1")])
    }

    /// Adds the device to the team, or enables it if it was disabled.
    func register(udid: String, name: String, platform: BuildPlatform) async throws -> Registration {
        if let existing = try await devices(query: [URLQueryItem(name: "filter[udid]", value: udid),
                                                    URLQueryItem(name: "limit", value: "1")]).first {
            guard existing.attributes?.status == "DISABLED" else { return .alreadyRegistered }
            let body = Body(data: .init(type: "devices", id: existing.id, attributes: .init(status: "ENABLED")))
            _ = try await call("PATCH", "devices/\(existing.id)", body: body)
            return .enabled
        }
        let body = Body(data: .init(type: "devices", attributes: .init(
            name: String(name.prefix(Self.maxNameLength)), platform: platform == .macOS ? "MAC_OS" : "IOS",
            udid: udid)))
        do {
            _ = try await call("POST", "devices", body: body)
            return .registered
        } catch AppStoreConnectError.status(409, let detail) {
            // 409 is also a full device list, an invalid UDID or name. Only a device that's
            // there now was registered by someone else in the meantime.
            let found = try? await devices(query: [URLQueryItem(name: "filter[udid]", value: udid),
                                                   URLQueryItem(name: "limit", value: "1")])
            if found?.first?.attributes?.status == "ENABLED" { return .alreadyRegistered }
            throw AppStoreConnectError.status(409, detail)
        }
    }

    // MARK: Wire format

    struct DeviceAttributes: Codable {
        var name: String?
        var platform: String?
        var udid: String?
        var status: String?
    }
    struct Resource: Codable {
        var type: String
        var id: String?
        var attributes: DeviceAttributes?
    }
    struct Body: Encodable { var data: Resource }
    private struct List: Decodable { var data: [DeviceResource] }
    private struct DeviceResource: Decodable { var id: String; var attributes: DeviceAttributes? }
    private struct Errors: Decodable {
        struct Item: Decodable { var detail: String?; var title: String? }
        var errors: [Item]
    }

    private func devices(query: [URLQueryItem]) async throws -> [DeviceResource] {
        let data = try await call("GET", "devices", query: query)
        return try JSONDecoder().decode(List.self, from: data).data
    }

    private func call(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      body: Body? = nil) async throws -> Data {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(try key.token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, status) = try await send(request)
        switch status {
        case 200..<300: return data
        case 401: throw AppStoreConnectError.notAccepted
        case 403: throw AppStoreConnectError.notAllowed
        default:
            let item = (try? JSONDecoder().decode(Errors.self, from: data))?.errors.first
            throw AppStoreConnectError.status(status, item?.detail ?? item?.title)
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// How a builder registers a client's device. Tests replace it; the real one calls App Store
/// Connect and deletes Xcode's cached profiles.
struct DeviceRegistrar: Sendable {
    var register: @Sendable (AppStoreConnectKey, DeviceRegistrationRequest) async throws -> AppStoreConnect.Registration
    var verify: @Sendable (AppStoreConnectKey) async throws -> Void
    /// Deletes the cached Xcode-managed profiles, so the next build fetches one with the new device.
    var removeProfiles: @Sendable () -> Void

    static let appStoreConnect = DeviceRegistrar(
        register: { key, request in
            try await AppStoreConnect(key: key).register(udid: request.udid, name: request.name, platform: request.platform)
        },
        verify: { try await AppStoreConnect(key: $0).verify() },
        removeProfiles: { _ = Provisioning.removeXcodeManagedProfiles() })
}
