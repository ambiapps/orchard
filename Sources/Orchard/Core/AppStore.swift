import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    private(set) var pipelines: [PipelineRunner] = []
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var isRefreshingDevices = false

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let defaultsKey = "pipelines"
    @ObservationIgnored private var activity: NSObjectProtocol?

    /// Tests pass `defaults: nil` to keep pipelines in memory, so they never read or overwrite
    /// the user's pipelines, and `discoversDevices: false` so they don't depend on the host's devices.
    init(defaults: UserDefaults? = .standard, discoversDevices: Bool = true) {
        self.defaults = defaults
        let configs = defaults?.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode([PipelineConfig].self, from: $0) } ?? []
        pipelines = configs.map(makeRunner)
        updateActivity()
        if discoversDevices { Task { await refreshDevices() } }
    }

    var anyEnabled: Bool { pipelines.contains { $0.config.isEnabled } }
    var anyBusy: Bool { pipelines.contains { $0.status.isBusy } }

    @discardableResult
    func addPipeline() -> PipelineRunner {
        var config = PipelineConfig()
        config.name = "Pipeline \(pipelines.count + 1)"
        let runner = makeRunner(config)
        pipelines.append(runner)
        save()
        return runner
    }

    func remove(_ runner: PipelineRunner) {
        runner.config.isEnabled = false
        pipelines.removeAll { $0.id == runner.id }
        save()
        Task { await runner.cleanUp() }
    }

    func refreshDevices() async {
        isRefreshingDevices = true
        devices = await DeviceDiscovery.discover()
        isRefreshingDevices = false
    }

    func isConnected(_ device: Device) -> Bool {
        devices.first { $0.id == device.id }?.isConnected ?? false
    }

    private func makeRunner(_ config: PipelineConfig) -> PipelineRunner {
        let runner = PipelineRunner(config: config)
        runner.onChange = { [weak self] in
            self?.save()
            self?.updateActivity()
        }
        return runner
    }

    private func save() {
        let data = try? JSONEncoder().encode(pipelines.map(\.config))
        defaults?.set(data, forKey: defaultsKey)
    }

    /// Keeps App Nap from throttling the poll timers while any pipeline is enabled.
    private func updateActivity() {
        if anyEnabled, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Watching branches for changes")
        } else if !anyEnabled, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
