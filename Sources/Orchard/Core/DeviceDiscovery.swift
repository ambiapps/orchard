import Foundation

struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    var device: Device
    var isConnected: Bool
    var id: String { device.id }
}

enum DeviceDiscovery {
    /// This Mac, paired physical devices (via devicectl) and booted simulators (via simctl).
    static func discover() async -> [DiscoveredDevice] {
        async let physical = physicalDevices()
        async let simulators = bootedSimulators()
        return [DiscoveredDevice(device: .thisMac, isConnected: true)] + (await physical) + (await simulators)
    }

    private static func physicalDevices() async -> [DiscoveredDevice] {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchard-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        guard (try? await Shell.xcrun(["devicectl", "list", "devices", "--quiet", "--json-output", output.path])) != nil,
              let data = try? Data(contentsOf: output),
              let response = try? JSONDecoder().decode(DeviceCtlResponse.self, from: data)
        else { return [] }

        return response.result.devices.compactMap { entry in
            guard entry.hardwareProperties.reality == "physical",
                  entry.connectionProperties.pairingState == "paired",
                  let platformName = entry.hardwareProperties.platform,
                  let platform = BuildPlatform(devicePlatform: platformName, simulator: false)
            else { return nil }
            let device = Device(
                id: entry.identifier,
                name: entry.deviceProperties.name ?? entry.hardwareProperties.marketingName ?? "Device",
                model: entry.hardwareProperties.marketingName ?? entry.hardwareProperties.deviceType ?? platformName,
                kind: .physical,
                platform: platform,
                osVersion: entry.deviceProperties.osVersionNumber ?? ""
            )
            return DiscoveredDevice(device: device, isConnected: entry.connectionProperties.tunnelState == "connected")
        }
        .sorted { ($0.isConnected ? 0 : 1, $0.device.name) < ($1.isConnected ? 0 : 1, $1.device.name) }
    }

    private static func bootedSimulators() async -> [DiscoveredDevice] {
        guard let output = try? await Shell.xcrun(["simctl", "list", "devices", "booted", "-j"]),
              let response = try? JSONDecoder().decode(SimctlResponse.self, from: Data(output.utf8))
        else { return [] }

        var result: [DiscoveredDevice] = []
        for (runtime, devices) in response.devices {
            // e.g. com.apple.CoreSimulator.SimRuntime.iOS-27-0
            let runtimeName = runtime.split(separator: ".").last.map(String.init) ?? ""
            let parts = runtimeName.split(separator: "-")
            guard let platformName = parts.first,
                  let platform = BuildPlatform(devicePlatform: String(platformName), simulator: true)
            else { continue }
            let version = parts.dropFirst().joined(separator: ".")
            for sim in devices where sim.state == "Booted" {
                let device = Device(
                    id: sim.udid, name: sim.name, model: "\(platform.displayName) \(version)",
                    kind: .simulator, platform: platform, osVersion: version)
                result.append(DiscoveredDevice(device: device, isConnected: true))
            }
        }
        return result.sorted { $0.device.name < $1.device.name }
    }
}

private struct DeviceCtlResponse: Decodable {
    struct Result: Decodable { var devices: [Entry] }
    struct Entry: Decodable {
        struct Connection: Decodable {
            var pairingState: String?
            var tunnelState: String?
        }
        struct Properties: Decodable {
            var name: String?
            var osVersionNumber: String?
        }
        struct Hardware: Decodable {
            var platform: String?
            var reality: String?
            var marketingName: String?
            var deviceType: String?
        }
        var identifier: String
        var connectionProperties: Connection
        var deviceProperties: Properties
        var hardwareProperties: Hardware
    }
    var result: Result
}

private struct SimctlResponse: Decodable {
    struct Sim: Decodable {
        var udid: String
        var name: String
        var state: String
    }
    var devices: [String: [Sim]]
}
