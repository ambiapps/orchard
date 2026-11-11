import Foundation
import os
import Testing
@testable import Orchard

@MainActor
struct ParallelDeployTests {
    private let devices = ["iPhone", "iPad", "Other iPhone"].map {
        Device(id: $0.lowercased(), name: $0, model: $0, kind: .physical, platform: .iOS, osVersion: "26.0")
    }
    private let product = BuiltProduct(appURL: URL(fileURLWithPath: "/tmp/App.app"), bundleIdentifier: "se.ambi.App")

    /// A disabled runner with one unfinished run for `devices`, deploying with `deployer`.
    private func makeRunner(deployer: @escaping PipelineRunner.DeployAction) -> (PipelineRunner, RunRecord.ID) {
        let runner = PipelineRunner(config: PipelineConfig(devices: devices), deployer: deployer)
        var run = RunRecord(commit: String(repeating: "a", count: 40))
        for device in devices { run.deviceOutcomes[device.id] = .pending }
        runner.runs = [run]
        return (runner, run.id)
    }

    /// Counts the deploys going on at once.
    private actor Tracker {
        private(set) var active = 0
        private(set) var mostActive = 0
        func enter() { active += 1; mostActive = max(mostActive, active) }
        func leave() { active -= 1 }
    }

    @Test func devicesAreDeployedToAtTheSameTime() async throws {
        let tracker = Tracker()
        let count = devices.count
        let (runner, run) = makeRunner { _, _, _ in
            await tracker.enter()
            // Hold on until every device's deploy has started; one at a time, that never happens.
            for _ in 0..<200 where await tracker.active < count {
                try await Task.sleep(for: .milliseconds(10))
            }
            await tracker.leave()
        }
        try await runner.deployAll(product, to: devices, run: run, log: { _ in })
        #expect(await tracker.mostActive == count)
        #expect(runner.runs[0].deviceOutcomes.values.allSatisfy { $0 == .succeeded })
    }

    @Test func oneDeviceFailingDoesNotStopTheOthers() async throws {
        let (runner, run) = makeRunner { _, device, _ in
            switch device.name {
            case "iPhone": throw ShellError(command: "devicectl", status: 1, output: "noise\n  Device is gone  \n")
            case "iPad": throw DeployError.launchFailed("the device was locked")
            default: try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await runner.deployAll(product, to: devices, run: run, log: { _ in })
        let outcomes = runner.runs[0].deviceOutcomes
        #expect(outcomes["iphone"] == .failed("Device is gone"))
        #expect(outcomes["ipad"] == .warning("Installed, but failed to launch: the device was locked"))
        #expect(outcomes["other iphone"] == .succeeded)
    }

    @Test func cancellingStopsEveryDeploy() async throws {
        let (runner, run) = makeRunner { _, _, _ in try await Task.sleep(for: .seconds(60)) }
        let devices = devices, product = product
        let task = Task { try await runner.deployAll(product, to: devices, run: run, log: { _ in }) }
        for _ in 0..<200 where !runner.runs[0].deviceOutcomes.values.allSatisfy({ $0 == .running }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(runner.status == .deploying(devices.map(\.name)))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func logLinesSayWhichDeviceTheyAreFromWhenThereAreSeveral() async throws {
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let log: @Sendable (String) -> Void = { line in lines.withLock { $0.append(line) } }
        let (runner, run) = makeRunner { _, _, log in log("Installing"); log("  ") }

        try await runner.deployAll(product, to: [devices[0]], run: run, log: log)
        #expect(lines.withLock { $0 } == ["Installing", "  "])

        lines.withLock { $0 = [] }
        try await runner.deployAll(product, to: devices, run: run, log: log)
        #expect(lines.withLock { $0.sorted() }
            == ["  ", "  ", "  ", "[Other iPhone] Installing", "[iPad] Installing", "[iPhone] Installing"])
    }

    @Test func statusCountsDevicesWhenThereAreSeveral() {
        #expect(PipelineRunner.Status.deploying(["iPhone"]).label == "Deploying to iPhone…")
        #expect(PipelineRunner.Status.deploying(["iPhone", "iPad"]).label == "Deploying to 2 devices…")
    }
}
