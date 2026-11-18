import Foundation
import Testing
@testable import Orchard

struct XcodeTests {
    @Test func findsContainersWorkspacesFirstThenShallowest() throws {
        let repo = try TemporaryDirectory()
        try repo.makeDirectories(
            "App.xcodeproj/project.xcworkspace",
            "App.xcworkspace",
            "Modules/Feature/Feature.xcodeproj",
            "Pods/Pods.xcodeproj",
            ".build/checkouts/Dep/Dep.xcodeproj",
            "a/b/c/d/TooDeep.xcodeproj"
        )
        try repo.write("Package.swift", "")

        #expect(Xcode.findContainers(in: repo.url) == [
            "App.xcworkspace",
            "App.xcodeproj",
            "Modules/Feature/Feature.xcodeproj",
            "",
        ])
    }

    @Test func productsDirectoryFollowsXcodeLayout() {
        let derivedData = URL(fileURLWithPath: "/DD")
        #expect(Xcode.productsDirectory(derivedData: derivedData, configuration: "Debug", platform: .iOS).path
            == "/DD/Build/Products/Debug-iphoneos")
        #expect(Xcode.productsDirectory(derivedData: derivedData, configuration: "Beta", platform: .iOSSimulator).path
            == "/DD/Build/Products/Beta-iphonesimulator")
        #expect(Xcode.productsDirectory(derivedData: derivedData, configuration: "Debug", platform: .macOS).path
            == "/DD/Build/Products/Debug")
    }

    @Test func findsTheAppThisBuildSigned() throws {
        let buildStart = Date()
        let products = try TemporaryDirectory()
        #expect(Xcode.builtApp(in: products.url.appendingPathComponent("Missing"), signedSince: buildStart) == nil)

        try products.makeDirectories("Widget.appex", "Phone.app.dSYM")
        try app("Phone", bundleID: "com.example.phone", in: products, signedAt: Date())
        let phone = try #require(Xcode.builtApp(in: products.url, signedSince: buildStart))
        #expect(phone.appURL.lastPathComponent == "Phone.app")
        #expect(phone.bundleIdentifier == "com.example.phone")

        // Left over from an earlier scheme: not signed by this build, so ignored.
        try app("Old", bundleID: "com.example.old", in: products, signedAt: buildStart.addingTimeInterval(-3600))
        #expect(Xcode.builtApp(in: products.url, signedSince: buildStart)?.bundleIdentifier == "com.example.phone")

        // A no-op build re-signs nothing; two apps signed by one build are ambiguous.
        #expect(Xcode.builtApp(in: products.url, signedSince: Date().addingTimeInterval(60)) == nil)
        try app("Clip", bundleID: "com.example.clip", in: products, signedAt: Date())
        #expect(Xcode.builtApp(in: products.url, signedSince: buildStart) == nil)

        // The build now lands elsewhere (e.g. a custom CONFIGURATION_BUILD_DIR): the only app is stale.
        let stale = try TemporaryDirectory()
        try app("Phone", bundleID: "com.example.phone", in: stale, signedAt: buildStart.addingTimeInterval(-3600))
        #expect(Xcode.builtApp(in: stale.url, signedSince: buildStart) == nil)

        // Unsigned: can't tell it's fresh.
        let unsigned = try TemporaryDirectory()
        try unsigned.makeDirectories("Phone.app")
        try plist(["CFBundleIdentifier": "com.example.phone"], at: unsigned.url.appendingPathComponent("Phone.app/Info.plist"))
        #expect(Xcode.builtApp(in: unsigned.url, signedSince: buildStart) == nil)

        let mac = try TemporaryDirectory()
        try app("Mac", bundleID: "com.example.mac", in: mac, signedAt: Date(), contents: "Contents/")
        #expect(Xcode.builtApp(in: mac.url, signedSince: buildStart)?.bundleIdentifier == "com.example.mac")
    }

    /// A minimal signed bundle: Info.plist and _CodeSignature/CodeResources dated `signedAt`.
    private func app(_ name: String, bundleID: String, in directory: TemporaryDirectory, signedAt: Date,
                     contents: String = "") throws {
        let root = "\(name).app/\(contents)"
        try directory.makeDirectories(root + "_CodeSignature")
        try plist(["CFBundleIdentifier": bundleID], at: directory.url.appendingPathComponent(root + "Info.plist"))
        let resources = directory.url.appendingPathComponent(root + "_CodeSignature/CodeResources")
        try plist([:], at: resources)
        try FileManager.default.setAttributes([.modificationDate: signedAt], ofItemAtPath: resources.path)
    }

    private func plist(_ dictionary: [String: String], at url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: url)
    }

    @Test func supportedPlatformsComeFromTheSchemesApp() throws {
        let settings = #"""
        [
          {"target": "Widgets", "buildSettings": {"WRAPPER_EXTENSION": "appex", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"}},
          {"target": "Watch", "buildSettings": {"WRAPPER_EXTENSION": "app", "SUPPORTED_PLATFORMS": "watchos watchsimulator"}},
          {"target": "App", "buildSettings": {"WRAPPER_EXTENSION": "app", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx xros xrsimulator"}}
        ]
        """#
        let data = Data(settings.utf8)
        #expect(try Xcode.supportedPlatforms(inBuildSettings: data, scheme: "App") == [.iOS, .macOS, .visionOS])
        // No target named like the scheme: the first app.
        #expect(try Xcode.supportedPlatforms(inBuildSettings: data, scheme: "Other") == [.watchOS])
        #expect(try Xcode.supportedPlatforms(inBuildSettings: Data("[]".utf8), scheme: "App").isEmpty)
    }

    @Test func containerDisplayName() {
        #expect(Xcode.displayName(forContainer: nil) == "Package.swift")
        #expect(Xcode.displayName(forContainer: "") == "Package.swift")
        #expect(Xcode.displayName(forContainer: "App.xcodeproj") == "App.xcodeproj")
    }
}
