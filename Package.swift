// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VibeBar",
    // Every localized resource in the package hangs off this: it is the
    // language `.lproj`-less resources are considered to be in, and the
    // one `L10n` falls back to when a key is missing from a translation.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "VibeBar", targets: ["VibeBarApp"]),
        .library(name: "VibeBarCore", targets: ["VibeBarCore"])
    ],
    dependencies: [
        // agent-session-kit owns the session stores the coding agents leave
        // on disk — discovery, parsing, the FTS5 index, deletion planning —
        // plus the local MCP Unix-socket / stdio transport. It was extracted
        // from this repository, so the types are the ones Vibe Bar used to
        // declare itself; `Compat/AgentSessionKitReexport.swift` re-exports
        // them and keeps the host-shaped defaults.
        // Pinned to an exact tag on purpose: a release build resolves this
        // from a clean checkout with no Package.resolved (it is gitignored),
        // so the pin is the only thing that makes two builds of the same
        // Vibe Bar commit contain the same package. Bump it deliberately.
        .package(url: "https://github.com/AstroQore/agent-session-kit.git", exact: "0.7.0"),
        // SweetCookieKit encapsulates Chromium cookie + localStorage parsing,
        // "Chrome Safe Storage" Keychain decryption, and Safari
        // binarycookies / Firefox SQLite reads used by misc providers.
        .package(url: "https://github.com/steipete/SweetCookieKit", exact: "0.5.2"),
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
                .product(name: "AgentSessionKit", package: "agent-session-kit"),
                .product(name: "SweetCookieKit", package: "SweetCookieKit")
            ],
            resources: [
                // Two kinds of resource share this directory.
                //
                // `pricing.json` is the model rate table, shipped as a
                // bundle so rate updates can be merged without a code
                // change. `PricingResolver` loads it via `Bundle.module`
                // and a runtime cache under ~/.vibebar/pricing_cache.json
                // can override it when `PricingRefresher` fetches a newer
                // copy from the project's GitHub raw URL.
                //
                // `<lang>.lproj/Localizable.{strings,stringsdict}` are the
                // compiled string catalogs `L10n` reads. They are generated
                // from `Resources/i18n/*.json` by
                // `Scripts/build_localizations.py` and checked in, so a
                // clean machine builds Vibe Bar without Python; a test
                // regenerates them and fails on a diff. `.process` is what
                // makes SwiftPM keep them under their `.lproj` in the
                // bundle — Core is where they live because it is the only
                // target with a bundle of its own, and both targets resolve
                // strings through Core's `L10n`.
                .process("Resources")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VibeBarCoreTests",
            dependencies: ["VibeBarCore"],
            resources: [
                .copy("Fixtures/RemoteSync")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
