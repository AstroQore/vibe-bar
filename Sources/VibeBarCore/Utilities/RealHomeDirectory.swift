import AgentSessionKit
import Foundation

/// Vibe Bar's single entry point for the user's home directory.
///
/// This deliberately shadows `AgentSessionKit.RealHomeDirectory`: inside
/// `VibeBarCore` the module-local declaration wins, and `VibeBarApp` sees
/// this one through the `@_exported import` in `AgentSessionKitReexport`.
/// Every `~/.codex/`, `~/.claude/`, `~/.vibebar/` path in the app therefore
/// resolves through here — which is the invariant `AGENTS.md` § 6 asks
/// for — and the one thing this adds on top of the kit's helper is a
/// process-wide override.
///
/// The override exists for exactly one caller: `DemoMode`, which points the
/// whole app at a synthetic home so README screenshots can be taken from a
/// store that contains no real credentials, paths, or session text. It is
/// set once, before any store is touched, and never changes afterwards;
/// outside demo mode `path` is the kit's answer, byte for byte.
public enum RealHomeDirectory {
    /// Written once by `DemoMode.bootstrap` on the main thread before a
    /// single store is opened, then only read. Plain storage is enough for
    /// that lifecycle, and a lock would put a mutex on every path lookup.
    nonisolated(unsafe) private static var overridePath: String?

    public static var path: String {
        overridePath ?? AgentSessionKit.RealHomeDirectory.path
    }

    public static var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The home the kit would report without any override — the account's
    /// actual `/Users/<name>`. `DemoMode` compares against it so a demo home
    /// can never silently be the real one.
    public static var systemPath: String {
        AgentSessionKit.RealHomeDirectory.path
    }

    /// `DemoMode` only. Not public: a redirected home is a launch-time
    /// decision, not something a feature toggles at runtime.
    static func setOverride(_ path: String?) {
        overridePath = path
    }
}
