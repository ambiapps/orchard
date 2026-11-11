import Foundation

struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    var device: Device
    var isConnected: Bool
    /// Where automatic setup is with this device; nil when it isn't being set up.
    var onboarding: OnboardingState? = nil
    var id: String { device.id }
}

/// A physical device as `devicectl list devices` reports it, paired or not.
struct PhysicalDevice: Hashable, Sendable {
    enum Pairing: Hashable, Sendable { case paired, unpaired, inProgress }
    var device: Device
    var pairing: Pairing
    /// Connected by cable, which pairing needs.
    var isWired: Bool
    /// Reachable by cable or over the network; devicectl connects the tunnel on demand.
    var isReachable: Bool
    /// The tunnel is up right now.
    var isConnected: Bool
    /// Nil when devicectl doesn't know (yet).
    var developerMode: Bool?
}

enum DeviceDiscovery {
    /// Physical devices (via devicectl) and booted simulators (via simctl). `physical` is nil when
    /// devicectl failed, which is not the same as no devices.
    static func discover() async -> (physical: [PhysicalDevice]?, simulators: [DiscoveredDevice]) {
        async let physical = physicalDevices()
        async let simulators = bootedSimulators()
        return (await physical, await simulators)
    }

    /// The devices to offer: this Mac, paired physical devices and booted simulators. A device that
    /// automatic setup is working on carries its state, and is listed even before it's paired.
    static func devices(physical: [PhysicalDevice], simulators: [DiscoveredDevice],
                        onboarding: [String: OnboardingState] = [:]) -> [DiscoveredDevice] {
        let rows = physical
            .filter { $0.pairing == .paired || onboarding[$0.device.id] != nil }
            .map { DiscoveredDevice(device: $0.device, isConnected: $0.isConnected,
                                    onboarding: onboarding[$0.device.id]) }
            .sorted { ($0.isConnected ? 0 : 1, $0.device.name) < ($1.isConnected ? 0 : 1, $1.device.name) }
        return [DiscoveredDevice(device: .thisMac, isConnected: true)] + rows + simulators
    }

    /// Rows for the device list: discovered devices plus selected ones that weren't discovered.
    /// Enabled (selected) devices come first, then the rest; within each, connected/available ones
    /// come first. Stable, so each group keeps its order (this Mac, physical devices, simulators,
    /// then the missing selected devices).
    static func listRows(discovered: [DiscoveredDevice], selected: [Device]) -> [DiscoveredDevice] {
        let missing = selected
            .filter { device in !discovered.contains { $0.id == device.id } }
            .map { DiscoveredDevice(device: $0, isConnected: false) }
        let all = discovered + missing
        let selectedIDs = Set(selected.map(\.id))
        func rank(_ row: DiscoveredDevice) -> Int {
            (selectedIDs.contains(row.id) ? 0 : 2) + (row.isConnected ? 0 : 1)
        }
        return all.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// `devices` with the hardware UDID filled in for physical devices that were saved without
    /// one. Asks devicectl only when one is missing; a device it doesn't know stays as it is.
    static func fillingUDIDs(_ devices: [Device]) async -> [Device] {
        guard devices.contains(where: { $0.kind == .physical && $0.udid == nil }) else { return devices }
        let known = await physicalDevices() ?? []
        return devices.map { device in
            guard device.kind == .physical, device.udid == nil else { return device }
            var device = device
            device.udid = known.first { $0.device.id == device.id }?.device.udid
            return device
        }
    }

    private static func physicalDevices() async -> [PhysicalDevice]? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchard-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        guard (try? await Shell.xcrun(["devicectl", "list", "devices", "--quiet", "--json-output", output.path])) != nil,
              let data = try? Data(contentsOf: output)
        else { return nil }
        return physicalDevices(fromJSON: data)
    }

    /// Parses `devicectl list devices --json-output`. Reads the `properties` dictionary and falls
    /// back to the deprecated top-level ones, which are all an older Xcode writes.
    static func physicalDevices(fromJSON data: Data) -> [PhysicalDevice]? {
        guard let response = try? JSONDecoder().decode(DeviceCtlResponse.self, from: data) else { return nil }
        return response.result.devices.compactMap { entry in
            let hardware = entry.properties?.hardware ?? entry.hardwareProperties
            let connection = entry.properties?.connection
            let pairing: PhysicalDevice.Pairing
            switch connection?.pairingState ?? entry.connectionProperties?.pairingState {
            case "paired": pairing = .paired
            case "unpaired": pairing = .unpaired
            case "pairingInProgress": pairing = .inProgress
            default: return nil
            }
            // A device that isn't paired yet may not report its hardware; only simulators are ruled out.
            guard pairing == .paired ? hardware?.reality == "physical" : hardware?.reality != "simulated"
            else { return nil }
            let platform = hardware?.platform.flatMap { BuildPlatform(devicePlatform: $0, simulator: false) }
            guard let platform = platform ?? (pairing == .paired ? nil : .iOS) else { return nil }

            let marketingName = hardware?.marketingName
            let device = Device(
                id: entry.identifier,
                name: entry.properties?.state?.name ?? entry.deviceProperties?.name ?? marketingName ?? "Device",
                model: marketingName ?? hardware?.deviceType ?? platform.displayName,
                kind: .physical,
                platform: platform,
                osVersion: entry.properties?.software?.osVersionNumber?.stringValue
                    ?? entry.deviceProperties?.osVersionNumber ?? "",
                udid: hardware?.udid
            )
            let state = connection?.state ?? entry.connectionProperties?.tunnelState
            let transport = connection?.transportType ?? entry.connectionProperties?.transportType
            return PhysicalDevice(
                device: device, pairing: pairing,
                isWired: transport == "wired",
                isReachable: state == "connected" || (state == "disconnected" && transport != nil),
                isConnected: state == "connected",
                developerMode: (entry.properties?.state?.developerModeStatus
                    ?? entry.deviceProperties?.developerModeStatus)?.isEnabled)
        }
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
            /// "connected", "disconnected" (reachable, tunnel down) or "unavailable".
            var state: String?
            /// The deprecated name of `state`.
            var tunnelState: String?
            /// "wired" or "localNetwork"; missing when the device can't be reached.
            var transportType: String?
        }
        /// `{"enabled": {…}}` in `properties`, a plain "enabled" in the deprecated dictionary.
        struct DeveloperMode: Decodable {
            var isEnabled: Bool
            init(from decoder: Decoder) throws {
                if let name = try? decoder.singleValueContainer().decode(String.self) {
                    isEnabled = name == "enabled"
                } else {
                    isEnabled = try decoder.container(keyedBy: Key.self).allKeys.contains { $0.stringValue == "enabled" }
                }
            }
            struct Key: CodingKey {
                var stringValue: String
                var intValue: Int? { nil }
                init?(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { nil }
            }
        }
        struct State: Decodable {
            var name: String?
            var developerModeStatus: DeveloperMode?
        }
        struct Version: Decodable { var stringValue: String? }
        struct Software: Decodable { var osVersionNumber: Version? }
        struct Hardware: Decodable {
            var platform: String?
            var reality: String?
            var marketingName: String?
            var deviceType: String?
            var udid: String?
        }
        struct Properties: Decodable {
            var connection: Connection?
            var hardware: Hardware?
            var software: Software?
            var state: State?
        }
        struct DeprecatedProperties: Decodable {
            var name: String?
            var osVersionNumber: String?
            var developerModeStatus: DeveloperMode?
        }
        var identifier: String
        var properties: Properties?
        var connectionProperties: Connection?
        var deviceProperties: DeprecatedProperties?
        var hardwareProperties: Hardware?
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
