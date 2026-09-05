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
        // Every user-facing string, shared with the cross-platform client.
        // Pinned exactly, like the kit: a catalogue tag reaches a user only
        // through a Vibe Bar build that carries it, and
        // `bump-vibe-bar-i18n.yml` opens the pull request that moves the pin.
        // `Package.resolved` is not committed, so the exact pin is what makes
        // two machines build the same strings.
        .package(url: "https://github.com/AstroQore/vibe-bar-i18n.git", exact: "0.5.0"),
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
                .product(name: "SweetCookieKit", package: "SweetCookieKit"),
                .product(name: "VibeBarLocalization", package: "vibe-bar-i18n")
            ],
            resources: [
                // `pricing.json` is the model rate table, shipped as a
                // bundle so rate updates can be merged without a code
                // change. `PricingResolver` loads it via `Bundle.module`
                // and a runtime cache under ~/.vibebar/pricing_cache.json
                // can override it when `PricingRefresher` fetches a newer
                // copy from the project's GitHub raw URL.
                //
                // The string catalogs are not here any more: they ship in
                // `vibe-bar-i18n`'s own resource bundle, which
                // `Scripts/build_app.sh` copies into the app.
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
