// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskPulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeskPulse", targets: ["DeskPulse"])
    ],
    targets: [
        .executableTarget(
            name: "DeskPulse",
            path: "Sources/DeskPulse",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DeskPulseTests",
            dependencies: ["DeskPulse"],
            path: "Tests/DeskPulseTests"
        )
    ]
)
