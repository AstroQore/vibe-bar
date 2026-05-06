import Darwin
import Foundation

/// Resolves the *real* user home directory, even when the app is sandboxed.
///
/// Inside the macOS app sandbox, every Foundation "home" API returns the
/// container path (`~/Library/Containers/<bundle-id>/Data`):
/// `NSHomeDirectory()`, `FileManager.default.homeDirectoryForCurrentUser`,
/// and — despite Apple's docs implying otherwise — `NSHomeDirectoryForUser`.
/// The `HOME` environment variable is also rewritten to the container.
/// Only `getpwuid(getuid()).pw_dir` is left untouched, because passwd
/// lookups go through an XPC service that does not honor the sandbox
/// home redirect.
///
/// The temp-exception `home-relative-path` entitlements in
/// `Resources/VibeBar.entitlements` grant *permission* to read/write
/// real-home subpaths like `~/.codex/`, `~/.claude/`, `~/.config/claude/`,
/// and `~/.vibebar/`. They do not redirect path resolution — the code
/// has to pass the real absolute path to Foundation. This helper is the
/// single place that knows how.
///
/// See AGENTS.md → "Sandbox & home directory" for the full rule and the
/// diagnostic for spotting the regression.
public enum RealHomeDirectory {
    public static var path: String {
        if let pw = getpwuid(getuid()) {
            let dir = String(cString: pw.pointee.pw_dir)
            if !dir.isEmpty { return dir }
        }
        return NSHomeDirectory()
    }

    public static var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}
