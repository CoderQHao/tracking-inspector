// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "InspectorCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "InspectorCore", targets: ["InspectorCore"])],
    targets: [
        .target(name: "InspectorCore"),
        .testTarget(name: "InspectorCoreTests", dependencies: ["InspectorCore"]),
    ]
)
