import CryptoKit
import Foundation
import os
import Testing
@testable import Orchard

@MainActor
struct DeviceRegistrationTests {
    private let signingKey = P256.Signing.PrivateKey()
    private var key: AppStoreConnectKey {
        AppStoreConnectKey(issuerID: "issuer-1", keyID: "ABC123", privateKey: signingKey.pemRepresentation)
    }
    private let phone = Device(id: "phone-id", name: "Kim’s iPhone", model: "iPhone", kind: .physical,
                               platform: .iOS, osVersion: "26.1", udid: "00008140-0000000000000000")

    private func decode(_ part: Substring) throws -> [String: Any] {
        var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        let data = try #require(Data(base64Encoded: text))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: App Store Connect

    @Test func tokenIsAnES256JWTSignedWithTheKey() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try key.token(now: now)
        let parts = token.split(separator: ".")
        try #require(parts.count == 3)
        let header = try decode(parts[0])
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "ABC123")
        let claims = try decode(parts[1])
        #expect(claims["iss"] as? String == "issuer-1")
        #expect(claims["aud"] as? String == "appstoreconnect-v1")
        #expect(claims["iat"] as? Int == 1_800_000_000)
        #expect(claims["exp"] as? Int == 1_800_000_600)

        var signature = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while signature.count % 4 != 0 { signature += "=" }
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(base64Encoded: signature)))
        #expect(signingKey.publicKey.isValidSignature(ecdsa, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func aFileThatIsNotAKeyIsRejected() {
        #expect(throws: AppStoreConnectError.badKey) {
            try AppStoreConnectKey(issuerID: "i", keyID: "k", privateKey: "hello").validate()
        }
        #expect(AppStoreConnectKey.keyID(fromFileName: "AuthKey_ABC123.p8") == "ABC123")
        #expect(AppStoreConnectKey.keyID(fromFileName: "key.p8") == nil)
    }

    /// Answers like App Store Connect: `existing` is the device's status if it's registered.
    private final class FakeAPI: Sendable {
        let requests = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
        let existing: String?
        let createStatus: Int
        /// The device's status once a create failed with 409: someone else registered it.
        let existingAfterConflict: String?

        init(existing: String? = nil, createStatus: Int = 201, existingAfterConflict: String? = nil) {
            self.existing = existing
            self.createStatus = createStatus
            self.existingAfterConflict = existingAfterConflict
        }

        var send: AppStoreConnect.Send {
            { [self] request in
                requests.withLock { $0.append(request) }
                switch request.httpMethod {
                case "GET":
                    let posted = requests.withLock { $0.contains { $0.httpMethod == "POST" } }
                    let data = (posted ? existingAfterConflict : existing).map { #"[{"type":"devices","id":"D1","attributes":{"status":"\#($0)"}}]"# } ?? "[]"
                    return (Data(#"{"data":\#(data)}"#.utf8), 200)
                case "POST":
                    let body = createStatus == 409 ? #"{"errors":[{"detail":"A device with number already exists"}]}"# : "{}"
                    return (Data(body.utf8), createStatus)
                default:
                    return (Data("{}".utf8), 200)
                }
            }
        }
    }

    @Test func registersANewDevice() async throws {
        let api = FakeAPI()
        let result = try await AppStoreConnect(key: key, send: api.send)
            .register(udid: phone.udid!, name: phone.name, platform: .iOS)
        #expect(result == .registered)
        let requests = api.requests.withLock { $0 }
        #expect(requests.map(\.httpMethod) == ["GET", "POST"])
        #expect(requests[0].url?.query()?.contains("filter%5Budid%5D=00008140-0000000000000000") == true
                || requests[0].url?.query()?.contains("filter[udid]=00008140-0000000000000000") == true)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        let body = try #require(try JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data()) as? [String: Any])
        let data = try #require(body["data"] as? [String: Any])
        #expect(data["type"] as? String == "devices")
        #expect(data["id"] == nil)
        let attributes = try #require(data["attributes"] as? [String: Any])
        #expect(attributes["udid"] as? String == phone.udid)
        #expect(attributes["platform"] as? String == "IOS")
        #expect(attributes["name"] as? String == "Kim’s iPhone")
    }

    @Test func aRegisteredDeviceIsLeftAndADisabledOneEnabled() async throws {
        let enabled = FakeAPI(existing: "ENABLED")
        #expect(try await AppStoreConnect(key: key, send: enabled.send)
            .register(udid: "U", name: "N", platform: .iOS) == .alreadyRegistered)
        #expect(enabled.requests.withLock { $0.map(\.httpMethod) } == ["GET"])

        let disabled = FakeAPI(existing: "DISABLED")
        #expect(try await AppStoreConnect(key: key, send: disabled.send)
            .register(udid: "U", name: "N", platform: .iOS) == .enabled)
        let patch = try #require(disabled.requests.withLock { $0.last })
        #expect(patch.httpMethod == "PATCH")
        #expect(patch.url?.lastPathComponent == "D1")

        let raced = FakeAPI(createStatus: 409, existingAfterConflict: "ENABLED")
        #expect(try await AppStoreConnect(key: key, send: raced.send)
            .register(udid: "U", name: "N", platform: .iOS) == .alreadyRegistered)
    }

    /// App Store Connect also answers 409 to a full device list or an invalid UDID.
    @Test func aConflictWithoutTheDeviceIsAnError() async {
        let full = FakeAPI(createStatus: 409)
        await #expect(throws: AppStoreConnectError.status(409, "A device with number already exists")) {
            try await AppStoreConnect(key: key, send: full.send).register(udid: "U", name: "N", platform: .iOS)
        }
    }

    @Test func explainsAKeyThatCannotRegister() async {
        let forbidden: AppStoreConnect.Send = { _ in (Data(), 403) }
        await #expect(throws: AppStoreConnectError.notAllowed) {
            try await AppStoreConnect(key: key, send: forbidden).register(udid: "U", name: "N", platform: .iOS)
        }
        let rejected: AppStoreConnect.Send = { _ in (Data(), 401) }
        await #expect(throws: AppStoreConnectError.notAccepted) {
            try await AppStoreConnect(key: key, send: rejected).verify()
        }
    }

    @Test func keyIsSavedForTheOwnerOnly() throws {
        let directory = try TemporaryDirectory()
        let store = AppStoreConnectKeyStore(directory: directory.url.appendingPathComponent("ASC"))
        #expect(store.load() == nil)
        try store.save(key)
        #expect(store.load() == key)
        let file = directory.url.appendingPathComponent("ASC/key.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        store.remove()
        #expect(store.load() == nil)
    }

    // MARK: Builder

    private func registrar(_ outcome: AppStoreConnect.Registration = .registered,
                           calls: OSAllocatedUnfairLock<[String]>) -> DeviceRegistrar {
        DeviceRegistrar(
            register: { _, request in
                calls.withLock { $0.append("register \(request.udid)") }
                return outcome
            },
            verify: { _ in calls.withLock { $0.append("verify") } },
            removeProfiles: { calls.withLock { $0.append("removeProfiles") } })
    }

    @Test func builderRegistersOnlyWithAKeyAndForItsOwnPipeline() async throws {
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let store = AppStore(defaults: nil, discoversDevices: false, registrar: registrar(calls: calls))
        let runner = store.addPipeline()
        store.sharesBuilds = true
        let request = DeviceRegistrationRequest(pipeline: runner.id, name: phone.name, udid: phone.udid!, platform: .iOS)

        #expect(await store.registerDevice(request, from: "Kim’s Mac") == .unavailable)
        #expect(calls.withLock { $0 }.isEmpty)

        try await store.setAppStoreConnectKey(key)
        #expect(store.appStoreConnectKey == key)
        var other = request
        other.pipeline = UUID()
        #expect(await store.registerDevice(other, from: "Kim’s Mac").status == .failed)

        let result = await store.registerDevice(request, from: "Kim’s Mac")
        #expect(result == DeviceRegistrationResult(status: .registered, rebuilding: true))
        #expect(calls.withLock { $0 } == ["verify", "register \(phone.udid!)", "removeProfiles"])

        store.removeAppStoreConnectKey()
        #expect(await store.registerDevice(request, from: "Kim’s Mac") == .unavailable)
    }

    @Test func aKeyThatDoesNotWorkIsNotKept() async throws {
        let store = AppStore(defaults: nil, discoversDevices: false, registrar: DeviceRegistrar(
            register: { _, _ in .registered },
            verify: { _ in throw AppStoreConnectError.notAccepted },
            removeProfiles: {}))
        await #expect(throws: AppStoreConnectError.notAccepted) { try await store.setAppStoreConnectKey(key) }
        #expect(store.appStoreConnectKey == nil)
    }

    // MARK: Over HTTP

    private func startServer(register: (@Sendable (DeviceRegistrationRequest, String) async -> DeviceRegistrationResult)?)
        async throws -> (BuildServer, BuilderClient) {
        let root = try TemporaryDirectory()
        var service = BuildService(
            name: "Office Mac",
            access: ClientAccess(approved: [ApprovedClient(name: "Client", tokenHash: ClientAccess.hash("secret"))]),
            root: root.url, deviceSupport: nil)
        service.registerDevice = register
        let server = try BuildServer(service: service, port: 0)
        let port = try await server.start()
        let link = try #require(BuilderLink("http://127.0.0.1:\(port)"))
        return (server, BuilderClient(link: link, identity: ClientIdentity(token: "secret", name: "Kim’s Mac")))
    }

    @Test func clientAsksTheBuilderOverHTTP() async throws {
        let received = OSAllocatedUnfairLock<[String]>(initialState: [])
        let (server, client) = try await startServer { request, name in
            received.withLock { $0.append("\(name): \(request.name) \(request.udid) \(request.platform.rawValue)") }
            return DeviceRegistrationResult(status: .registered, rebuilding: true)
        }
        defer { server.stop() }
        let request = DeviceRegistrationRequest(pipeline: UUID(), name: phone.name, udid: phone.udid!, platform: .iOS)
        #expect(try await client.registerDevice(request) == DeviceRegistrationResult(status: .registered, rebuilding: true))
        #expect(received.withLock { $0 } == ["Kim’s Mac: Kim’s iPhone 00008140-0000000000000000 iOS"])

        let stranger = BuilderClient(link: client.link, identity: ClientIdentity(token: "other", name: "Stranger"))
        await #expect(throws: BuilderError.awaitingApproval) { try await stranger.registerDevice(request) }
        #expect(received.withLock { $0.count } == 1)
    }

    @Test func aBuilderWithoutRegistrationSaysItCannot() async throws {
        let (server, client) = try await startServer(register: nil)
        defer { server.stop() }
        let request = DeviceRegistrationRequest(pipeline: UUID(), name: "N", udid: "U", platform: .iOS)
        #expect(try await client.registerDevice(request).status == .unavailable)
    }

    @Test func serverRejectsABadOrOversizedBody() async throws {
        let service = BuildService(
            name: "B", access: ClientAccess(approved: [ApprovedClient(name: "C", tokenHash: ClientAccess.hash("secret"))]),
            deviceSupport: nil)
        var request = HTTPRequest(method: "POST", path: "/v1/devices", headers: ["authorization": "Bearer secret"])
        request.body = Data("nonsense".utf8)
        #expect(await service.respond(to: request).status == 400)
        request.headers["authorization"] = nil
        #expect(await service.respond(to: request).status == 401)
    }

    /// A negative Content-Length used to make the body's range invalid and crash the builder,
    /// before the token was even checked.
    @Test func aNegativeContentLengthIsABadRequest() async throws {
        let (server, client) = try await startServer(register: nil)
        defer { server.stop() }
        let port = try #require(client.link.baseURL.port)
        let head = "POST /v1/devices HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n"
        let answer = try await Self.rawRequest(head, port: port)
        #expect(answer.hasPrefix("HTTP/1.1 400"))
    }

    /// Sends `text` over a plain TCP connection and returns what comes back.
    private static func rawRequest(_ text: String, port: Int) async throws -> String {
        let task = Task.detached { () throws -> String in
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw CocoaError(.fileReadUnknown) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = text.withCString { send(fd, $0, strlen($0), 0) }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = recv(fd, &buffer, buffer.count, 0)
            return String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
        }
        return try await task.value
    }

    @Test func anUnknownStatusIsAFailure() throws {
        let result = try JSONDecoder().decode(DeviceRegistrationResult.self, from: Data(#"{"status":"queued"}"#.utf8))
        #expect(result.status == .failed)
    }

    // MARK: Client

    @Test func clientRemembersARequestUntilTheWarningGoesAway() async throws {
        let (server, client) = try await startServer { _, _ in DeviceRegistrationResult(status: .registered, rebuilding: true) }
        defer { server.stop() }
        var config = PipelineConfig(name: "App")
        config.remoteID = UUID()
        config.builderName = "Office Mac"
        config.devices = [phone]
        let runner = PipelineRunner(config: config)
        runner.builder = client

        let result = await runner.requestRegistration(of: phone)
        #expect(result.status == .registered)
        #expect(RegistrationAlert.from(result, device: phone, builder: "Office Mac") == nil)
        #expect(runner.registrationRequests == [phone.id: .requested])
        // No build lists the phone as missing, so nothing keeps the request once the runner looks again.
        runner.config.devices = []
        #expect(runner.registrationRequests.isEmpty)
    }

    /// If the builder's new build still leaves the device out, the button comes back.
    @Test func aNewBuildWithoutTheDeviceEndsTheRequest() async throws {
        let (server, client) = try await startServer { _, _ in DeviceRegistrationResult(status: .registered, rebuilding: true) }
        defer { server.stop() }
        let dir = try TemporaryDirectory()
        func app(_ name: String) throws -> BuiltProduct {
            try dir.makeDirectories("\(name)/App.app")
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["Name": "iOS Team Provisioning Profile: x", "ProvisionedDevices": ["OTHER"]],
                format: .xml, options: 0)
            try plist.write(to: dir.url.appendingPathComponent("\(name)/App.app/embedded.mobileprovision"))
            return BuiltProduct(appURL: dir.url.appendingPathComponent("\(name)/App.app"), bundleIdentifier: "x")
        }
        var config = PipelineConfig(name: "App")
        config.remoteID = UUID()
        config.devices = [phone]
        let runner = PipelineRunner(config: config)
        runner.builder = client
        var first = RunRecord(commit: String(repeating: "a", count: 40))
        first.products = [BuildPlatform.iOS.rawValue: try app("first")]
        runner.runs = [first]
        #expect(runner.unprovisionedDevices == [phone.id])

        _ = await runner.requestRegistration(of: phone)
        #expect(runner.registrationRequests == [phone.id: .requested])
        var second = RunRecord(commit: String(repeating: "b", count: 40))
        second.products = [BuildPlatform.iOS.rawValue: try app("second")]
        runner.runs = [second, first]
        #expect(runner.unprovisionedDevices == [phone.id])
        #expect(runner.registrationRequests.isEmpty)
    }

    @Test func clientAlertsWhenTheBuilderCannotRegister() async throws {
        let (server, client) = try await startServer(register: nil)
        defer { server.stop() }
        var config = PipelineConfig(name: "App")
        config.remoteID = UUID()
        config.devices = [phone]
        let runner = PipelineRunner(config: config)
        runner.builder = client

        let result = await runner.requestRegistration(of: phone)
        #expect(runner.registrationRequests.isEmpty)
        let alert = try #require(RegistrationAlert.from(result, device: phone, builder: "Office Mac"))
        #expect(alert.title == "Office Mac can't register devices")
        #expect(alert.message.contains("App Store Connect API key"))
        #expect(alert.message.contains(phone.udid!))
        #expect(alert.udid == phone.udid)
    }
}
