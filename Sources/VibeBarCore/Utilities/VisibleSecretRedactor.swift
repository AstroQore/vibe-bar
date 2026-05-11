import Foundation

/// Redacts credential-shaped text before it can be persisted in quota caches
/// or rendered in SwiftUI. This is intentionally aimed at UI-facing strings,
/// not logs: model IDs and plan names should survive, while API keys, bearer
/// tokens, JWTs, and cookie values must never be shown back to the user.
public enum VisibleSecretRedactor {
    public static let placeholder = "<redacted>"

    private static let wholeValuePatterns: [String] = [
        #"(?i)\bsk-or-v1-[A-Za-z0-9._…-]{3,}\b"#,
        #"(?i)\bsk-(?:proj-|ant-|cp-)?[A-Za-z0-9._…-]{8,}\b"#,
        #"\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#
    ]

    private static let assignmentPattern =
        #"(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|bearer[_-]?token|auth[_-]?token|csrf[_-]?token|session[_-]?key|session[_-]?token|secret|password)\s*[:=]\s*([^;\s]+)"#

    private static let headerPatterns: [String] = [
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
        #"(?i)\b(Authorization|Cookie|Set-Cookie)\s*:\s*[^\n]+"#
    ]

    public static func redact(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        for pattern in headerPatterns + wholeValuePatterns {
            text = replacing(pattern, in: text, with: placeholder)
        }
        text = replacing(assignmentPattern, in: text, with: "$1=\(placeholder)")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func dropIfSensitive(_ raw: String?) -> String? {
        guard let cleaned = redact(raw) else { return nil }
        if looksSensitive(raw) { return nil }
        return cleaned
    }

    public static func looksSensitive(_ raw: String?) -> Bool {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return redact(raw) != raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
