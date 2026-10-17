import Testing
@testable import Orchard

struct BuildPlatformTests {
    @Test(arguments: [
        ("iOS", false, BuildPlatform.iOS),
        ("iPadOS", false, .iOS),
        ("iOS", true, .iOSSimulator),
        ("tvOS", false, .tvOS),
        ("tvOS", true, .tvOSSimulator),
        ("watchOS", true, .watchOSSimulator),
        ("xrOS", false, .visionOS),
        ("visionOS", true, .visionOSSimulator),
        ("macOS", true, .macOS),
    ])
    func mapsDevicePlatforms(name: String, simulator: Bool, expected: BuildPlatform) {
        #expect(BuildPlatform(devicePlatform: name, simulator: simulator) == expected)
    }

    @Test func rejectsUnknownPlatforms() {
        #expect(BuildPlatform(devicePlatform: "bridgeOS", simulator: false) == nil)
    }

    @Test func genericDestinations() {
        #expect(BuildPlatform.macOS.genericDestination == "platform=macOS")
        #expect(BuildPlatform.iOS.genericDestination == "generic/platform=iOS")
        #expect(BuildPlatform.visionOSSimulator.genericDestination == "generic/platform=visionOS Simulator")
    }

    @Test func simulatorFlagMatchesName() {
        for platform in BuildPlatform.allCases {
            #expect(platform.isSimulator == platform.displayName.hasSuffix("Simulator"))
        }
    }

    @Test func platformNamesAreUnique() {
        let names = BuildPlatform.allCases.map(\.platformName)
        #expect(Set(names).count == names.count)
    }
}
