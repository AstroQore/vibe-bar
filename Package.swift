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
        // SweetCookieKit encapsulates the Chromium SQLite parsing, "Chrome
        // Safe Storage" Keychain decryption, and Safari binarycookies /
        // Firefox SQLite reads that the misc-providers feature needs.
        .package(url: "https://github.com/steipete/SweetCookieKit", from: "0.4.0"),
        // Sparkle is the standard update framework for independently
        // distributed macOS applications. Pin the exact reviewed release:
        // update verification and installation are security-sensitive.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "VibeBarApp",
            dependencies: [
                "VibeBarCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../Frameworks"
                ])
            ]
        ),
        .target(
            name: "VibeBarCore",
            dependencies: [
                .product(name: "SweetCookieKit", package: "SweetCookieKit")
            ],
            resources: [
                // Pricing tables: shipped as a bundled JSON so model
                // rate updates can be merged without a code change.
                // `PricingResolver` loads this via `Bundle.module` and
                // a runtime cache under ~/.vibebar/pricing_cache.json
                // can override it when `PricingRefresher` fetches a
                // newer copy from the project's GitHub raw URL.
                .copy("Resources/pricing.json")
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
