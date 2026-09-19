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
        // fff's C header, for ⌘L's transcript search. Declarations only: the
        // library is loaded at run time — see Sources/Rune/FFF.swift.
        .target(name: "CFFF", path: "Sources/CFFF"),
        .executableTarget(
            name: "Rune",
            dependencies: ["GhosttyKit", "CFFF"],
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
