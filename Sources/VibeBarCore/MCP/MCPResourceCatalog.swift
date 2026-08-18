import Foundation

/// One resource as `resources/list` renders it.
public struct MCPResource: Sendable, Equatable {
    public let uri: String
    public let name: String
    public let title: String
    public let description: String
    public let mimeType: String

    public init(uri: String, name: String, title: String, description: String, mimeType: String) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
    }

    var json: MCPJSON {
        .object([
            "uri": .string(uri),
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "mimeType": .string(mimeType)
        ])
    }
}

/// The two documents the server hands out: the naming spec an agent has to
/// read before it can phrase an answer correctly, and a short guide to which
/// tool answers what.
///
/// The naming spec is **generated** from `ProviderHierarchyCatalog`,
/// `ToolType` and `HarnessCatalog` rather than transcribed. A hand-written
/// copy of `AGENTS.md` § 7.1 would drift the first time a provider is added,
/// and a stale spec is worse than none: it teaches the model a label that no
/// longer exists.
public enum MCPResourceCatalog {
    public static let namingSpecURI = "vibebar://naming-spec"
    public static let toolsGuideURI = "vibebar://tools"

    public static let all: [MCPResource] = [
        MCPResource(
            uri: namingSpecURI,
            name: "naming-spec",
            title: "Vibe Bar provider and harness naming",
            description: "The two naming axes — quota (company / SubProvider / group) and usage "
                + "(harness) — with the current tables and the model-name rule.",
            mimeType: "text/markdown"
        ),
        MCPResource(
            uri: toolsGuideURI,
            name: "tools",
            title: "Which Vibe Bar tool answers what",
            description: "A short routing guide from a user's question to the tool that answers it.",
            mimeType: "text/markdown"
        )
    ]

    public static func contents(of uri: String) -> (mimeType: String, text: String)? {
        switch uri {
        case namingSpecURI: return ("text/markdown", namingSpec)
        case toolsGuideURI: return ("text/markdown", toolsGuide)
        default: return nil
        }
    }

    // MARK: - Naming spec

    public static var namingSpec: String {
        var lines: [String] = []
        lines.append("# Vibe Bar provider and harness naming")
        lines.append("")
        lines.append("Vibe Bar names a provider along **two orthogonal axes**. Pick one axis per")
        lines.append("answer and stay on it; never mix levels of the two in one list.")
        lines.append("")
        lines.append("- **Quota axis** — what an account is billed against. L1 company → L2")
        lines.append("  SubProvider → L3 quota / model group. This is what `quota.get` and")
        lines.append("  `status.get` speak.")
        lines.append("- **Usage / cost axis** — where the tokens were actually spent. The unit is")
        lines.append("  the local *harness*: the CLI or app that produced the sessions Vibe Bar")
        lines.append("  scanned. It is neither the company nor the quota SubProvider. This is what")
        lines.append("  `usage.*` and `sessions.*` speak.")
        lines.append("")
        lines.append("Two harnesses can draw on one SubProvider's quota (Claude Code and Claude")
        lines.append("Cowork both spend Claude's), and one company can own several harnesses that")
        lines.append("bill against different quotas.")
        lines.append("")
        lines.append("## Quota axis")
        lines.append("")
        lines.append("| L1 company | L2 SubProvider | tool key |")
        lines.append("| --- | --- | --- |")
        for tool in ToolType.dedicatedCardProviders {
            lines.append("| \(tool.vendorName) | \(tool.quotaSubProviderName()) | `\(tool.rawValue)` |")
        }
        lines.append("")
        lines.append("Grok Bot is a cloud-only SubProvider that shares Cursor's adapter: it appears")
        lines.append("as the `grok_bot_weekly` bucket under the `cursor` tool.")
        lines.append("")
        lines.append("L3 is the bucket: `id`, `title` and `groupTitle` on each entry of")
        lines.append("`quota.get` → `accounts[].buckets[]`. Examples are \"5 Hours\", \"Weekly\",")
        lines.append("\"All Models\", and per-model groups such as Sonnet / Opus / Fable.")
        lines.append("")
        lines.append("### Misc providers")
        lines.append("")
        lines.append("These have quota but no dedicated card, no cost scan and no status page:")
        lines.append("")
        lines.append("| Company | SubProvider | tool key |")
        lines.append("| --- | --- | --- |")
        for tool in ToolType.miscPageProviders {
            lines.append("| \(tool.vendorName) | \(tool.productName) | `\(tool.rawValue)` |")
        }
        lines.append("")
        lines.append("## Usage / cost axis")
        lines.append("")
        lines.append("| Harness | L1 company | harness key | Local evidence |")
        lines.append("| --- | --- | --- | --- |")
        for harness in Harness.allCases {
            lines.append(
                "| \(harness.displayName) | \(harness.companyName) | `\(harness.rawValue)` | \(evidence(for: harness)) |"
            )
        }
        lines.append("")
        lines.append("Consequences worth stating out loud:")
        lines.append("")
        lines.append("- \"Gemini Web\" is a quota SubProvider with **no** local usage. The")
        lines.append("  deprecated CLI's historical tokens are always labelled \"Gemini CLI\".")
        lines.append("- Cursor's tokens stay remote on purpose: its sessions are listed locally,")
        lines.append("  but cost comes from the dashboard, so a Cursor session can have real")
        lines.append("  messages and no local token counters.")
        lines.append("- The Sessions surface is a **usage** surface. Its rows are labelled with")
        lines.append("  the harness; only company chips speak L1.")
        lines.append("")
        lines.append("## Model names")
        lines.append("")
        lines.append("Display always uses the canonical vendor id — `gemini-3.5-flash-high`, not")
        lines.append("\"Gemini 3.5 Flash (High)\". The ledger, the pricing tables and every `model`")
        lines.append("field in these tools keep whatever the provider wrote, because rates are")
        lines.append("matched on those upstream labels. Filter on the raw id; canonicalize only")
        lines.append("what you print.")
        lines.append("")
        lines.append("Where a model is genuinely absent — an aborted Cursor conversation records")
        lines.append("no model at all, and old Gemini CLI chats predate the per-turn field — the")
        lines.append("value is `null`. Never infer a model from the provider's \"usual\" one.")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func evidence(for harness: Harness) -> String {
        switch harness {
        case .codex:        return "`~/.codex/sessions` rollouts"
        case .chatgptWork:  return "same tree, `originator` == \"codex_work_desktop\""
        case .claudeCode:   return "`~/.claude/projects`, `~/.config/claude/projects`"
        case .claudeCowork: return "Claude.app's `local-agent-mode-sessions`"
        case .geminiCLI:    return "`~/.gemini/tmp/*/chats`, telemetry log"
        case .antigravity:  return "`~/.gemini/antigravity{,-cli,-ide}/conversations`"
        case .grokBuild:    return "`~/.grok/sessions/**/updates.jsonl`"
        case .cursor:       return "`~/.cursor/chats/**/store.db`; cost from the dashboard"
        }
    }

    // MARK: - Tool guide

    public static let toolsGuide = """
        # Which Vibe Bar tool answers what

        Vibe Bar exposes one Mac's local AI usage. Everything is read from the
        running app's own caches; nothing here calls a provider directly except
        `quota.refresh`, which asks the app to. `skills.install` is the one tool
        that writes, and only inside the skills directories Vibe Bar manages.

        ## Routing

        | The user asks | Call |
        | --- | --- |
        | "how much Codex / Claude / Gemini / Grok / Cursor do I have left?" | `quota.get` |
        | "when does my 5-hour window reset?" | `quota.get` (`buckets[].resetAt`) |
        | "am I going to run out before the reset?" | `quota.get` with `includeForecast: true` |
        | "refresh my usage" | `quota.refresh`, then `quota.get` |
        | "who used the most tokens this month?" | `usage.summary` with `groupBy: "harness"` |
        | "what did I spend this week?" | `cost.snapshot`, or `usage.summary` for a custom window |
        | "how has my spend moved day by day?" | `cost.history` |
        | "show me my usage over time" | `usage.trend` |
        | "what were my last N requests?" | `usage.requests` |
        | "find my session about X" | `sessions.search` |
        | "what have I been working on?" | `sessions.list` |
        | "is Anthropic down?" | `status.get` |
        | "why is this model costing so much?" | `pricing.effective` |
        | "install the Vibe Bar skill" / "add this skill" | `skills.install` |

        ## Rules that keep the answer right

        - **Two axes, never mixed.** `quota.*` and `status.*` speak company /
          SubProvider / bucket. `usage.*` and `sessions.*` speak harnesses. Read
          `vibebar://naming-spec` before phrasing a comparison across providers.
        - **Cite `generatedAt`.** Every payload carries it. Quota is a cache — say
          how old it is rather than implying it is live.
        - **Refresh sparingly.** `quota.refresh` without `force` only touches
          accounts that are genuinely stale, and that is the right default. Do not
          poll; a forced refresh more than once every few minutes is rate-limited
          and tells the provider nothing new.
        - **Money has two fields.** `costMicros` is exact micro-USD; `costUSD` is
          rounded for display. Sum the micros, print the dollars.
        - **`unpricedRequests > 0` means the total is a floor.** Some model on the
          window has no rate card. Say so; check `pricing.effective`.
        - **Privacy mode empties the cost surfaces.** When `cost.snapshot` reports
          `privacyModeEnabled: true`, report that the user turned cost tracking
          off — not that they spent nothing.
        - **Request-level history is about 30 days deep.** Older usage survives as
          daily totals, visible through `usage.summary` and `usage.trend` but not
          through `usage.requests`.
        - **`skills.install` installs; it does not browse.** Name a source —
          `owner/repo`, `owner/repo@branch`, either plus `#<skill>` when the
          repository holds several, a github.com URL, or an absolute local
          directory — and pass `apps` for the agent CLIs that should get it.
          Without `apps` the skill lands in `~/.agents/skills/` switched on for
          nobody. It can be switched off in Settings → MCP Server, in which case
          the tool says so rather than failing silently.
        """
}
