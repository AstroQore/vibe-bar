import Darwin
import Foundation

/// Resolves the user's real home directory.
///
/// Vibe Bar runs unsandboxed today (see AGENTS.md § 6), so every
/// Foundation "home" API returns `/Users/<you>` directly. This helper
/// is therefore functionally equivalent to `NSHomeDirectory()` in the
/// current build — but it is kept as the canonical entry point for
/// every real-home read so re-enabling the sandbox later (or porting
/// to a sandboxed fork) does not require auditing every credential
/// path again.
///
/// The implementation uses `getpwuid(getuid()).pw_dir`, which is the
/// only Foundation-adjacent API that returned the real home even in
/// the previous sandboxed builds. The empirical probe table that
/// justified the choice is preserved in AGENTS.md § 6.2 in case the
/// sandbox returns.
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
