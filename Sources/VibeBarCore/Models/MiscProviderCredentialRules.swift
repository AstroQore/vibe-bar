import Foundation

/// Shape checks for the credentials a user types into a misc-provider row.
///
/// These exist because the Settings fields used to accept any non-empty
/// string and immediately show a green "saved" state — so pasting an Ark
/// inference key into Volcengine's Agent Plan Access Key field looked like
/// success, and the mistake only surfaced later as an opaque quota error on
/// a different screen.
///
/// The rules are deliberately two-tier:
///
/// - `.rejected` is reserved for a value we can positively identify as a
///   *different* credential the same vendor issues. Those are the mistakes
///   worth blocking, and the message can name both credentials.
/// - `.warning` covers "this does not look like the documented prefix".
///   Vendors rotate key formats without telling anyone, so an unrecognised
///   shape must never stop a user who knows better — the value is saved and
///   the row explains what Vibe Bar expected.
///
/// Everything here is pure string inspection on a value the user just
/// typed. Nothing is logged, stored, or echoed back into a message.
public enum MiscCredentialFieldRules {
    public enum Verdict: Equatable, Sendable {
        case accepted
        /// Saved, with a caveat shown under the field.
        case warning(String)
        /// Not saved. The message says which credential this looks like
        /// and which one the field wants.
        case rejected(String)

        public var allowsSave: Bool {
            if case .rejected = self { return false }
            return true
        }

        public var message: String? {
            switch self {
            case .accepted:            return nil
            case .warning(let text):   return text
            case .rejected(let text):  return text
            }
        }
    }

    /// Check one field's value. `value` is expected to be pre-trimmed.
    public static func check(
        tool: ToolType,
        kind: MiscCredentialStore.Kind,
        value: String
    ) -> Verdict {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .accepted }

        switch (tool, kind) {
        case (.volcengineAgentPlan, .accessKeyID):
            if trimmed.lowercased().hasPrefix("sk-") {
                return .rejected(
                    "That looks like an Ark inference key (sk-…). Agent Plan needs an Access Key ID, which starts with AKLT — create one in the Volcengine console under Access Control (访问控制) → API Access Key."
                )
            }
            if !trimmed.hasPrefix("AKLT") {
                return .warning(
                    "Volcengine Access Key IDs normally start with AKLT. Saved anyway — if the card reports a rejected key, copy the Access Key ID from Access Control (访问控制) → API Access Key."
                )
            }
            return .accepted

        case (.warp, .apiKey):
            if !trimmed.hasPrefix("wk-") {
                return .warning(
                    "Warp API keys normally start with wk-. Saved anyway — mint one in Warp → Settings → AI → API Keys if the card reports a rejected key."
                )
            }
            return .accepted

        case (.openRouter, .apiKey):
            if !trimmed.hasPrefix("sk-or-") {
                return .warning(
                    "OpenRouter keys normally start with sk-or-v1-. Saved anyway — create one at openrouter.ai → Keys if the card reports a rejected key."
                )
            }
            return .accepted

        case (.minimax, .apiKey):
            if !trimmed.hasPrefix("sk-cp-") {
                return .warning(
                    "The Token Plan key from Billing → Token Plan starts with sk-cp-. Saved anyway — a general MiniMax platform key can authenticate but report no Token Plan quota."
                )
            }
            return .accepted

        case (.zai, .apiKey):
            // z.ai issues `zai-…`; open.bigmodel.cn issues `<id>.<secret>`.
            // Accept either shape, warn on anything else.
            if !trimmed.hasPrefix("zai-") && !trimmed.contains(".") {
                return .warning(
                    "Z.ai keys from z.ai → API Keys start with zai-; open.bigmodel.cn keys look like id.secret. Saved anyway — check the Region picker if the card reports a rejected key."
                )
            }
            return .accepted

        default:
            return .accepted
        }
    }
}

/// Which cookie a hand-pasted header has to carry before the provider's
/// adapter can do anything with it.
///
/// Providers whose `MiscCookieResolver.Spec.requiredNames` is empty ship
/// the whole jar, so the paste field could not reject anything and a header
/// missing the one cookie that matters was stored, marked "saved", and only
/// failed at the next refresh. These are the sentinels each adapter
/// actually reads out of the header.
///
/// Only providers with a *hard* sentinel are listed. Alibaba, Baidu
/// Qianfan, and iFlytek stitch identity out of HttpOnly tickets we cannot
/// enumerate and have no single load-bearing cookie name, so their pastes
/// stay unvalidated rather than risk rejecting a working header.
public enum MiscManualCookieRules {
    /// Cookie names that must all be present, in the order a message
    /// should list them. Empty means "no sentinel is known".
    public static func requiredCookieNames(for tool: ToolType) -> [String] {
        switch tool {
        case .volcengine:
            return ["csrfToken"]
        case .tencentHunyuan, .tencentTokenPlan:
            return ["skey", "uin"]
        default:
            return []
        }
    }

    /// `nil` when the header is usable; otherwise the message to show
    /// instead of saving it.
    public static func rejectionMessage(for tool: ToolType, header: String) -> String? {
        let names = Set(CookieHeaderNormalizer.pairs(from: header)
            .filter { !$0.value.isEmpty }
            .map(\.name))

        let missing = requiredCookieNames(for: tool).filter { !names.contains($0) }
        if !missing.isEmpty {
            return message(tool: tool, missing: missing)
        }

        if tool == .ollama, !OllamaQuotaAdapter.hasRecognizedSessionCookie(header) {
            return "No Ollama session cookie found in the pasted text. Copy the ollama.com Cookie header while signed in — it must include session (or next-auth.session-token)."
        }
        return nil
    }

    private static func message(tool: ToolType, missing: [String]) -> String {
        let list = missing.joined(separator: " and ")
        switch tool {
        case .volcengine:
            return "No \(list) cookie found in the pasted text. csrfToken is only set after you open the Ark console (console.volcengine.com/ark) once — open it, then copy the Cookie header again."
        case .tencentHunyuan, .tencentTokenPlan:
            return "No \(list) cookie found in the pasted text. Both are set by the Tencent Cloud console — open console.cloud.tencent.com once, then copy the Cookie header again."
        default:
            return "No \(list) cookie found in the pasted text."
        }
    }
}
