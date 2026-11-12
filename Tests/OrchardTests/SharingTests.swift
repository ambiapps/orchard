import Foundation
import Testing
@testable import Orchard

@MainActor
struct SharingTests {
    private let commit = String(repeating: "a", count: 40)

    /// A fake built app in `directory`.
    private func makeApp(in directory: TemporaryDirectory, bundleID: String = "com.example.app") throws -> BuiltProduct {
        try directory.makeDirectories("Products/App.app")
        let app = directory.url.appendingPathComponent("Products/App.app")
        try #require(NSDictionary(dictionary: ["CFBundleIdentifier": bundleID])
            .write(to: app.appendingPathComponent("Info.plist"), atomically: true))
        try directory.write("Products/App.app/binary", "contents")
        return BuiltProduct(appURL: app, bundleIdentifier: bundleID)
    }

    private func get(_ path: String, token: String? = "secret", method: String = "GET") -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: token.map { ["authorization": "Bearer \($0)"] } ?? [:])
    }

    /// Access that lets in the token "secret".
    private func approving(_ token: String = "secret") -> ClientAccess {
        ClientAccess(approved: [ApprovedClient(name: "Client", tokenHash: ClientAccess.hash(token))])
    }

    // MARK: Link

    @Test func linkIsTheBuildersAddress() throws {
        let link = try #require(BuilderLink(" http://office-mac.local:9000/ \n"))
        #expect(link.baseURL.absoluteString == "http://office-mac.local:9000")
        #expect(BuilderLink(BuilderLink.string(host: "mac.local", port: 8642)) == BuilderLink("mac.local"))
    }

    /// Links from 1.0.14 and earlier end in the builder's shared token, which no longer lets anyone in.
    @Test func anOldLinksTokenIsIgnored() throws {
        #expect(BuilderLink("http://office-mac.local:8642/#4f1c") == BuilderLink("office-mac.local"))
    }

    @Test func linkWithoutSchemeOrPortGetsTheDefaults() throws {
        let link = try #require(BuilderLink("office-mac.tailnet.ts.net"))
        #expect(link.baseURL.absoluteString == "http://office-mac.tailnet.ts.net:\(BuilderLink.defaultPort)")
    }

    @Test func linkNeedsAHost() {
        #expect(BuilderLink("") == nil)
        #expect(BuilderLink("http://") == nil)
        #expect(BuilderLink("ftp://office-mac.local") == nil)
        #expect(BuilderLink.newToken() != BuilderLink.newToken())
    }

    // MARK: Approval

    @Test func aNewClientWaitsForItsCode() throws {
        let access = ClientAccess()
        let code = ClientAccess.code(forToken: "t")
        #expect(access.check(token: "t", name: "Ada's Mac", address: "10.0.0.2") == .pending)
        #expect(access.check(token: "t", name: "Ada's Mac") == .pending)
        let request = try #require(access.pairingRequests.first)
        #expect(access.pairingRequests.count == 1)
        #expect(request.name == "Ada's Mac")
        #expect(request.code == code)
        #expect(ClientIdentity(token: "t", name: "Ada's Mac").code == code)
        let wrong = code == "000000" ? "111111" : "000000"
        #expect(!access.approve(request.id, code: wrong))
        #expect(access.check(token: "t", name: "Ada's Mac") == .pending)
        #expect(access.approve(request.id, code: ClientIdentity.format(code)))
        #expect(access.pairingRequests.isEmpty)
        #expect(access.check(token: "t", name: nil) == .allowed)
        #expect(access.approvedClients.map(\.name) == ["Ada's Mac"])
        #expect(access.approvedClients.first?.tokenHash != "t")
        #expect(access.check(token: "other", name: nil) == .refused)
    }

    @Test func aRequestNeedsATokenAndAName() {
        let access = ClientAccess()
        #expect(access.check(token: nil, name: "Mac") == .refused)
        #expect(access.check(token: "", name: "Mac") == .refused)
        #expect(access.check(token: "t", name: " ") == .refused)
        #expect(access.pairingRequests.isEmpty)
    }

    @Test func aDeclinedClientStaysDeclinedAndARemovedOneAsksAgain() throws {
        let access = ClientAccess()
        _ = access.check(token: "no", name: "Stranger")
        access.decline(try #require(access.pairingRequests.first).id)
        #expect(access.check(token: "no", name: "Stranger") == .declined)
        #expect(access.pairingRequests.isEmpty)
        // Saved declines survive a relaunch.
        #expect(ClientAccess(declined: access.declinedTokens).check(token: "no", name: "Stranger") == .declined)

        _ = access.check(token: "yes", name: "Ada's Mac")
        #expect(access.approve(try #require(access.pairingRequests.first).id, code: ClientAccess.code(forToken: "yes")))
        access.remove(try #require(access.approvedClients.first).id)
        #expect(access.check(token: "yes", name: "Ada's Mac") == .pending)
    }

    @Test func oldAndExcessRequestsAreDropped() {
        let access = ClientAccess()
        let start = Date()
        _ = access.check(token: "gone", name: "Gone", now: start)
        for index in 0..<ClientAccess.maxRequests {
            _ = access.check(token: "t\(index)", name: "Mac \(index)", address: "10.0.0.\(index)",
                             now: start.addingTimeInterval(ClientAccess.requestLifetime + 1 + Double(index)))
        }
        #expect(!access.pairingRequests.contains { $0.name == "Gone" })
        #expect(access.pairingRequests.count == ClientAccess.maxRequests)
        _ = access.check(token: "new", name: "New", now: start.addingTimeInterval(ClientAccess.requestLifetime + 20))
        #expect(access.pairingRequests.count == ClientAccess.maxRequests)
        #expect(access.pairingRequests.contains { $0.name == "New" })
        #expect(!access.pairingRequests.contains { $0.name == "Mac 0" })
        access.prune(now: start.addingTimeInterval(1000))
        #expect(access.pairingRequests.isEmpty)
    }

    /// A Mac sending request after request can't push other Macs' requests out.
    @Test func oneAddressKeepsFewRequests() {
        let access = ClientAccess()
        _ = access.check(token: "real", name: "Ada's Mac", address: "10.0.0.2")
        for index in 0..<50 {
            _ = access.check(token: "spam\(index)", name: "Ada's Mac", address: "10.0.0.66")
        }
        #expect(access.pairingRequests.filter { $0.address == "10.0.0.66" }.count == ClientAccess.maxRequestsPerAddress)
        #expect(access.pairingRequests.contains { $0.address == "10.0.0.2" })
    }

    @Test func codesAreSixDigitsAndDifferByToken() {
        let codes = (0..<50).map { _ in ClientIdentity.new(name: "Mac").code }
        #expect(codes.allSatisfy { $0.count == 6 && $0.allSatisfy(\.isNumber) })
        #expect(Set(codes).count > 40)
        #expect(ClientIdentity.format("012345") == "012 345")
    }

    // MARK: HTTP

    @Test func parsesARequestHead() {
        let head = "GET /v1/builds?x=1 HTTP/1.1\r\nHost: mac:8642\r\nAuthorization:  Bearer secret"
        #expect(HTTPRequest.parse(Data(head.utf8)) == HTTPRequest(
            method: "GET", path: "/v1/builds", headers: ["host": "mac:8642", "authorization": "Bearer secret"]))
        #expect(HTTPRequest.parse(Data("hello".utf8)) == nil)
    }

    @Test func everyRequestNeedsTheToken() throws {
        let root = try TemporaryDirectory()
        let service = BuildService(name: "Builder", access: approving(), root: root.url, deviceSupport: nil)
        #expect(service.response(to: get("/v1/builds", token: nil)).status == 401)
        #expect(service.response(to: get("/v1/builds", token: "wrong")).status == 401)
        #expect(service.response(to: get("/v1/builds")).status == 200)
        #expect(service.response(to: get("/v1/builds", method: "POST")).status == 405)
        #expect(service.response(to: get("/v1/device-support.pkg")).status == 404)
        #expect(service.response(to: get("/etc/passwd")).status == 404)
    }

    @Test func onlyTheCurrentBuildCanBeDownloaded() async throws {
        let root = try TemporaryDirectory()
        let pipeline = PipelineConfig(name: "App")
        let product = try makeApp(in: root)
        let service = BuildService(name: "Builder", access: approving(), root: root.url, deviceSupport: nil)
        let first = try await SharedBuilds.publish(product, platform: .iOS, commit: commit, subject: "One",
                                                   pipeline: pipeline, root: root.url)
        func path(_ build: SharedBuild) -> String { "/v1/builds/\(pipeline.id.uuidString)/\(build.id.uuidString).zip" }
        let archive = SharedBuilds.directory(pipeline: pipeline.id, root: root.url)
            .appendingPathComponent("\(first.id.uuidString).zip")
        #expect(service.response(to: get(path(first))).body == .file(archive))
        #expect(service.response(to: get("/v1/builds/\(pipeline.id.uuidString)/../../secret.zip")).status == 404)

        // The same commit built again is a new build; the old one is gone.
        let second = try await SharedBuilds.publish(product, platform: .iOS, commit: commit, subject: "One",
                                                    pipeline: pipeline, root: root.url)
        #expect(second.id != first.id)
        #expect(service.response(to: get(path(first))).status == 404)
        #expect(service.response(to: get(path(second))).status == 200)
        #expect(SharedBuilds.catalog(root: root.url) == [SharedPipeline(id: pipeline.id, name: "App", builds: [second])])
    }

    @Test func buildsOfPlatformsNoLongerBuiltAreRemoved() async throws {
        let root = try TemporaryDirectory()
        let pipeline = PipelineConfig(name: "App")
        let product = try makeApp(in: root)
        let iOS = try await SharedBuilds.publish(product, platform: .iOS, commit: commit, subject: nil,
                                                 pipeline: pipeline, root: root.url)
        let tvOS = try await SharedBuilds.publish(product, platform: .tvOS, commit: commit, subject: nil,
                                                  pipeline: pipeline, root: root.url)
        SharedBuilds.remove(pipeline: pipeline.id, keeping: [.iOS], root: root.url)
        #expect(SharedBuilds.catalog(root: root.url).first?.builds == [iOS])
        #expect(SharedBuilds.archive(pipeline: pipeline.id, build: tvOS.id, root: root.url) == nil)
        #expect(SharedBuilds.archive(pipeline: pipeline.id, build: iOS.id, root: root.url) != nil)
        SharedBuilds.removeAll(root: root.url)
        #expect(SharedBuilds.catalog(root: root.url).isEmpty)
    }

    // MARK: Server and client

    /// A builder serving `root` on a free port, and a client connected to it.
    private func startServer(root: URL, token: String = "secret",
                             access: ClientAccess? = nil) async throws -> (BuildServer, BuilderClient) {
        let server = try BuildServer(
            service: BuildService(name: "Office Mac", access: access ?? approving(), root: root, deviceSupport: nil),
            port: 0)
        let port = try await server.start()
        let link = try #require(BuilderLink("http://127.0.0.1:\(port)"))
        return (server, BuilderClient(link: link, identity: ClientIdentity(token: token, name: "Client")))
    }

    @Test func clientDownloadsWhatTheBuilderBuilt() async throws {
        let root = try TemporaryDirectory()
        let pipeline = PipelineConfig(name: "App")
        let build = try await SharedBuilds.publish(try makeApp(in: root), platform: .iOS, commit: commit,
                                                   subject: "One", pipeline: pipeline, root: root.url)
        let (server, client) = try await startServer(root: root.url)
        defer { server.stop() }

        let catalog = try await client.catalog()
        #expect(catalog.builder == "Office Mac")
        #expect(catalog.pipelines == [SharedPipeline(id: pipeline.id, name: "App", builds: [build])])
        #expect(build.size > 0)

        let downloads = try TemporaryDirectory()
        let zip = downloads.url.appendingPathComponent("iOS.zip")
        try await client.download(build, pipeline: pipeline.id, to: zip)
        let product = try await SharedBuilds.unpack(zip, into: downloads.url.appendingPathComponent("iOS"))
        #expect(product.bundleIdentifier == "com.example.app")
        #expect(try String(contentsOf: product.appURL.appendingPathComponent("binary"), encoding: .utf8) == "contents")
    }

    @Test func aClientGetsBuildsOnceTheBuilderEntersItsCode() async throws {
        let root = try TemporaryDirectory()
        let access = ClientAccess()
        let (server, unknown) = try await startServer(root: root.url, token: "new", access: access)
        defer { server.stop() }
        var client = unknown
        client.identity = ClientIdentity(token: "new", name: "César's MacBook")
        await #expect(throws: BuilderError.awaitingApproval) { try await client.catalog() }
        let request = try #require(access.pairingRequests.first)
        #expect(request.name == "César's MacBook")
        #expect(request.code == client.identity.code)
        #expect(request.address == "127.0.0.1")
        #expect(access.approve(request.id, code: ClientIdentity.format(client.identity.code)))
        #expect(try await client.catalog().builder == "Office Mac")
    }

    @Test func aDeclinedClientIsRefused() async throws {
        let root = try TemporaryDirectory()
        let access = ClientAccess()
        let (server, client) = try await startServer(root: root.url, token: "wrong", access: access)
        defer { server.stop() }
        await #expect(throws: BuilderError.awaitingApproval) { try await client.catalog() }
        access.decline(try #require(access.pairingRequests.first).id)
        await #expect(throws: BuilderError.declined) { try await client.catalog() }
    }

    /// A builder on 1.0.14 or earlier answers 401 to every client; that isn't a decline.
    @Test func aRefusalWithoutADeclineIsUnauthorized() async throws {
        let root = try TemporaryDirectory()
        let (server, unnamed) = try await startServer(root: root.url, token: "x", access: ClientAccess())
        defer { server.stop() }
        var client = unnamed
        client.identity.name = ""
        await #expect(throws: BuilderError.unauthorized) { try await client.catalog() }
    }

    // MARK: Client pipeline

    @Test func remotePipelineInstallsEachNewBuildOnce() async throws {
        let builderRoot = try TemporaryDirectory()
        let clientRoot = try TemporaryDirectory()
        let shared = PipelineConfig(name: "App")
        let product = try makeApp(in: builderRoot)
        try await SharedBuilds.publish(product, platform: .macOS, commit: commit, subject: "One",
                                       pipeline: shared, root: builderRoot.url)
        let (server, client) = try await startServer(root: builderRoot.url)
        defer { server.stop() }

        let installed = Installed()
        let runner = PipelineRunner(
            config: PipelineConfig(name: "App", devices: [.thisMac], remoteID: shared.id),
            sharedRoot: clientRoot.url,
            deployer: { product, _, _ in await installed.add(product) })
        runner.builder = client

        await runner.check(force: false)
        #expect(runner.lastError == nil)
        #expect(runner.runs.count == 1)
        #expect(runner.runs.first?.outcome == .succeeded)
        #expect(runner.runs.first?.subject == "One")
        #expect(runner.config.lastDeployedCommit == commit)
        let first = try #require(await installed.products.first)
        #expect(first.bundleIdentifier == "com.example.app")
        #expect(first.appURL.resolvingSymlinksInPath().path.hasPrefix(clientRoot.url.path), "\(first.appURL.path)")

        // Nothing new on the builder: nothing is installed.
        await runner.check(force: false)
        #expect(await installed.products.count == 1)

        // The same commit, built again (say, with a new provisioning profile), is a new build.
        try await SharedBuilds.publish(product, platform: .macOS, commit: commit, subject: "One",
                                       pipeline: shared, root: builderRoot.url)
        await runner.check(force: false)
        #expect(await installed.products.count == 2)
        #expect(runner.runs.count == 2)
    }

    /// The builder publishes platforms minutes apart; one platform's new build mustn't
    /// reinstall the other's.
    @Test func eachPlatformIsFollowedByItself() async throws {
        let builderRoot = try TemporaryDirectory()
        let clientRoot = try TemporaryDirectory()
        let shared = PipelineConfig(name: "App")
        let product = try makeApp(in: builderRoot)
        for platform in [BuildPlatform.macOS, .iOS] {
            try await SharedBuilds.publish(product, platform: platform, commit: commit, subject: nil,
                                           pipeline: shared, root: builderRoot.url)
        }
        let (server, client) = try await startServer(root: builderRoot.url)
        defer { server.stop() }
        let phone = Device(id: "phone", name: "iPhone", model: "iPhone", kind: .physical, platform: .iOS,
                           osVersion: "26.0", udid: "00008140-000000000000001E")
        let installed = Installed()
        let runner = PipelineRunner(
            config: PipelineConfig(name: "App", devices: [.thisMac, phone], remoteID: shared.id),
            sharedRoot: clientRoot.url,
            deployer: { _, device, _ in await installed.add(device) })
        runner.builder = client

        await runner.check(force: false)
        #expect(await installed.devices.sorted() == ["iPhone", Device.thisMac.name].sorted())

        let newCommit = String(repeating: "b", count: 40)
        try await SharedBuilds.publish(product, platform: .iOS, commit: newCommit, subject: nil,
                                       pipeline: shared, root: builderRoot.url)
        await runner.check(force: false)
        #expect(await installed.devices.filter { $0 == "iPhone" }.count == 2)
        #expect(await installed.devices.filter { $0 == Device.thisMac.name }.count == 1)
        #expect(runner.runs.first?.commit == newCommit)
        #expect(runner.runs.first?.outcome == .succeeded)
        #expect(runner.runs.first?.deviceOutcomes.keys.sorted() == ["phone"])
    }

    @Test func aPipelineWithoutDevicesOnlyRunsOnABuilder() async {
        let runner = PipelineRunner(
            config: PipelineConfig(repoPath: "/nowhere", branch: "main", scheme: "App", alsoBuilds: .iOS),
            deployer: { _, _, _ in })
        await runner.check(force: true)
        #expect(runner.lastError == "Choose at least one device")
        #expect(runner.runs.isEmpty)
    }

    @Test func remotePipelineSaysWhenTheBuilderHasNoBuild() async throws {
        let builderRoot = try TemporaryDirectory()
        let shared = PipelineConfig(name: "App")
        try await SharedBuilds.publish(try makeApp(in: builderRoot), platform: .iOS, commit: commit, subject: nil,
                                       pipeline: shared, root: builderRoot.url)
        let (server, client) = try await startServer(root: builderRoot.url)
        defer { server.stop() }
        let runner = PipelineRunner(config: PipelineConfig(devices: [.thisMac], remoteID: shared.id),
                                    deployer: { _, _, _ in })
        await runner.check(force: false)
        #expect(runner.lastError == BuilderError.notConnected.errorDescription)
        runner.builder = client
        await runner.check(force: false)
        #expect(runner.lastError == BuilderError.noBuild.errorDescription)
        await runner.check(force: false)
        // The same answer on every poll is logged once.
        #expect(runner.log.filter { $0.text.contains(BuilderError.noBuild.errorDescription!) }.count == 1)
        #expect(runner.runs.isEmpty)
    }

    private actor Installed {
        private(set) var products: [BuiltProduct] = []
        func add(_ product: BuiltProduct) { products.append(product) }
        private(set) var devices: [String] = []
        func add(_ device: Device) { devices.append(device.name) }
    }

    // MARK: Store

    @Test func builderPipelinesAreAddedOnce() throws {
        let store = makeTestStore(pipelines: 0)
        store.builderLink = "office-mac.local"
        let shared = SharedPipeline(id: UUID(), name: "Flightradar24", builds: [])
        let catalog = BuildCatalog(builder: "Office Mac", hasDeviceSupport: true, pipelines: [shared])
        store.sync(with: .success(catalog))
        store.sync(with: .success(catalog))
        #expect(store.pipelines.map(\.config.name) == ["Flightradar24"])
        #expect(store.pipelines[0].config.remoteID == shared.id)
        #expect(store.pipelines[0].config.isEnabled == false)
        #expect(store.pipelines[0].builder == store.builder)
        #expect(store.builderStatus == .connected(name: "Office Mac", pipelines: 1))

        // One the user deleted stays deleted, until the link is entered again.
        store.remove(store.pipelines[0])
        store.sync(with: .success(catalog))
        #expect(store.pipelines.isEmpty)
        store.builderLink = ""
        #expect(store.builderStatus == .none)
        store.builderLink = "office-mac.local"
        store.sync(with: .success(catalog))
        #expect(store.pipelines.count == 1)
    }

    @Test func aBadLinkIsReported() {
        let store = makeTestStore(pipelines: 0)
        store.builderLink = "ftp://office-mac.local"
        #expect(store.builderStatus == .invalidLink)
        #expect(store.builder == nil)
    }

    @Test func aClientShowsItsCodeUntilApproved() throws {
        let store = makeTestStore(pipelines: 0)
        store.builderLink = "office-mac.local"
        let identity = try #require(store.builderIdentity)
        #expect(store.builder?.identity == identity)
        store.sync(with: .failure(BuilderError.awaitingApproval))
        #expect(store.builderStatus == .awaitingApproval(code: identity.code))

        // Correcting the host name keeps the token, and so the approval.
        store.builderLink = "office-mac.tailnet.ts.net"
        #expect(store.builderIdentity == identity)

        store.sync(with: .failure(BuilderError.unauthorized))
        #expect(store.builderStatus == .failed(BuilderError.unauthorized.errorDescription!))
        store.sync(with: .failure(BuilderError.declined))
        #expect(store.builderStatus == .declined)
        let declined = try #require(store.builderIdentity)
        store.requestApprovalAgain()
        #expect(store.builderIdentity?.token != declined.token)
        #expect(store.builder?.identity == store.builderIdentity)
        #expect(store.builderStatus == .connecting)
    }

    @Test func theBuilderApprovesWithTheCode() throws {
        let store = makeTestStore(pipelines: 0)
        #expect(store.clientAccess.check(token: "t", name: "Ada's Mac") == .pending)
        store.accessChanged(newRequest: nil)
        let request = try #require(store.pairingRequests.first)
        #expect(!store.approve(request, code: request.code == "000000" ? "111111" : "000000"))
        #expect(store.approvedClients.isEmpty)
        #expect(store.approve(request, code: request.code))
        #expect(store.pairingRequests.isEmpty)
        #expect(store.approvedClients.map(\.name) == ["Ada's Mac"])
        store.removeClient(store.approvedClients[0])
        #expect(store.approvedClients.isEmpty)
    }

    /// Approved clients are saved, so a builder that relaunches still knows them.
    @Test func approvedClientsAreSaved() throws {
        let suite = "OrchardTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults, discoversDevices: false)
        _ = store.clientAccess.check(token: "t", name: "Ada's Mac")
        store.accessChanged(newRequest: nil)
        let request = try #require(store.pairingRequests.first)
        #expect(store.approve(request, code: request.code))
        let relaunched = AppStore(defaults: defaults, discoversDevices: false)
        #expect(relaunched.approvedClients.map(\.name) == ["Ada's Mac"])
        #expect(relaunched.clientAccess.check(token: "t", name: nil) == .allowed)
    }

    // MARK: Config

    @Test func aRemotePipelineNeedsOnlyDevices() {
        var config = PipelineConfig(remoteID: UUID())
        #expect(config.missingSetup == "Choose at least one device")
        config.devices = [.thisMac]
        #expect(config.missingSetup == nil)
    }

    @Test func aBuilderCanBuildWithoutDevices() {
        var config = PipelineConfig(repoPath: "/repo", branch: "main", scheme: "App")
        #expect(config.missingSetup == "Choose at least one device")
        config.alsoBuilds = .iOS
        #expect(config.missingSetup == nil)
        #expect(config.buildPlatforms == [.iOS])
        config.devices = [.thisMac]
        #expect(config.buildPlatforms == [.iOS, .macOS])
    }

    @Test func timingsSavedBeforeDownloadsDecode() throws {
        let old = #"{"checkout":3,"build":250,"deploy":39}"#
        let timings = try JSONDecoder().decode(RunTimings.self, from: Data(old.utf8))
        #expect(timings.summary(total: 292) == "4m 52s (checkout 3s, build 4m 10s, deploy 39s)")
        #expect(RunTimings(download: 12, deploy: 5).phases == ["download 12s", "deploy 5s"])
    }

    // MARK: Device support

    @Test func devicectlComesFromXcodeOrThePackage() throws {
        let directory = try TemporaryDirectory()
        try directory.makeDirectories("Xcode.app/Contents/Developer/usr/bin", "CommandLineTools/usr/bin", "CoreDevice")
        try directory.write("Xcode.app/Contents/Developer/usr/bin/devicectl", "")
        try directory.write("CoreDevice/devicectl", "")
        let xcode = directory.url.appendingPathComponent("Xcode.app/Contents/Developer")
        let commandLineTools = directory.url.appendingPathComponent("CommandLineTools")
        let standalone = directory.url.appendingPathComponent("CoreDevice/devicectl").path
        #expect(DeviceSupport.tool(developerDirectory: xcode, standalonePath: standalone) == .xcode)
        #expect(DeviceSupport.tool(developerDirectory: commandLineTools, standalonePath: standalone) == .standalone)
        #expect(DeviceSupport.tool(developerDirectory: nil, standalonePath: standalone) == .standalone)
        #expect(DeviceSupport.tool(developerDirectory: nil, standalonePath: standalone + "-missing") == nil)

        #expect(DeviceSupport.package(developerDirectory: xcode) == nil)
        try directory.makeDirectories("Xcode.app/Contents/Resources/Packages")
        try directory.write("Xcode.app/Contents/Resources/Packages/XcodeSystemResources.pkg", "")
        #expect(DeviceSupport.package(developerDirectory: xcode)?.lastPathComponent == "XcodeSystemResources.pkg")
    }

    @Test func onlyApplesOwnPackagesAreInstalled() {
        #expect(DeviceSupport.isAppleSoftware(signature: """
            Package "XcodeSystemResources.pkg":
               Status: signed Apple Software
               Signed with a trusted timestamp on: 2026-10-16 10:58:38 +0000
            """))
        #expect(!DeviceSupport.isAppleSoftware(signature: """
            Package "Other.pkg":
               Status: signed by a developer certificate issued by Apple for distribution
            """))
        #expect(!DeviceSupport.isAppleSoftware(signature: "Status: no signature"))
        #expect(!DeviceSupport.isAppleSoftware(signature: ""))
    }
}
