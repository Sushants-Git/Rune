// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kterm",
    platforms: [.macOS(.v13)],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/ghostty/macos/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "kterm",
            dependencies: ["GhosttyKit"],
            path: "Sources/kterm"
        ),
    ]
)
