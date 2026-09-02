import Foundation

/// Demo mode: the real app, pointed at a synthetic home.
///
/// Every screenshot in the README is taken from a Vibe Bar that was launched
/// this way. Instead of faking views, demo mode redirects
/// `RealHomeDirectory` to a directory built by `Scripts/demo_home.py` — a
/// copy of one maintainer's quota, cost, forecast and ledger state with the
/// identifying parts replaced, plus fabricated agent sessions and a library of
/// public skills — and then turns off everything that would reach past that
/// directory: no provider refresh, no status polling, no pricing fetch, no
/// update check, no Relay sync, no Keychain, no MCP socket, no login item.
/// What remains is exactly the code path a user sees, rendering data that
/// belongs to nobody.
///
/// Enabled by `VIBEBAR_DEMO_HOME=<dir>` (or `--demo-home <dir>`). Optional:
///
/// - `VIBEBAR_DEMO_APPEARANCE=light|dark` — pin the appearance for the
///   process, so the same surface can be captured in both.
/// - `VIBEBAR_DEMO_SURFACE=<surface>` — open one surface after launch:
///   `popover:<page>`, `mini:<regular|compact>`, `workbench:<page>`,
///   `settings:<section>`, `onboarding:<step>`, where the identifiers are
///   the app's own raw values (`overview`, `openAI`, `usageStats`, `layout`,
///   `subscriptions`, …).
/// - `VIBEBAR_DEMO_BACKDROP=0` — skip the solid backdrop window demo mode
///   otherwise puts behind the popover so a translucent surface is captured
///   over one flat colour rather than over whatever happens to be on screen.
///
/// `bootstrap` must run before the first store is opened — `main.swift`
/// calls it before AppKit exists — and it refuses a demo home that is the
/// account's real home, so a typo can never put the real store into a mode
/// that disables its refreshes.
public enum DemoMode {
    public enum Appearance: String, Sendable {
        case light
        case dark
    }

    public enum Surface: Sendable, Equatable {
        case popover(page: String)
        case miniWindow(mode: String)
        case workbench(page: String)
        case settings(section: String)
        /// The first-run setup assistant, opened on the named step.
        case onboarding(step: String)

        /// `kind:identifier`. An unknown kind is `nil`; an empty identifier
        /// is allowed and means "the surface's default".
        public init?(parsing raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else {
                switch trimmed {
                case "popover": self = .popover(page: "")
                case "mini": self = .miniWindow(mode: "")
                case "workbench": self = .workbench(page: "")
                case "settings": self = .settings(section: "")
                case "onboarding": self = .onboarding(step: "")
                default: return nil
                }
                return
            }
            let kind = trimmed[..<colon]
            let identifier = String(trimmed[trimmed.index(after: colon)...])
            switch kind {
            case "popover": self = .popover(page: identifier)
            case "mini": self = .miniWindow(mode: identifier)
            case "workbench": self = .workbench(page: identifier)
            case "settings": self = .settings(section: identifier)
            case "onboarding": self = .onboarding(step: identifier)
            default: return nil
            }
        }
    }

    public struct Configuration: Sendable, Equatable {
        public var homeDirectory: String
        public var appearance: Appearance?
        public var surface: Surface?
        public var showsBackdrop: Bool

        public init(
            homeDirectory: String,
            appearance: Appearance? = nil,
            surface: Surface? = nil,
            showsBackdrop: Bool = true
        ) {
            self.homeDirectory = homeDirectory
            self.appearance = appearance
            self.surface = surface
            self.showsBackdrop = showsBackdrop
        }
    }

    public enum BootstrapError: Error, Equatable, CustomStringConvertible {
        case missingArgument
        case notADirectory(String)
        case isRealHome(String)

        public var description: String {
            switch self {
            case .missingArgument:
                "--demo-home needs a directory argument"
            case let .notADirectory(path):
                "demo home is not a directory: \(path)"
            case let .isRealHome(path):
                "refusing to use the real home directory as the demo home: \(path)"
            }
        }
    }

    public static let homeEnvironmentKey = "VIBEBAR_DEMO_HOME"
    public static let appearanceEnvironmentKey = "VIBEBAR_DEMO_APPEARANCE"
    public static let surfaceEnvironmentKey = "VIBEBAR_DEMO_SURFACE"
    public static let backdropEnvironmentKey = "VIBEBAR_DEMO_BACKDROP"
    public static let homeArgument = "--demo-home"

    /// Same lifecycle as `RealHomeDirectory`'s override: written once at
    /// launch, read for the rest of the process.
    nonisolated(unsafe) public private(set) static var configuration: Configuration?

    public static var isEnabled: Bool { configuration != nil }

    /// Parses the process environment and arguments, and on success redirects
    /// `RealHomeDirectory`. Returns `nil` when demo mode was not requested.
    @discardableResult
    public static func bootstrap(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws -> Configuration? {
        guard let configuration = try parse(environment: environment, arguments: arguments) else {
            return nil
        }
        RealHomeDirectory.setOverride(configuration.homeDirectory)
        Self.configuration = configuration
        return configuration
    }

    /// Pure parse, so tests can exercise every branch without touching the
    /// process-wide override.
    public static func parse(
        environment: [String: String],
        arguments: [String],
        systemHome: String = RealHomeDirectory.systemPath,
        fileManager: FileManager = .default
    ) throws -> Configuration? {
        var requestedHome: String?
        if let index = arguments.firstIndex(of: homeArgument) {
            guard arguments.indices.contains(index + 1) else {
                throw BootstrapError.missingArgument
            }
            requestedHome = arguments[index + 1]
        } else if let fromEnvironment = environment[homeEnvironmentKey], !fromEnvironment.isEmpty {
            requestedHome = fromEnvironment
        }
        guard let requestedHome else { return nil }

        let home = URL(fileURLWithPath: requestedHome, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: home, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BootstrapError.notADirectory(home)
        }
        let realHome = URL(fileURLWithPath: systemHome, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard home != realHome else {
            throw BootstrapError.isRealHome(home)
        }

        let appearance = environment[appearanceEnvironmentKey]
            .flatMap { Appearance(rawValue: $0.lowercased()) }
        let surface = environment[surfaceEnvironmentKey].flatMap(Surface.init(parsing:))
        let backdrop: Bool
        switch environment[backdropEnvironmentKey]?.lowercased() {
        case "0", "false", "no", "off": backdrop = false
        default: backdrop = true
        }
        return Configuration(
            homeDirectory: home,
            appearance: appearance,
            surface: surface,
            showsBackdrop: backdrop
        )
    }
}
