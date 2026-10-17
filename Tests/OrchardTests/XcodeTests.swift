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

    @Test func containerDisplayName() {
        #expect(Xcode.displayName(forContainer: nil) == "Package.swift")
        #expect(Xcode.displayName(forContainer: "") == "Package.swift")
        #expect(Xcode.displayName(forContainer: "App.xcodeproj") == "App.xcodeproj")
    }
}
