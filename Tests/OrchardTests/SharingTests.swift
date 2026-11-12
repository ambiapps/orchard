import Foundation
import os
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

    // MARK: Link

    @Test func linkCarriesAddressAndToken() throws {
        let link = try #require(BuilderLink(" http://office-mac.local:9000/#abc123 \n"))
        #expect(link.baseURL.absoluteString == "http://office-mac.local:9000")
        #expect(link.token == "abc123")
        #expect(BuilderLink(BuilderLink.string(host: "mac.local", port: 8642, token: "t")) == BuilderLink("mac.local/#t"))
    }

    @Test func linkWithoutSchemeOrPortGetsTheDefaults() throws {
        let link = try #require(BuilderLink("office-mac.tailnet.ts.net/#abc"))
        #expect(link.baseURL.absoluteString == "http://office-mac.tailnet.ts.net:\(BuilderLink.defaultPort)")
    }

    @Test func linkNeedsAHostAndAToken() {
        #expect(BuilderLink("") == nil)
        #expect(BuilderLink("http://office-mac.local:8642/") == nil)
        #expect(BuilderLink("ftp://office-mac.local/#abc") == nil)
        #expect(BuilderLink.newToken() != BuilderLink.newToken())
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
        let service = BuildService(name: "Builder", token: "secret", root: root.url, deviceSupport: nil)
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
        let service = BuildService(name: "Builder", token: "secret", root: root.url, deviceSupport: nil)
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

    /// Clients see a builder's pipelines before their first build.
    @Test func pipelinesAreListedBeforeTheyHaveABuild() async throws {
        let root = try TemporaryDirectory()
        let built = PipelineConfig(name: "Built")
        let waiting = PipelineConfig(name: "Waiting")
        let build = try await SharedBuilds.publish(try makeApp(in: root), platform: .iOS, commit: commit,
                                                   subject: nil, pipeline: built, root: root.url)
        SharedBuilds.list([.init(id: waiting.id, name: "Waiting"), .init(id: built.id, name: "Renamed")],
                          root: root.url)
        #expect(SharedBuilds.catalog(root: root.url) == [
            SharedPipeline(id: built.id, name: "Renamed", builds: [build]),
            SharedPipeline(id: waiting.id, name: "Waiting", builds: []),
        ])
        SharedBuilds.removeAll(root: root.url)
        #expect(SharedBuilds.catalog(root: root.url).isEmpty)
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
    private func startServer(root: URL, token: String = "secret") async throws -> (BuildServer, BuilderClient) {
        let server = try BuildServer(
            service: BuildService(name: "Office Mac", token: "secret", root: root, deviceSupport: nil), port: 0)
        let port = try await server.start()
        let link = try #require(BuilderLink("http://127.0.0.1:\(port)/#\(token)"))
        return (server, BuilderClient(link: link))
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
        let progress = OSAllocatedUnfairLock(initialState: [Double]())
        try await client.download(build, pipeline: pipeline.id, to: zip) { fraction in
            progress.withLock { $0.append(fraction) }
        }
        let reported = progress.withLock { $0 }
        #expect(reported.last == 1)
        #expect(reported == reported.sorted())
        let product = try await SharedBuilds.unpack(zip, into: downloads.url.appendingPathComponent("iOS"))
        #expect(product.bundleIdentifier == "com.example.app")
        #expect(try String(contentsOf: product.appURL.appendingPathComponent("binary"), encoding: .utf8) == "contents")
    }

    @Test func aWrongTokenIsRefused() async throws {
        let root = try TemporaryDirectory()
        let (server, client) = try await startServer(root: root.url, token: "wrong")
        defer { server.stop() }
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

    @Test func remotePipelineWaitsForTheBuildersFirstBuild() async throws {
        let builderRoot = try TemporaryDirectory()
        let shared = PipelineConfig(name: "App")
        SharedBuilds.list([.init(id: shared.id, name: "App")], root: builderRoot.url)
        let (server, client) = try await startServer(root: builderRoot.url)
        defer { server.stop() }
        let installed = Installed()
        let clientRoot = try TemporaryDirectory()
        let runner = PipelineRunner(config: PipelineConfig(devices: [.thisMac], remoteID: shared.id),
                                    sharedRoot: clientRoot.url,
                                    deployer: { product, _, _ in await installed.add(product) })
        await runner.check(force: false)
        #expect(runner.lastError == BuilderError.notConnected.errorDescription)
        #expect(!runner.isWaitingForBuild)

        // The builder has the pipeline, but no build: that's waiting, not an error.
        runner.builder = client
        await runner.check(force: false)
        await runner.check(force: false)
        #expect(runner.lastError == nil)
        #expect(runner.isWaitingForBuild)
        #expect(runner.statusLabel == "No build yet")
        #expect(runner.log.filter { $0.text == "Waiting for Office Mac to build this pipeline" }.count == 1)
        #expect(runner.runs.isEmpty)

        // A build for a platform none of the devices has is still waiting.
        let product = try makeApp(in: builderRoot)
        try await SharedBuilds.publish(product, platform: .iOS, commit: commit, subject: nil,
                                       pipeline: shared, root: builderRoot.url)
        await runner.check(force: false)
        #expect(runner.isWaitingForBuild)

        try await SharedBuilds.publish(product, platform: .macOS, commit: commit, subject: nil,
                                       pipeline: shared, root: builderRoot.url)
        await runner.check(force: false)
        #expect(!runner.isWaitingForBuild)
        #expect(await installed.products.count == 1)
        #expect(runner.statusLabel == "Disabled")
    }

    @Test func aPipelineTheBuilderDroppedIsAnError() async throws {
        let builderRoot = try TemporaryDirectory()
        let (server, client) = try await startServer(root: builderRoot.url)
        defer { server.stop() }
        let runner = PipelineRunner(config: PipelineConfig(devices: [.thisMac], remoteID: UUID()),
                                    deployer: { _, _, _ in })
        runner.builder = client
        await runner.check(force: false)
        #expect(runner.lastError == BuilderError.notShared.errorDescription)
        #expect(!runner.isWaitingForBuild)
    }

    private actor Installed {
        private(set) var products: [BuiltProduct] = []
        func add(_ product: BuiltProduct) { products.append(product) }
        private(set) var devices: [String] = []
        func add(_ device: Device) { devices.append(device.name) }
    }

    // MARK: Store

    private let office = BuilderLink("office-mac.local/#token")!
    private let studio = BuilderLink("studio.local/#other")!

    @Test func builderPipelinesAreAddedOnce() throws {
        let store = makeTestStore(pipelines: 0)
        #expect(store.builderLinks == [""])
        store.builderLinks = ["office-mac.local/#token"]
        #expect(store.builderStatus(for: store.builderLinks[0]) == .connecting)
        let shared = SharedPipeline(id: UUID(), name: "Flightradar24", builds: [])
        let catalog = BuildCatalog(builder: "Office Mac", hasDeviceSupport: true, pipelines: [shared])
        store.sync(with: .success(catalog), from: office)
        store.sync(with: .success(catalog), from: office)
        #expect(store.pipelines.map(\.config.name) == ["Flightradar24"])
        let runner = store.pipelines[0]
        #expect(runner.config.remoteID == shared.id)
        #expect(runner.config.isEnabled == false)
        #expect(runner.config.builderLabel == "Office Mac")
        #expect(runner.builder == BuilderClient(link: office))
        #expect(runner.isWaitingForBuild)
        #expect(store.builderStatus(for: store.builderLinks[0]) == .connected(name: "Office Mac", pipelines: 1))
        #expect(store.builderHasDeviceSupport)

        // One the user deleted stays deleted, until its builder is removed and added again.
        store.remove(runner)
        store.sync(with: .success(catalog), from: office)
        #expect(store.pipelines.isEmpty)
        store.removeBuilderLink(at: 0)
        #expect(store.builderLinks == [""])
        #expect(store.builderStatus(for: "") == .none)
        #expect(!store.builderHasDeviceSupport)
        store.builderLinks = ["office-mac.local/#token"]
        store.sync(with: .success(catalog), from: office)
        #expect(store.pipelines.count == 1)
    }

    @Test func eachBuilderHasItsOwnPipelines() throws {
        let store = makeTestStore(pipelines: 0)
        store.builderLinks = ["office-mac.local/#token", "studio.local/#other"]
        let app = SharedPipeline(id: UUID(), name: "App", builds: [])
        let build = SharedBuild(platform: .iOS, commit: commit, bundleIdentifier: "com.example.app")
        let other = SharedPipeline(id: UUID(), name: "App", builds: [build])
        store.sync(with: .success(BuildCatalog(builder: "Office Mac", hasDeviceSupport: false, pipelines: [app])),
                   from: office)
        store.sync(with: .success(BuildCatalog(builder: "Studio", hasDeviceSupport: true, pipelines: [other])),
                   from: studio)
        #expect(store.pipelines.map(\.config.builderLabel) == ["Office Mac", "Studio"])
        #expect(store.pipelines.map(\.builder) == [BuilderClient(link: office), BuilderClient(link: studio)])
        #expect(store.pipelines.map(\.isWaitingForBuild) == [true, false])
        #expect(store.pipelines[1].remoteBuilds == [build])
        #expect(store.builderStatus(for: "studio.local/#other") == .connected(name: "Studio", pipelines: 1))

        // One builder failing says nothing about the other.
        store.sync(with: .failure(BuilderError.unauthorized), from: office)
        #expect(store.builderStatus(for: "office-mac.local/#token") == .failed(BuilderError.unauthorized.errorDescription!))
        #expect(store.builderStatus(for: "studio.local/#other") == .connected(name: "Studio", pipelines: 1))

        // Removing a builder keeps its pipelines, which then have nowhere to get builds from.
        store.removeBuilderLink(at: 0)
        #expect(store.pipelines.count == 2)
        #expect(store.pipelines[0].builder == nil)
        #expect(store.pipelines[1].builder == BuilderClient(link: studio))
        // An answer that was on its way from the removed builder is ignored.
        store.sync(with: .success(BuildCatalog(builder: "Office Mac", hasDeviceSupport: false, pipelines: [])),
                   from: office)
        #expect(store.builderStatus(for: "office-mac.local/#token") == .connecting)
    }

    /// A pipeline follows its builder to a new address (say, its Tailscale name), and one saved
    /// before 1.0.15 finds out which builder it's on.
    @Test func aPipelineFollowsItsBuilderToANewAddress() throws {
        let store = makeTestStore(pipelines: 0)
        store.builderLinks = ["office-mac.local/#token"]
        let shared = SharedPipeline(id: UUID(), name: "App", builds: [])
        let catalog = BuildCatalog(builder: "Office Mac", hasDeviceSupport: false, pipelines: [shared])
        store.sync(with: .success(catalog), from: office)
        let runner = store.pipelines[0]

        runner.config.builderURL = nil
        store.builderLinks = ["office-mac.local/#token"]
        store.sync(with: .success(catalog), from: office)
        #expect(runner.config.builderURL == office.baseURL.absoluteString)

        let moved = try #require(BuilderLink("100.64.0.7/#token"))
        store.builderLinks = ["100.64.0.7/#token"]
        #expect(runner.builder == nil)
        store.sync(with: .success(catalog), from: moved)
        #expect(store.pipelines.count == 1)
        #expect(runner.builder == BuilderClient(link: moved))
    }

    @Test func theLinkOfEarlierVersionsIsKept() throws {
        let name = "OrchardTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("office-mac.local/#token", forKey: "builderLink")
        let store = AppStore(defaults: defaults, discoversDevices: false)
        #expect(store.builderLinks == ["office-mac.local/#token"])
        #expect(store.builders == [office])
        store.builderLinks.append("")
        store.builderLinks[1] = "studio.local/#other"
        #expect(defaults.stringArray(forKey: "builderLinks") == ["office-mac.local/#token", "studio.local/#other"])
    }

    @Test func aBadLinkIsReported() {
        let store = makeTestStore(pipelines: 0)
        store.builderLinks = ["office-mac.local"]
        #expect(store.builderStatus(for: "office-mac.local") == .invalidLink)
        #expect(store.builders.isEmpty)
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
