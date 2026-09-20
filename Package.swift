// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TrackingInspector",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TrackingInspector", targets: ["TrackingInspector"])],
    targets: [
        .target(name: "InspectorCore"),
        .executableTarget(name: "TrackingInspector", dependencies: ["InspectorCore"], resources: [.copy("Web")]),
        .testTarget(name: "InspectorCoreTests", dependencies: ["InspectorCore"]),
    ]
)
