import Foundation
import Testing
@testable import Orchard

struct DeviceDiscoveryTests {
    private func device(_ name: String, _ kind: DeviceKind) -> Device {
        let platform: BuildPlatform = switch kind {
        case .thisMac: .macOS
        case .physical: .iOS
        case .simulator: .iOSSimulator
        }
        return Device(id: name, name: name, model: name, kind: kind, platform: platform, osVersion: "27.0")
    }

    private func row(_ name: String, _ kind: DeviceKind, connected: Bool) -> DiscoveredDevice {
        DiscoveredDevice(device: device(name, kind), isConnected: connected)
    }

    @Test func enabledDevicesComeFirstThenAvailable() {
        let discovered = [
            row("Mac", .thisMac, connected: true),
            row("iPhone A", .physical, connected: true),
            row("iPhone B", .physical, connected: false),
            row("iPhone C", .physical, connected: false),
            row("Sim A", .simulator, connected: true),
            row("Sim B", .simulator, connected: true),
        ]
        let selected = [device("Sim B", .simulator), device("Missing", .physical), device("iPhone C", .physical)]
        let names = DeviceDiscovery.listRows(discovered: discovered, selected: selected).map(\.device.name)
        #expect(names == ["Sim B", "iPhone C", "Missing", "Mac", "iPhone A", "Sim A", "iPhone B"])
    }

    @Test func availableDevicesComeFirstWhenNoneEnabled() {
        let discovered = [
            row("Mac", .thisMac, connected: true),
            row("iPhone A", .physical, connected: true),
            row("iPhone B", .physical, connected: false),
            row("iPhone C", .physical, connected: false),
            row("Sim A", .simulator, connected: true),
        ]
        let names = DeviceDiscovery.listRows(discovered: discovered, selected: []).map(\.device.name)
        #expect(names == ["Mac", "iPhone A", "Sim A", "iPhone B", "iPhone C"])
    }

    @Test func selectedDiscoveredDeviceIsNotListedTwice() {
        let discovered = [row("Mac", .thisMac, connected: true), row("iPhone A", .physical, connected: true)]
        let selected = [device("iPhone A", .physical)]
        let names = DeviceDiscovery.listRows(discovered: discovered, selected: selected).map(\.device.name)
        #expect(names == ["iPhone A", "Mac"])
    }

    @Test func readsPairedPhysicalDevicesWithTheirHardwareUDID() {
        func entry(_ id: String, udid: String, reality: String, pairing: String, tunnel: String) -> String {
            #"""
            {"identifier":"\#(id)","connectionProperties":{"pairingState":"\#(pairing)","tunnelState":"\#(tunnel)"},
             "deviceProperties":{"name":"\#(id)","osVersionNumber":"27.0"},
             "hardwareProperties":{"platform":"iOS","reality":"\#(reality)","marketingName":"iPhone 17","udid":"\#(udid)"}}
            """#
        }
        let json = #"""
        {"result":{"devices":[\#([
            entry("Offline", udid: "00008110-AAAA", reality: "physical", pairing: "paired", tunnel: "disconnected"),
            entry("Sim", udid: "Sim", reality: "simulated", pairing: "paired", tunnel: "connected"),
            entry("Unpaired", udid: "00008110-BBBB", reality: "physical", pairing: "unpaired", tunnel: "connected"),
            entry("Online", udid: "00008110-CCCC", reality: "physical", pairing: "paired", tunnel: "connected"),
        ].joined(separator: ","))]}}
        """#
        // The listed devices, without this Mac: paired ones only, connected first.
        let physical = DeviceDiscovery.physicalDevices(fromJSON: Data(json.utf8)) ?? []
        let devices = DeviceDiscovery.devices(physical: physical, simulators: []).dropFirst()
        #expect(devices.map(\.id) == ["Online", "Offline"])
        #expect(devices.map(\.device.udid) == ["00008110-CCCC", "00008110-AAAA"])
        #expect(devices.map(\.isConnected) == [true, false])
    }

    @Test func keepsOrderWhenAllAvailable() {
        let discovered = [row("Mac", .thisMac, connected: true), row("Sim B", .simulator, connected: true)]
        #expect(DeviceDiscovery.listRows(discovered: discovered, selected: []).map(\.device.name) == ["Mac", "Sim B"])
    }

    // MARK: devicectl JSON

    /// Entries cut down from `devicectl list devices --json-output` of Xcode 27.2 (jsonVersion 5),
    /// which writes each value twice: in `properties` and in the deprecated top-level dictionaries.
    /// The unpaired and Developer Mode-off entries are the paired ones with the state names
    /// CoreDevice defines, as no such device was at hand to capture.
    private static let json = #"""
    {"info": {"jsonVersion": 5, "outcome": "success"}, "result": {"devices": [
      {"identifier": "WIFI",
       "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork", "tunnelState": "connected"},
       "deviceProperties": {"developerModeStatus": "enabled", "name": "iPhone Duo", "osVersionNumber": "27.2"},
       "hardwareProperties": {"deviceType": "iPhone", "marketingName": "iPhone", "platform": "iOS", "reality": "physical", "udid": "00008160-00121DC90EE00036"},
       "properties": {
         "connection": {"authenticationType": "manualPairing", "lastConnectionDate": 816096240, "pairingState": "paired", "state": "connected", "transportType": "localNetwork", "tunnelIPAddressString": "fd17:d532:183d::1"},
         "hardware": {"deviceType": "iPhone", "marketingName": "iPhone", "platform": "iOS", "productType": "iPhone19,4", "reality": "physical", "udid": "00008160-00121DC90EE00036"},
         "software": {"osVersionNumber": {"components": [27, 2, 0, 0, 0], "stringValue": "27.2"}},
         "state": {"bootState": "booted", "developerModeStatus": {"enabled": {"mode": 1}}, "name": "iPhone Duo", "preparednessState": 7}}},
      {"identifier": "ASLEEP",
       "properties": {
         "connection": {"pairingState": "paired", "state": "disconnected", "transportType": "localNetwork", "tunnelTransportProtocol": "tcp"},
         "hardware": {"deviceType": "iPad", "marketingName": "iPad Pro", "platform": "iOS", "reality": "physical", "udid": "00008103-001904DC0AD1001E"},
         "software": {"osVersionNumber": {"stringValue": "27.1"}},
         "state": {"bootState": "booted", "developerModeStatus": {"enabled": {"mode": 1}}, "name": "iPad Pro"}}},
      {"identifier": "AWAY",
       "properties": {
         "connection": {"authenticationType": "manualPairing", "pairingState": "paired", "state": "unavailable"},
         "hardware": {"deviceType": "iPhone", "marketingName": "iPhone 16", "platform": "iOS", "reality": "physical", "udid": "00008140-0009786824A2201C"},
         "software": {"osVersionNumber": {"stringValue": "27.0"}},
         "state": {"developerModeStatus": {"enabled": {"mode": 1}}, "name": "Sofia’s iPhone"}}},
      {"identifier": "SIM",
       "properties": {
         "connection": {"pairingState": "paired", "state": "disconnected", "transportType": "sameMachine"},
         "hardware": {"deviceType": "iPhone", "marketingName": "iPhone 18 Pro", "platform": "iOS", "reality": "simulated"},
         "state": {"bootState": "shutdown", "name": "Simulator", "preparednessState": 0}}},
      {"identifier": "NEW",
       "properties": {
         "connection": {"pairingState": "unpaired", "state": "disconnected", "transportType": "wired"},
         "hardware": {"deviceType": "iPhone", "platform": "iOS", "udid": "00008150-000615013CD0C01C"},
         "state": {"name": "New iPhone"}}},
      {"identifier": "TRUSTING",
       "properties": {"connection": {"pairingState": "pairingInProgress", "state": "disconnected", "transportType": "wired"}}},
      {"identifier": "NODEVMODE",
       "properties": {
         "connection": {"pairingState": "paired", "state": "connected", "transportType": "wired"},
         "hardware": {"deviceType": "iPhone", "marketingName": "iPhone 17", "platform": "iOS", "reality": "physical"},
         "state": {"developerModeStatus": {"disabled": {}}, "name": "Fresh iPhone"}}},
      {"identifier": "OLDXCODE",
       "connectionProperties": {"pairingState": "paired", "transportType": "wired", "tunnelState": "connected"},
       "deviceProperties": {"developerModeStatus": "disabled", "name": "Old Xcode", "osVersionNumber": "18.5"},
       "hardwareProperties": {"deviceType": "appleTV", "marketingName": "Apple TV 4K", "platform": "tvOS", "reality": "physical", "udid": "0000-TV"}},
      {"identifier": "UNSUPPORTED",
       "properties": {"connection": {"pairingState": "unsupported", "state": "unavailable"},
                      "hardware": {"platform": "iOS", "reality": "physical"}}}
    ]}}
    """#

    private func parsed(_ id: String) -> PhysicalDevice? {
        DeviceDiscovery.physicalDevices(fromJSON: Data(Self.json.utf8))?.first { $0.device.id == id }
    }

    @Test func parsesAConnectedDeviceOnTheNetwork() throws {
        let device = try #require(parsed("WIFI"))
        #expect(device.device == Device(id: "WIFI", name: "iPhone Duo", model: "iPhone", kind: .physical,
                                        platform: .iOS, osVersion: "27.2", udid: "00008160-00121DC90EE00036"))
        #expect(device.pairing == .paired)
        #expect(!device.isWired)
        #expect(device.isReachable)
        #expect(device.isConnected)
        #expect(device.developerMode == true)
    }

    @Test func tellsReachableFromConnectedFromUnavailable() throws {
        // On the network with its tunnel down: devicectl connects when asked to install.
        let asleep = try #require(parsed("ASLEEP"))
        #expect(asleep.isReachable)
        #expect(!asleep.isConnected)
        let away = try #require(parsed("AWAY"))
        #expect(!away.isReachable)
        #expect(!away.isConnected)
    }

    @Test func parsesPairingAndDeveloperModeStates() throws {
        let new = try #require(parsed("NEW"))
        #expect(new.pairing == .unpaired)
        #expect(new.isWired)
        #expect(new.developerMode == nil)
        #expect(new.device.name == "New iPhone")
        // An unpaired device may report nothing but its identifier.
        let trusting = try #require(parsed("TRUSTING"))
        #expect(trusting.pairing == .inProgress)
        #expect(trusting.device.platform == .iOS)
        #expect(try #require(parsed("NODEVMODE")).developerMode == false)
    }

    @Test func readsTheDeprecatedDictionariesOfAnOlderXcode() throws {
        let device = try #require(parsed("OLDXCODE"))
        #expect(device.device.name == "Old Xcode")
        #expect(device.device.platform == .tvOS)
        #expect(device.device.osVersion == "18.5")
        #expect(device.isWired)
        #expect(device.isConnected)
        #expect(device.developerMode == false)
    }

    @Test func skipsSimulatorsAndDevicesThatCannotPair() {
        #expect(parsed("SIM") == nil)
        #expect(parsed("UNSUPPORTED") == nil)
    }

    @Test func listsUnpairedDevicesOnlyWhileTheyAreSetUp() {
        let physical = DeviceDiscovery.physicalDevices(fromJSON: Data(Self.json.utf8)) ?? []
        let paired = [Device.thisMac.id, "NODEVMODE", "OLDXCODE", "WIFI", "AWAY", "ASLEEP"]
        // Without automatic setup the list is what it always was: paired devices only.
        #expect(DeviceDiscovery.devices(physical: physical, simulators: []).map(\.id) == paired)
        let rows = DeviceDiscovery.devices(physical: physical, simulators: [], onboarding: ["NEW": .waitingForTrust])
        #expect(Set(rows.map(\.id)) == Set(paired + ["NEW"]))
        #expect(rows.first { $0.id == "NEW" }?.onboarding == .waitingForTrust)
    }

    /// Not an empty list: a listing that failed mustn't look like every device was unplugged.
    @Test func garbageIsAFailureNotAnEmptyList() {
        #expect(DeviceDiscovery.physicalDevices(fromJSON: Data("not json".utf8)) == nil)
        #expect(DeviceDiscovery.physicalDevices(fromJSON: Data(#"{"result": {"devices": []}}"#.utf8)) == [])
    }
}
