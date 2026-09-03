import Foundation

/// Redacts a diagnostic string that may have come from a provider's own
/// response before it leaves this machine.
///
/// `QuotaError`'s payloads are a mix of two things: copy Vibe Bar wrote
/// ("This account has no Coding Plan subscription…") and text lifted
/// verbatim out of a provider response — `WarpResponseParser` builds a
/// `.parseFailure` straight from GraphQL `errors[].message`, and half a
/// dozen adapters interpolate a BFF's `Message` field into `.network`.
/// Nothing stops such a message from carrying the account's email, a
/// session id, or a token fragment, and the error text reaches two sinks
/// that leave the app: a public `os_log` line and the MCP projection an
/// agent reads.
///
/// This is deliberately gentler than `SafeLog.sanitize`, which masks any
/// run of 20+ `[A-Za-z0-9_-.]` characters and therefore eats ordinary
/// hostnames — `console.volcengine.com` becomes `***`, which is exactly
/// the actionable half of the message an agent needs. Here the dot is not
/// part of the token class, so dotted hostnames survive intact while an
/// opaque 20+ character blob (a JWT segment, an API key, an account id)
/// still gets masked, and addresses go through `EmailMasker` first.
public enum ProviderDiagnosticRedactor {
    public static let defaultMaxLength = 300

    /// Mask addresses and opaque identifiers, collapse whitespace, and cap
    /// the length so one provider's stack trace cannot flood a log line or
    /// an agent's context window.
    public static func redact(_ raw: String, maxLength: Int = defaultMaxLength) -> String {
        var text = raw.replacingOccurrences(of: "\n", with: " ")
        text = maskEmails(in: text)
        text = maskOpaqueRuns(in: text)
        text = text
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncate(text, maxLength: maxLength)
    }

    /// Run every address in `text` through `EmailMasker`.
    ///
    /// Exposed because `SafeLog.sanitize` on its own does not catch one:
    /// the `@` splits an address into two runs that are each well under
    /// its 20-character threshold, so `user@example.com` sails through
    /// untouched. Anything logging a provider diagnostic wants both.
    public static func maskEmails(in text: String) -> String {
        guard let regex = emailRegex else { return text }
        let full = NSRange(text.startIndex..., in: text)
        var result = text
        // Replace back-to-front so earlier ranges stay valid.
        for match in regex.matches(in: text, options: [], range: full).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let masked = EmailMasker.mask(String(text[range]))
            result.replaceSubrange(
                Range(match.range, in: result) ?? range,
                with: masked
            )
        }
        return result
    }

    private static func maskOpaqueRuns(in text: String) -> String {
        guard let regex = opaqueRunRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: "***"
        )
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 0, text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }

    private static let emailRegex = try? NSRegularExpression(
        pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
    )

    /// No dot in the character class — that is what keeps
    /// `console.volcengine.com` readable while a JWT segment or an API key
    /// is still masked.
    private static let opaqueRunRegex = try? NSRegularExpression(
        pattern: "[A-Za-z0-9_\\-]{20,}"
    )
}
