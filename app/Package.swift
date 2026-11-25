// swift-tools-version:6.0
// Quicksand.app — status-bar app that runs the host-side brokers for every
// sandbox — and the qs command, which ships inside it. See docs/quicksand-app.md. Build: `swift build` (or
// scripts/bundle.sh for a .app); test: `swift test`.
import PackageDescription

let package = Package(
    name: "Quicksand",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Quicksand", targets: ["Quicksand"]),
        .executable(name: "qs-event", targets: ["qs-event"]),
        .executable(name: "qs", targets: ["qs"]),
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
        // What the bash brokers call to log a request; ships inside the app.
        .executableTarget(
            name: "qs-event",
            dependencies: ["QuicksandCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The qs command: for now hands every command to the bash qs
        // (qs.bash); ships inside the app as Contents/MacOS/qs.
        .executableTarget(
            name: "qs",
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
