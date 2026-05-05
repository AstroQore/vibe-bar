// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VibeBar",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "VibeBar", targets: ["VibeBarApp"]),
        .library(name: "VibeBarCore", targets: ["VibeBarCore"])
    ],
    targets: [
        .executableTarget(
            name: "VibeBarApp",
            dependencies: ["VibeBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "VibeBarCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VibeBarCoreTests",
            dependencies: ["VibeBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
