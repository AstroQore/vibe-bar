import Foundation
import os.log

/// SafeLog wraps os_log with the explicit invariant that NO sensitive material
/// (access tokens, raw credentials, Authorization headers, refresh tokens) ever
/// passes through. Always call with already-redacted values.
public enum SafeLog {
    public static let subsystem = "com.astroqore.VibeBar"

    private static let general = Logger(subsystem: subsystem, category: "general")
    private static let network = Logger(subsystem: subsystem, category: "network")
    private static let credentials = Logger(subsystem: subsystem, category: "credentials")

    public static func info(_ message: String) {
        general.info("\(message, privacy: .public)")
    }

    public static func warn(_ message: String) {
        general.warning("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        general.error("\(message, privacy: .public)")
    }

    public static func net(_ message: String) {
        network.info("\(message, privacy: .public)")
    }

    public static func credentialEvent(_ message: String) {
        // Always private, even though we already redact. Defense in depth.
        credentials.info("\(message, privacy: .private)")
    }

    /// Sanitizes an arbitrary string for log inclusion: collapses whitespace,
    /// replaces any token-shaped sequences (>= 20 alphanumeric/-./_ chars) with "***".
    public static func sanitize(_ raw: String) -> String {
        let collapsed = raw.replacingOccurrences(of: "\n", with: " ")
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9_\\-\\.]{20,}") else {
            return collapsed
        }
        let range = NSRange(collapsed.startIndex..., in: collapsed)
        return regex.stringByReplacingMatches(in: collapsed, options: [], range: range, withTemplate: "***")
    }
}
