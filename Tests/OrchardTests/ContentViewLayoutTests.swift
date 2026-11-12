import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Orchard

@MainActor
struct ContentViewLayoutTests {
    private func makeWindow(width: CGFloat, appearance: NSAppearance.Name? = nil,
                            store: AppStore = makeTestStore()) -> WindowHarness {
        let view = ContentView()
            .environment(store)
            .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
        return WindowHarness(view, size: NSSize(width: width, height: 700), appearance: appearance)
    }

    @Test func usesOneSplitViewForAllColumns() throws {
        let harness = makeWindow(width: 1000)
        defer { harness.close() }
        let split = try #require(harness.splitViews.first)
        #expect(split.isVertical)
        #expect(split.arrangedSubviews.count == 3)
        // A nested horizontal split view in a column is what let the sidebar push it off-window.
        #expect(!harness.splitViews.dropFirst().contains { $0.isVertical })
    }

    /// Dragging the sidebar wider used to grow the detail column past the window's edge.
    @Test(arguments: [Layout.windowMinWidth, 1000, 1400], [0, 360, 700, 5000])
    func resizingSidebarKeepsColumnsInsideWindow(windowWidth: CGFloat, sidebarDrag: CGFloat) throws {
        try checkSidebarResize(windowWidth: windowWidth, sidebarDrag: sidebarDrag, store: makeTestStore())
    }

    /// With nothing selected the activity column is empty, and must still keep its minimum width.
    @Test(arguments: [Layout.windowMinWidth, 1000], [360, 5000])
    func resizingSidebarWithoutPipelinesKeepsColumnsInsideWindow(windowWidth: CGFloat, sidebarDrag: CGFloat) throws {
        try checkSidebarResize(windowWidth: windowWidth, sidebarDrag: sidebarDrag, store: makeTestStore(pipelines: 0))
    }

    private func checkSidebarResize(windowWidth: CGFloat, sidebarDrag: CGFloat, store: AppStore) throws {
        let harness = makeWindow(width: windowWidth, store: store)
        defer { harness.close() }
        let split = try #require(harness.splitViews.first)

        split.setPosition(sidebarDrag, ofDividerAt: 0)
        harness.settle()

        let frame = split.convert(split.bounds, to: nil)
        #expect(frame.minX >= -0.5)
        #expect(frame.maxX <= harness.contentWidth + 0.5)

        let columns = split.arrangedSubviews.map(\.frame)
        try #require(columns.count == 3)
        let (sidebar, settings, activity) = (columns[0], columns[1], columns[2])
        #expect(activity.maxX <= split.bounds.maxX + 0.5)
        // Dragging the divider all the way left collapses the sidebar, which keeps its old frame.
        let sidebarCollapsed = split.isSubviewCollapsed(split.arrangedSubviews[0])
        if !sidebarCollapsed {
            #expect(sidebar.width >= Layout.sidebarMin - 0.5)
            #expect(sidebar.width <= Layout.sidebarMax + 0.5)
        }
        // The settings column runs under the floating sidebar; its visible part must keep its minimum.
        let visibleSettings = settings.maxX - (sidebarCollapsed ? 0 : sidebar.maxX)
        #expect(visibleSettings >= Layout.settingsMin - 0.5)
        #expect(activity.width >= Layout.activityMin - 0.5)
    }

    /// Writes screenshots for PR descriptions: `ORCHARD_SCREENSHOTS=<dir> swift test --filter screenshots`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORCHARD_SCREENSHOTS"] != nil))
    func screenshots() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORCHARD_SCREENSHOTS"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (state, drag) in [("default", CGFloat(0)), ("sidebar-wide", 5000)] {
                let store = makeTestStore()
                let harness = makeWindow(width: 1100, appearance: appearance, store: store)
                defer { harness.close() }
                // The app's `Window` scene sets the title from `navigationTitle`; a bare window doesn't.
                harness.window.title = store.pipelines[0].config.name
                if drag > 0 {
                    harness.splitViews.first?.setPosition(drag, ofDividerAt: 0)
                    harness.settle()
                }
                try harness.snapshot(to: directory.appendingPathComponent("\(state)-\(name).png"))
            }

            try devicesSnapshot(appearance: appearance, to: directory.appendingPathComponent("devices-\(name).png"))
            try onboardingSnapshot(appearance: appearance, to: directory.appendingPathComponent("onboarding-\(name).png"))
            for isOn in [false, true] {
                let store = makeTestStore()
                store.setsUpDevicesAutomatically = isOn
                let settings = WindowHarness(SettingsView().environment(store), size: NSSize(width: 460, height: 200),
                                             appearance: appearance)
                defer { settings.close() }
                settings.window.title = "Orchard Settings"
                try settings.snapshot(to: directory.appendingPathComponent("settings-\(isOn ? "on" : "off")-\(name).png"))
            }

            for state in ["builder", "client"] {
                let store = makeTestStore()
                if state == "builder" {
                    store.sharesBuilds = true
                } else {
                    store.builderLinks = ["http://office-mac.local:8642/#4f1c…", "http://studio.tailnet.ts.net:8642/#9ab2…"]
                    for (link, name) in zip(store.builders, ["Office Mac", "Studio"]) {
                        store.sync(with: .success(BuildCatalog(builder: name, hasDeviceSupport: true, pipelines: [])),
                                   from: link)
                    }
                }
                let settings = WindowHarness(SettingsView().environment(store), size: NSSize(width: 460, height: 200),
                                             appearance: appearance)
                defer { settings.close() }
                settings.window.title = "Orchard Settings"
                try settings.snapshot(to: directory.appendingPathComponent("settings-\(state)-\(name).png"))
            }
            try clientSnapshot(appearance: appearance, deviceSupport: .installed,
                               to: directory.appendingPathComponent("client-\(name).png"))
            try clientSnapshot(appearance: appearance, deviceSupport: .missing,
                               to: directory.appendingPathComponent("client-setup-\(name).png"))
            try builderSnapshot(appearance: appearance, to: directory.appendingPathComponent("builder-\(name).png"))

            let store = makeTestStore()
            let runner = store.pipelines[0]
            let iPhone = Device(id: "iphone", name: "iPhone", model: "iPhone 17 Pro", kind: .physical,
                                platform: .iOS, osVersion: "26.0")
            runner.config.devices = [iPhone]
            runner.runs = sampleRuns(device: iPhone.id)
            let harness = makeWindow(width: 1100, appearance: appearance, store: store)
            defer { harness.close() }
            harness.window.title = runner.config.name
            try harness.snapshot(to: directory.appendingPathComponent("deploys-\(name).png"))
            // Expand the latest deploy's changes: click its "3 commits since …" toggle.
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let table = try #require(views(harness.window.contentView!).compactMap { $0 as? NSTableView }.first)
            let row = table.convert(table.rect(ofRow: 1), to: nil)  // Row 0 is the section header.
            let point = NSPoint(x: row.minX + 40, y: row.minY + 8)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                harness.window.sendEvent(try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: harness.window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            harness.settle()
            try harness.snapshot(to: directory.appendingPathComponent("deploys-expanded-\(name).png"))

            try redeploySnapshot(appearance: appearance, to: directory.appendingPathComponent("redeploy-\(name).png"))
        }
    }

    /// A client's pipeline, which installs a builder's builds; without device support, it offers
    /// to install it.
    private func clientSnapshot(appearance: NSAppearance.Name, deviceSupport: AppStore.DeviceSupportState,
                                to url: URL) throws {
        let iPhone = Device(id: "iphone", name: "Ada's iPhone", model: "iPhone 17 Pro", kind: .physical,
                            platform: .iOS, osVersion: "26.0")
        let this = DiscoveredDevice(device: Device(id: "this-mac", name: "MacBook Air", model: "This Mac",
                                                   kind: .thisMac, platform: .macOS, osVersion: "26.0"), isConnected: true)
        let installed = deviceSupport == .installed
        let store = AppStore(defaults: nil, discoversDevices: false,
                             devices: installed ? [this, DiscoveredDevice(device: iPhone, isConnected: true)] : [this])
        store.builderLinks = ["http://office-mac.local:8642/#token", "http://studio.local:8642/#token"]
        let build = SharedBuild(platform: .iOS, commit: "5e1f0c2a9b7d4e6f8a1b3c5d7e9f0a2b4c6d8e0f",
                                bundleIdentifier: "com.example.app", builtAt: Date().addingTimeInterval(-900))
        store.sync(with: .success(BuildCatalog(builder: "Office Mac", hasDeviceSupport: true, pipelines: [
            SharedPipeline(id: UUID(), name: "Flightradar24", builds: [build]),
            SharedPipeline(id: UUID(), name: "New Design", builds: []),
        ])), from: store.builders[0])
        store.sync(with: .success(BuildCatalog(builder: "Studio", hasDeviceSupport: false, pipelines: [
            SharedPipeline(id: UUID(), name: "Flightradar24", builds: []),
        ])), from: store.builders[1])
        store.deviceSupport = deviceSupport
        let runner = store.pipelines[0]
        if installed {
            runner.config.devices = [iPhone]
            runner.runs = sampleRuns(device: iPhone.id)
        }
        let harness = makeWindow(width: 1100, appearance: appearance, store: store)
        defer { harness.close() }
        harness.window.title = runner.config.name
        try harness.snapshot(to: url)

        // The sidebar's rows by themselves, because the sidebar comes out blank in a render.
        guard installed else { return }
        let rows = VStack(alignment: .leading, spacing: 6) {
            ForEach(store.pipelines) { PipelineRow(runner: $0) }
        }
        .padding(12)
        .frame(width: Layout.sidebarIdeal, alignment: .leading)
        let sidebar = WindowHarness(rows, size: NSSize(width: Layout.sidebarIdeal, height: 150), appearance: appearance)
        defer { sidebar.close() }
        sidebar.window.title = "Pipelines"
        try sidebar.snapshot(to: url.deletingLastPathComponent().appendingPathComponent(
            url.lastPathComponent.replacingOccurrences(of: "client", with: "sidebar")))
    }

    /// A builder's pipeline, with the platform it also builds for its clients.
    private func builderSnapshot(appearance: NSAppearance.Name, to url: URL) throws {
        let store = makeTestStore()
        store.sharesBuilds = true
        let runner = store.pipelines[0]
        runner.config.alsoBuilds = .iOS
        let view = ContentView()
            .environment(store)
            .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
        let harness = WindowHarness(view, size: NSSize(width: 1100, height: 900), appearance: appearance)
        defer { harness.close() }
        harness.window.title = runner.config.name
        try harness.snapshot(to: url)
    }

    /// A deploy that failed on one of two devices, whose build can be deployed to it again.
    private func redeploySnapshot(appearance: NSAppearance.Name, to url: URL) throws {
        let dir = try TemporaryDirectory()
        try dir.makeDirectories("App.app")
        let phone = Device(id: "iphone", name: "iPhone", model: "iPhone 17 Pro", kind: .physical,
                           platform: .iOS, osVersion: "26.0")
        let pad = Device(id: "ipad", name: "iPad Pro", model: "iPad Pro", kind: .physical,
                         platform: .iOS, osVersion: "26.0")
        let store = makeTestStore()
        let runner = store.pipelines[0]
        runner.config.devices = [phone, pad]
        var runs = sampleRuns(device: phone.id)
        runs[0].outcome = .failed("1 of 2 device(s) failed")
        runs[0].deviceOutcomes = [phone.id: .failed("The device is not connected."), pad.id: .succeeded]
        runs[0].products = [BuildPlatform.iOS.rawValue: BuiltProduct(
            appURL: dir.url.appendingPathComponent("App.app"), bundleIdentifier: "com.example.app")]
        runner.runs = runs
        let harness = makeWindow(width: 1100, appearance: appearance, store: store)
        defer { harness.close() }
        harness.window.title = runner.config.name
        try harness.snapshot(to: url)
    }

    /// The settings column with a mix of connected, disconnected and booted simulator devices.
    private func devicesSnapshot(appearance: NSAppearance.Name, to url: URL) throws {
        func device(_ id: String, _ name: String, _ model: String, _ kind: DeviceKind,
                    _ platform: BuildPlatform) -> Device {
            Device(id: id, name: name, model: model, kind: kind, platform: platform, osVersion: "26.0")
        }
        let iPhone = device("iphone", "César's iPhone", "iPhone 17 Pro", .physical, .iOS)
        let iPad = device("ipad", "iPad", "iPad Pro", .physical, .iOS)
        let watch = device("watch", "Apple Watch", "Apple Watch Ultra 3", .physical, .watchOS)
        let simulator = device("sim", "iPhone 17", "iOS 26.0", .simulator, .iOSSimulator)
        let oldPhone = device("old", "Old iPhone", "iPhone 15", .physical, .iOS)
        let store = AppStore(defaults: nil, discoversDevices: false, devices: [
            DiscoveredDevice(device: Device(id: "this-mac", name: "Mac Studio", model: "This Mac",
                                            kind: .thisMac, platform: .macOS, osVersion: "26.0"), isConnected: true),
            DiscoveredDevice(device: iPhone, isConnected: true),
            DiscoveredDevice(device: iPad, isConnected: false),
            DiscoveredDevice(device: watch, isConnected: false),
            DiscoveredDevice(device: simulator, isConnected: true),
        ])
        let runner = store.addPipeline()
        runner.config.devices = [iPhone, simulator, oldPhone]
        let harness = makeWindow(width: 1100, appearance: appearance, store: store)
        defer { harness.close() }
        harness.window.title = runner.config.name
        try harness.snapshot(to: url)
    }

    /// The settings column with automatic setup on: a device in each setup state, and the
    /// "Deploy to new devices" toggle.
    private func onboardingSnapshot(appearance: NSAppearance.Name, to url: URL) throws {
        func row(_ name: String, _ model: String, version: String = "27.0", connected: Bool = false,
                 _ state: OnboardingState?) -> DiscoveredDevice {
            DiscoveredDevice(
                device: Device(id: name, name: name, model: model, kind: .physical, platform: .iOS, osVersion: version),
                isConnected: connected, onboarding: state)
        }
        let ready = row("Office iPhone", "iPhone 17 Pro", connected: true, nil)
        let store = AppStore(defaults: nil, discoversDevices: false, devices: [
            DiscoveredDevice(device: Device(id: "this-mac", name: "Mac Studio", model: "This Mac",
                                            kind: .thisMac, platform: .macOS, osVersion: "27.0"), isConnected: true),
            ready,
            row("Preparing iPhone", "iPhone 17", connected: true, .preparing),
            row("New iPhone", "iPhone", version: "", .waitingForTrust),
            row("Unplugged iPhone", "iPhone", version: "", .waitingForCable),
            row("Fresh iPad", "iPad Air", .developerModeOff),
            row("Away iPhone", "iPhone 16", .unreachable),
            row("Stuck iPhone", "iPhone 15", .failed("The developer disk image could not be mounted")),
        ])
        store.setsUpDevicesAutomatically = true
        let runner = store.addPipeline()
        runner.config.devices = [ready.device]
        let view = ContentView()
            .environment(store)
            .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
        let harness = WindowHarness(view, size: NSSize(width: 1100, height: 1000), appearance: appearance)
        defer { harness.close() }
        harness.window.title = runner.config.name
        try harness.snapshot(to: url)
    }

    private func sampleRuns(device: String) -> [RunRecord] {
        func sha(_ seed: Character) -> String { String(repeating: seed, count: 40) }
        var latest = RunRecord(commit: sha("c"), subject: "Merge feature/search", baseCommit: sha("a"))
        latest.changes = [
            CommitSummary(sha: sha("c"), author: "Ada Lovelace", subject: "Merge feature/search"),
            CommitSummary(sha: sha("b"), author: "Ada Lovelace", subject: "Debounce search queries"),
            CommitSummary(sha: sha("9"), author: "Alan Turing", subject: "Add a search field to the flight list"),
        ]
        latest.outcome = .succeeded
        latest.deviceOutcomes = [device: .succeeded]
        latest.timings = RunTimings(checkout: 3, build: 250, deploy: 39)
        latest.finishedAt = latest.startedAt.addingTimeInterval(292)
        var previous = RunRecord(commit: sha("a"), subject: "Fix crash on launch", baseCommit: sha("8"))
        previous.changes = [CommitSummary(sha: sha("a"), author: "Alan Turing", subject: "Fix crash on launch")]
        previous.outcome = .warning("Installed, but failed to launch on iPhone")
        previous.deviceOutcomes = [device: .warning("Installed, but failed to launch: the device was locked")]
        previous.timings = RunTimings(checkout: 2, build: 1840, deploy: 45)
        previous.finishedAt = previous.startedAt.addingTimeInterval(1887)
        return [latest, previous]
    }
}
