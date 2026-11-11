import Foundation
import Testing
@testable import Orchard

struct ProvisioningTests {
    private let phoneUDID = "00008110-000A21862E20A01E"
    private let padUDID = "00008030-001D790A0A3B802E"

    private func device(_ name: String, udid: String?, kind: DeviceKind = .physical) -> Device {
        Device(id: name, name: name, model: name, kind: kind,
               platform: kind == .physical ? .iOS : .iOSSimulator, osVersion: "27.0", udid: udid)
    }

    /// A profile as it is on disk: an XML plist with CMS signature bytes around it.
    private func profileData(name: String = "iOS Team Provisioning Profile: com.example.app",
                             devices: [String]?, managed: Bool = true, allDevices: Bool = false) throws -> Data {
        var plist: [String: Any] = ["Name": name, "IsXcodeManaged": managed]
        if let devices { plist["ProvisionedDevices"] = devices }
        if allDevices { plist["ProvisionsAllDevices"] = true }
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return Data([0x30, 0x82, 0xC5, 0x93, 0x06, 0x09]) + xml + Data([0xA0, 0x82, 0x00, 0xFF])
    }

    /// Writes an .app at `path` in `directory` with a profile at each of `profiles`' relative paths.
    private func makeApp(in directory: TemporaryDirectory, profiles: [String: [String]]) throws -> URL {
        let app = directory.url.appendingPathComponent("App.app")
        for (path, devices) in profiles {
            let url = app.appendingPathComponent(path).appendingPathComponent("embedded.mobileprovision")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try profileData(devices: devices).write(to: url)
        }
        return app
    }

    // MARK: Reading profiles

    @Test func readsTheProfileInsideItsSignature() throws {
        let profile = try #require(Provisioning.profile(from: profileData(devices: [phoneUDID.lowercased()])))
        #expect(profile.name == "iOS Team Provisioning Profile: com.example.app")
        #expect(profile.isXcodeManaged)
        #expect(!profile.provisionsAllDevices)
        #expect(profile.devices == [phoneUDID])
    }

    @Test func dataWithoutAPlistIsNotAProfile() {
        #expect(Provisioning.profile(from: Data("not a profile".utf8)) == nil)
        #expect(Provisioning.profile(from: Data("<?xml garbage </plist>".utf8)) == nil)
    }

    @Test func comparesUDIDsIgnoringCase() throws {
        let profile = try #require(Provisioning.profile(from: profileData(devices: ["ABCDEF0123"])))
        #expect(profile.covers(udid: "abcdef0123"))
        #expect(!profile.covers(udid: "abcdef0124"))
    }

    @Test func aProfileForAllDevicesCoversAnyDevice() throws {
        let profile = try #require(Provisioning.profile(from: profileData(devices: nil, allDevices: true)))
        #expect(profile.covers(udid: phoneUDID))
    }

    // MARK: Checking an app

    @Test func findsTheAppsAndItsExtensionsProfiles() throws {
        let directory = try TemporaryDirectory()
        let app = try makeApp(in: directory, profiles: [
            "": [], "PlugIns/Widget.appex": [], "Extensions/Share.appex": [], "AppClips/Clip.app": [],
            "Watch/Watch.app": [], "Watch/Watch.app/PlugIns/Complication.appex": [],
        ])
        // Relative to the app; the enumerator may spell the temporary directory differently.
        let found = Provisioning.embeddedProfiles(in: app).map {
            $0.deletingLastPathComponent().path.components(separatedBy: "/App.app").last ?? ""
        }
        #expect(Set(found) == ["", "/PlugIns/Widget.appex", "/Extensions/Share.appex", "/AppClips/Clip.app"])
    }

    @Test func noDeviceIsMissingWhenEveryProfileListsThem() throws {
        let directory = try TemporaryDirectory()
        let app = try makeApp(in: directory, profiles: [
            "": [phoneUDID, padUDID], "PlugIns/Widget.appex": [padUDID, phoneUDID],
        ])
        let devices = [device("iPhone", udid: phoneUDID), device("iPad", udid: padUDID)]
        #expect(Provisioning.devicesMissing(fromProfilesIn: app, devices: devices).isEmpty)
    }

    @Test func aDeviceMissingFromTheAppsProfileIsReported() throws {
        let directory = try TemporaryDirectory()
        let app = try makeApp(in: directory, profiles: ["": [padUDID]])
        let devices = [device("iPhone", udid: phoneUDID), device("iPad", udid: padUDID)]
        #expect(Provisioning.devicesMissing(fromProfilesIn: app, devices: devices).map(\.name) == ["iPhone"])
    }

    @Test func aDeviceMissingFromOnlyAnExtensionsProfileIsReported() throws {
        let directory = try TemporaryDirectory()
        let app = try makeApp(in: directory, profiles: [
            "": [phoneUDID, padUDID], "PlugIns/Widget.appex": [padUDID],
        ])
        let devices = [device("iPhone", udid: phoneUDID), device("iPad", udid: padUDID)]
        #expect(Provisioning.devicesMissing(fromProfilesIn: app, devices: devices).map(\.name) == ["iPhone"])
    }

    @Test func anEmbeddedWatchAppsProfileIsNotChecked() throws {
        let directory = try TemporaryDirectory()
        let app = try makeApp(in: directory, profiles: ["": [phoneUDID], "Watch/Watch.app": []])
        #expect(Provisioning.devicesMissing(fromProfilesIn: app, devices: [device("iPhone", udid: phoneUDID)]).isEmpty)
    }

    @Test func devicesThatCannotBeCheckedAreNotReported() throws {
        let directory = try TemporaryDirectory()
        let app = try makeApp(in: directory, profiles: ["": []])
        let devices = [
            device("Old iPhone", udid: nil),
            device("Simulator", udid: "5E0C1E9C-0F0F-4F6B-9E0D-7D3B6C1A2B3C", kind: .simulator),
        ]
        #expect(Provisioning.devicesMissing(fromProfilesIn: app, devices: devices).isEmpty)
    }

    @Test func anAppWithoutReadableProfilesHasNoMissingDevices() throws {
        let directory = try TemporaryDirectory()
        try directory.makeDirectories("App.app")
        try directory.write("App.app/embedded.mobileprovision", "unreadable")
        let app = directory.url.appendingPathComponent("App.app")
        #expect(Provisioning.devicesMissing(fromProfilesIn: app, devices: [device("iPhone", udid: phoneUDID)]).isEmpty)
        let none = directory.url.appendingPathComponent("Missing.app")
        #expect(Provisioning.devicesMissing(fromProfilesIn: none, devices: [device("iPhone", udid: phoneUDID)]).isEmpty)
    }

    @Test func onlyAnXcodeManagedProfileCanBeRefreshed() throws {
        let phone = device("iPhone", udid: phoneUDID)
        func app(name: String, managed: Bool, devices: [String]) throws -> (TemporaryDirectory, URL) {
            let directory = try TemporaryDirectory()
            try directory.makeDirectories("App.app")
            let app = directory.url.appendingPathComponent("App.app")
            try profileData(name: name, devices: devices, managed: managed)
                .write(to: app.appendingPathComponent("embedded.mobileprovision"))
            return (directory, app)
        }
        let team = try app(name: "iOS Team Provisioning Profile: com.example.app", managed: false, devices: [padUDID])
        #expect(Provisioning.canRefreshProfiles(in: team.1, missing: [phone]))
        let managed = try app(name: "XC com example app", managed: true, devices: [padUDID])
        #expect(Provisioning.canRefreshProfiles(in: managed.1, missing: [phone]))
        let manual = try app(name: "Example Development", managed: false, devices: [padUDID])
        #expect(Provisioning.devicesMissing(fromProfilesIn: manual.1, devices: [phone]) == [phone])
        #expect(!Provisioning.canRefreshProfiles(in: manual.1, missing: [phone]))
        // A managed profile that lists the device isn't the one at fault.
        let covering = try app(name: "XC com example app", managed: true, devices: [phoneUDID])
        #expect(!Provisioning.canRefreshProfiles(in: covering.1, missing: [phone]))
    }

    @Test func messageNamesTheDevice() {
        #expect(Provisioning.unregisteredMessage(for: device("César's iPhone", udid: phoneUDID))
                == "César's iPhone isn't in the team's provisioning profile; register it in the developer account")
    }

    // MARK: Removing cached profiles

    @Test func removesOnlyXcodeManagedProfiles() throws {
        let directory = try TemporaryDirectory()
        func write(_ file: String, _ data: Data) throws {
            try data.write(to: directory.url.appendingPathComponent(file))
        }
        try write("team.mobileprovision", profileData(devices: [], managed: false))
        try write("wildcard.mobileprovision",
                  profileData(name: "iOS Team Provisioning Profile: *", devices: [], managed: true))
        try write("mac.provisionprofile",
                  profileData(name: "Mac Team Provisioning Profile: com.example.app", devices: [], managed: true))
        try write("manual.mobileprovision", profileData(name: "Example Development", devices: [], managed: false))
        try write("adhoc.mobileprovision", profileData(name: "Example Ad Hoc", devices: [], managed: false))
        try write("unreadable.mobileprovision", Data("unreadable".utf8))
        try write("managed.txt", profileData(devices: [], managed: true))

        #expect(Provisioning.removeXcodeManagedProfiles(in: directory.url) == 3)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted()
        #expect(left == ["adhoc.mobileprovision", "managed.txt", "manual.mobileprovision", "unreadable.mobileprovision"])
    }

    @Test func removingFromAMissingDirectoryDoesNothing() throws {
        let directory = try TemporaryDirectory()
        #expect(Provisioning.removeXcodeManagedProfiles(in: directory.url.appendingPathComponent("nope")) == 0)
    }
}
