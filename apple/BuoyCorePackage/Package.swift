// swift-tools-version: 5.9
//
// BuoyCore — local Swift Package exposing the Rust core to the iOS and
// macOS apps. The xcframework and the generated Swift bindings are written
// into this package directory by `just build-xcframework`; they are NOT
// committed to git (see .gitignore).
//
// To consume from the Xcode project:
//   File -> Add Package Dependencies -> Add Local…
//   Point at apple/BuoyCorePackage and add it to the Buoy target.

import PackageDescription

let package = Package(
    name: "BuoyCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BuoyCore", targets: ["BuoyCore"]),
    ],
    targets: [
        .binaryTarget(
            name: "BuoyCoreFFI",
            path: "Artifacts/BuoyCore.xcframework"
        ),
        .target(
            name: "BuoyCore",
            dependencies: ["BuoyCoreFFI"],
            path: "Sources/BuoyCore",
            linkerSettings: [
                // The Rust core's candle backend uses Accelerate for its
                // matrix math on Apple platforms.
                .linkedFramework("Accelerate")
            ]
        ),
    ]
)
