// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orchard",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Orchard",
            path: "Sources/Orchard"
        ),
        .testTarget(
            name: "OrchardTests",
            dependencies: ["Orchard"],
            path: "Tests/OrchardTests"
        ),
    ]
)
