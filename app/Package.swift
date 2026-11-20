// swift-tools-version:6.0
// Quicksand.app — status-bar app that runs the host-side brokers for every
// sandbox. See docs/quicksand-app.md. Build: `swift build` (or
// scripts/bundle.sh for a .app); test: `swift test`.
import PackageDescription

let package = Package(
    name: "Quicksand",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Quicksand", targets: ["Quicksand"]),
        .library(name: "QuicksandCore", targets: ["QuicksandCore"]),
    ],
    targets: [
        // Everything that decides or parses: caller identity, broker specs,
        // spawning, sandbox status, the event log. No UI; unit-tested.
        .target(
            name: "QuicksandCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The status-bar app: SwiftUI views over QuicksandCore.
        .executableTarget(
            name: "Quicksand",
            dependencies: ["QuicksandCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QuicksandCoreTests",
            dependencies: ["QuicksandCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
