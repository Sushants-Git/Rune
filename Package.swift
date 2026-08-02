// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rune",
    platforms: [.macOS(.v13)],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/ghostty/macos/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "Rune",
            dependencies: ["GhosttyKit"],
            path: "Sources/Rune",
            linkerSettings: [
                // libghostty statically bundles C++ dependencies (glslang,
                // oniguruma, harfbuzz and friends) and expects the host to
                // provide the platform frameworks it renders and speaks to.
                .linkedLibrary("c++"),
                // opencode keeps its sessions in a SQLite database; see
                // OpenCodeStore in AgentSession.swift.
                .linkedLibrary("sqlite3"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Cocoa"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Carbon"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
