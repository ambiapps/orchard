import Foundation

/// Checks that a built app's provisioning profiles list the devices it's about to be installed on.
///
/// Device builds use a generic destination, so xcodebuild signs with whatever Xcode-managed
/// profile it has cached, even one created before a device was registered. Installing on that
/// device then fails with `ApplicationVerificationFailed` (0xE8008012).
enum Provisioning {
    struct Profile: Equatable, Sendable {
        var name: String
        var isXcodeManaged: Bool
        var provisionsAllDevices: Bool
        /// Uppercased hardware UDIDs.
        var devices: Set<String>

        func covers(udid: String) -> Bool {
            provisionsAllDevices || devices.contains(udid.uppercased())
        }

        /// A profile Xcode made and will make again when it's gone.
        var isCachedByXcode: Bool {
            isXcodeManaged || name.hasPrefix("iOS Team Provisioning Profile")
        }
    }

    /// Where Xcode 16+ keeps the profiles it downloads.
    static let xcodeProfiles = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true)

    /// Reads a `.mobileprovision` / `.provisionprofile`: a CMS signature wrapped around an XML
    /// plist, which is in there as plain text.
    static func profile(from data: Data) -> Profile? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        let devices = plist["ProvisionedDevices"] as? [String] ?? []
        return Profile(
            name: plist["Name"] as? String ?? "",
            isXcodeManaged: plist["IsXcodeManaged"] as? Bool ?? false,
            provisionsAllDevices: plist["ProvisionsAllDevices"] as? Bool ?? false,
            devices: Set(devices.map { $0.uppercased() }))
    }

    static func profile(at url: URL) -> Profile? {
        (try? Data(contentsOf: url)).flatMap(profile(from:))
    }

    /// Every `embedded.mobileprovision` in `app`: its own and each extension's and app clip's.
    /// An embedded watch app is left out, because it's installed on a watch, not on the device
    /// the build is for.
    static func embeddedProfiles(in app: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "Watch" {
                enumerator.skipDescendants()
            } else if url.lastPathComponent == "embedded.mobileprovision" {
                found.append(url)
            }
        }
        return found
    }

    /// The physical devices among `devices` that at least one of `app`'s profiles doesn't list.
    /// Devices without a known UDID and profiles that can't be read are skipped, since there's
    /// nothing to compare.
    static func devicesMissing(fromProfilesIn app: URL, devices: [Device]) -> [Device] {
        let profiles = embeddedProfiles(in: app).compactMap(profile(at:))
        return devices.filter { device in
            guard device.kind == .physical, let udid = device.udid else { return false }
            return profiles.contains { !$0.covers(udid: udid) }
        }
    }

    /// Whether a profile in `app` that lacks one of `devices` is one Xcode manages, so deleting
    /// the cached copy and building again can produce a current one. A hand-made profile can't
    /// be refreshed that way.
    static func canRefreshProfiles(in app: URL, missing devices: [Device]) -> Bool {
        let udids = devices.compactMap(\.udid)
        return embeddedProfiles(in: app).compactMap(profile(at:)).contains { profile in
            profile.isCachedByXcode && udids.contains { !profile.covers(udid: $0) }
        }
    }

    /// Deletes the profiles Xcode manages from `directory`, so the next build with
    /// `-allowProvisioningUpdates` downloads current ones. Profiles the developer made by hand
    /// stay. Returns how many were deleted.
    @discardableResult
    static func removeXcodeManagedProfiles(in directory: URL = xcodeProfiles) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for file in files where ["mobileprovision", "provisionprofile"].contains(file.pathExtension) {
            guard profile(at: file)?.isCachedByXcode == true,
                  (try? FileManager.default.removeItem(at: file)) != nil else { continue }
            removed += 1
        }
        return removed
    }

    static func unregisteredMessage(for device: Device) -> String {
        "\(device.name) isn't in the team's provisioning profile; register it in the developer account"
    }
}
