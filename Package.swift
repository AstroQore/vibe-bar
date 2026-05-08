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
    dependencies: [
        // First and currently only external dependency. SweetCookieKit
        // encapsulates the Chromium SQLite parsing, "Chrome Safe Storage"
        // Keychain decryption, and Safari binarycookies / Firefox SQLite
        // reads that the misc-providers feature needs. Adding it
        // permanently ends vibe-bar's zero-deps invariant — see AGENTS.md
        // § 6 for the trade-off, and prefer porting code into Vibe Bar
        // before adding a second dep.
        .package(url: "https://github.com/steipete/SweetCookieKit", from: "0.4.0")
    ],
    targets: [
        .executableTarget(
            name: "VibeBarApp",
            dependencies: ["VibeBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "VibeBarCore",
            dependencies: [
                .product(name: "SweetCookieKit", package: "SweetCookieKit")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VibeBarCoreTests",
            dependencies: ["VibeBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
