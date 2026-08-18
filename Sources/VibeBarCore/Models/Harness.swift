import Foundation

/// Canonical display names for every local harness Vibe Bar scans.
///
/// Vibe Bar identifies a provider along **two orthogonal axes**, and a
/// surface must never mix them inside one list:
///
/// - **Quota axis** — L1 company → L2 SubProvider → L3 quota / model group.
///   Lives in `ProviderHierarchyCatalog` + `ToolType.quotaSubProviderName`.
/// - **Usage / cost axis** — the *harness*: the CLI or app that actually
///   produced the sessions we scanned. That is neither the company nor the
///   quota SubProvider. Two harnesses can draw on one SubProvider's quota
///   (Claude Code and Claude Cowork both spend Claude's), and one company can
///   own several harnesses that bill against different quotas.
///
/// | Harness        | L1 company | Local evidence                                              |
/// | -------------- | ---------- | ----------------------------------------------------------- |
/// | Codex          | OpenAI     | `~/.codex/sessions` rollouts, every other `originator` (`Codex Desktop`, `codex-tui`, `codex_cli_rs`, `codex_exec`, `codex_vscode`) |
/// | ChatGPT Work   | OpenAI     | same tree, `originator` == "codex_work_desktop"              |
/// | Claude Code    | Anthropic  | `~/.claude/projects`, `~/.config/claude/projects`            |
/// | Claude Cowork  | Anthropic  | `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects` |
/// | Gemini CLI     | Google AI  | `~/.gemini/tmp/*/chats/session-*.jsonl` (+ telemetry log)    |
/// | AntiGravity    | Google AI  | `~/.gemini/antigravity{,-cli,-ide}/conversations`            |
/// | Grok Build     | SpaceXAI   | `~/.grok/sessions/**/updates.jsonl`                          |
/// | Cursor         | SpaceXAI   | `~/.cursor/chats/**/store.db` for sessions; dashboard remote events for cost (no local token counters) |
///
/// Renaming a harness is one edit here, not a hunt across the UI.
/// `AGENTS.md` § 7.1 carries the coverage matrix — which of model, cost,
/// sessions, and delete each harness actually supports.
public enum HarnessCatalog {
    public static let codex = "Codex"
    public static let chatgptWork = "ChatGPT Work"
    public static let claudeCode = "Claude Code"
    public static let claudeCowork = "Claude Cowork"
    /// Deliberately *not* "Gemini Web": Gemini Web is a quota SubProvider
    /// with no local usage at all, and this deprecated CLI still owns real
    /// historical token counts under `~/.gemini/tmp`.
    public static let geminiCLI = "Gemini CLI"
    public static let antigravity = "AntiGravity"
    public static let grokBuild = "Grok Build"
    public static let cursor = "Cursor"
}

/// The local harness a usage event came from — the unit every usage and cost
/// surface groups by. See `HarnessCatalog` for the full table and for why
/// this is a different axis from the quota hierarchy.
///
/// Declaration order is the display order: harnesses grouped by their L1
/// company, in the same company order the quota surfaces use.
public enum Harness: String, CaseIterable, Codable, Sendable, Hashable {
    case codex
    case chatgptWork
    case claudeCode
    case claudeCowork
    case geminiCLI
    case antigravity
    case grokBuild
    case cursor

    public var displayName: String {
        switch self {
        case .codex:        HarnessCatalog.codex
        case .chatgptWork:  HarnessCatalog.chatgptWork
        case .claudeCode:   HarnessCatalog.claudeCode
        case .claudeCowork: HarnessCatalog.claudeCowork
        case .geminiCLI:    HarnessCatalog.geminiCLI
        case .antigravity:  HarnessCatalog.antigravity
        case .grokBuild:    HarnessCatalog.grokBuild
        case .cursor:       HarnessCatalog.cursor
        }
    }

    /// The `ToolType` whose quota this harness consumes. Usage rows are still
    /// stored under this tool, so the harness dimension refines the existing
    /// per-tool ledger rather than replacing it.
    public var quotaTool: ToolType {
        switch self {
        case .codex, .chatgptWork:      .codex
        case .claudeCode, .claudeCowork: .claude
        case .geminiCLI:                .gemini
        case .antigravity:              .antigravity
        case .grokBuild:                .grok
        case .cursor:                   .cursor
        }
    }

    /// L1 company representative — the same one the quota chips filter by, so
    /// a harness row and a company chip always agree on the brand.
    public var company: ToolType {
        quotaTool.coreProviderRepresentative ?? quotaTool
    }

    /// L1 company name, e.g. "OpenAI" / "Google AI".
    public var companyName: String {
        company.vendorName
    }

    /// The harness a tool's events belong to when nothing more specific was
    /// stamped — used to backfill ledger rows written before the harness
    /// dimension existed, and as a defensive fallback at ingest.
    ///
    /// Codex maps to `.codex` rather than `.chatgptWork` because ordinary Codex
    /// — CLI, exec, the VS Code extension and the desktop app's Codex tab — is
    /// the overwhelming majority; a ChatGPT Work rollout is recognised from its
    /// `originator` at scan time and overrides this.
    public static func defaultHarness(for tool: ToolType) -> Harness? {
        switch tool {
        case .codex:       .codex
        case .claude:      .claudeCode
        case .gemini:      .geminiCLI
        case .antigravity: .antigravity
        case .grok:        .grokBuild
        case .cursor:      .cursor
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi,
             .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine,
             .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro,
             .ollama, .openRouter, .warp:
            nil
        }
    }

    /// Every harness owned by one L1 company, in declaration order.
    public static func harnesses(forCompany company: ToolType) -> [Harness] {
        let representative = company.coreProviderRepresentative ?? company
        return allCases.filter { $0.company == representative }
    }

    /// One filter-chip group: an L1 company and the harnesses under it.
    ///
    /// The company is context, not a peer of its members. Usage and cost
    /// surfaces filter by harness — that is the unit a row is labelled with —
    /// and the company chip exists only to toggle its harnesses in one click.
    public struct ChipGroup: Equatable, Sendable, Identifiable {
        public let company: ToolType
        public let harnesses: [Harness]

        public init(company: ToolType, harnesses: [Harness]) {
            self.company = company
            self.harnesses = harnesses
        }

        public var id: ToolType { company }

        public var harnessSet: Set<Harness> { Set(harnesses) }
    }

    /// Groups `harnesses` under `companies` for a harness-primary filter row.
    ///
    /// Companies are normalized to their representative and de-duplicated, the
    /// members keep `allCases` declaration order, and a company that
    /// contributes no harness is dropped — a chip that can only ever narrow to
    /// nothing should not be drawn. Pass a narrowed `harnesses` list (the ones
    /// a page actually knows about) to keep the row honest.
    public static func chipGroups(
        companies: [ToolType],
        harnesses: [Harness] = Harness.allCases
    ) -> [ChipGroup] {
        let available = Set(harnesses)
        var seen: Set<ToolType> = []
        var groups: [ChipGroup] = []
        for company in companies {
            let representative = company.coreProviderRepresentative ?? company
            guard seen.insert(representative).inserted else { continue }
            let members = Self.harnesses(forCompany: representative)
                .filter(available.contains)
            guard !members.isEmpty else { continue }
            groups.append(ChipGroup(company: representative, harnesses: members))
        }
        return groups
    }
}
