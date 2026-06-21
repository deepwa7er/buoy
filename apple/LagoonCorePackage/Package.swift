// swift-tools-version: 5.9
//
// LagoonCore — local Swift Package exposing the Rust core to the iOS and
// macOS apps. The xcframework and the generated Swift bindings are written
// into this package directory by `just build-xcframework`; they are NOT
// committed to git (see .gitignore).
//
// To consume from the Xcode project:
//   File -> Add Package Dependencies -> Add Local…
//   Point at apple/LagoonCorePackage and add it to the Lagoon target.

import PackageDescription

let package = Package(
    name: "LagoonCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LagoonCore", targets: ["LagoonCore"]),
    ],
    targets: [
        .binaryTarget(
            name: "LagoonCoreFFI",
            path: "Artifacts/LagoonCore.xcframework"
        ),
        .target(
            name: "LagoonCore",
            dependencies: ["LagoonCoreFFI"],
            path: "Sources/LagoonCore",
            linkerSettings: [
                // The Rust core's candle backend uses Accelerate for its
                // matrix math on Apple platforms.
                .linkedFramework("Accelerate")
            ]
        ),
    ]
)
