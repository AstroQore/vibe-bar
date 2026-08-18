import Foundation

/// The tool surface, schemas included. `MCPTool` itself is
/// `AgentSessionKit`'s — the wire shape of `tools/list` is not Vibe
/// Bar-specific; which tools exist is.
///
/// Descriptions carry the two-axis rule (`AGENTS.md` § 7.1) inline rather
/// than assuming the agent read the naming-spec resource first: a model
/// picking a tool from a list reads these strings and nothing else, and
/// "which provider used the most" has two different right answers depending
/// on whether the question is about quota or about spend.
public enum MCPToolCatalog {
    public static let all: [MCPTool] = [
        quotaGet,
        quotaRefresh,
        usageSummary,
        usageTrend,
        usageRequests,
        costSnapshot,
        costHistory,
        sessionsSearch,
        sessionsList,
        statusGet,
        pricingEffective,
        skillsInstall
    ]

    public static func tool(named name: String) -> MCPTool? {
        all.first { $0.name == name }
    }

    // MARK: - Schema helpers

    static func object(
        properties: [String: MCPJSON],
        required: [String] = []
    ) -> MCPJSON {
        var schema: [String: MCPJSON] = [
            "type": .string("object"),
            "properties": .object(properties),
            // Agents routinely invent plausible-looking extra arguments.
            // Rejecting them here turns a silently ignored filter into a
            // visible error instead of a wrong number.
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    static func stringEnumList(_ values: [String], description: String) -> MCPJSON {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object([
                "type": .string("string"),
                "enum": .array(values.map { .string($0) })
            ])
        ])
    }

    static func string(_ description: String, enumValues: [String]? = nil) -> MCPJSON {
        var schema: [String: MCPJSON] = [
            "type": .string("string"),
            "description": .string(description)
        ]
        if let enumValues {
            schema["enum"] = .array(enumValues.map { .string($0) })
        }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> MCPJSON {
        var schema: [String: MCPJSON] = [
            "type": .string("integer"),
            "description": .string(description)
        ]
        if let minimum { schema["minimum"] = .int(Int64(minimum)) }
        if let maximum { schema["maximum"] = .int(Int64(maximum)) }
        return .object(schema)
    }

    static func boolean(_ description: String) -> MCPJSON {
        .object([
            "type": .string("boolean"),
            "description": .string(description)
        ])
    }

    // MARK: - Shared vocabularies

    public static var toolValues: [String] { ToolType.allCases.map(\.rawValue) }
    public static var harnessValues: [String] { Harness.allCases.map(\.rawValue) }
    public static var sessionProviderValues: [String] { SessionProvider.allCases.map(\.rawValue) }

    private static var toolFilter: MCPJSON {
        stringEnumList(
            toolValues,
            description: "Quota-axis providers to keep. Omit for all of them."
        )
    }

    private static var harnessFilter: MCPJSON {
        stringEnumList(
            harnessValues,
            description: "Local harnesses (the CLI or app that produced the requests) to keep. "
                + "Orthogonal to 'tools': Claude Code and Claude Cowork both bill against the 'claude' quota."
        )
    }

    private static var rangeProperties: [String: MCPJSON] {
        [
            "from": string("Inclusive ISO-8601 start of the window. Overrides 'days' when both are given."),
            "to": string("Exclusive ISO-8601 end of the window. Defaults to now."),
            "days": integer(
                "Window length in days ending now, used when 'from' is absent. Defaults to 30.",
                minimum: 1,
                maximum: 3_650
            ),
            "tools": toolFilter,
            "harnesses": harnessFilter,
            "models": .object([
                "type": .string("array"),
                "description": .string(
                    "Raw vendor model ids to keep, exactly as the provider spelled them "
                        + "(for example 'claude-opus-4-7', not 'Opus')."
                ),
                "items": .object(["type": .string("string")])
            ])
        ]
    }

    // MARK: - Tools

    public static let quotaGet = MCPTool(
        name: "quota.get",
        title: "Read subscription quota",
        description: """
            Live subscription quota per account, straight from Vibe Bar's cache — no network call. \
            This is the quota axis: L1 company (OpenAI, Anthropic, Google AI, SpaceXAI), L2 SubProvider \
            (ChatGPT Agentic, Claude, Gemini Web, AntiGravity, Grok, Cursor), L3 buckets ('5 Hours', \
            'Weekly', per-model groups). Answers 'how much Codex / Claude / Gemini / Grok / Cursor do I \
            have left'. Percentages come back both used and remaining. 'lastUpdated' is when the numbers \
            were fetched; 'lastAttempted' is when a refresh last ran, successful or not — quote \
            'generatedAt' when reporting. For tokens spent or money, use usage.summary or cost.snapshot \
            instead: those speak harnesses, not quota.
            """,
        inputSchema: object(properties: [
            "tools": toolFilter,
            "includeForecast": boolean(
                "Include Vibe Bar's pace forecast per bucket (projected use at reset, run-out time). Default false."
            )
        ])
    )

    public static let quotaRefresh = MCPTool(
        name: "quota.refresh",
        title: "Refresh subscription quota",
        description: """
            Ask the running app to re-fetch quota from the providers. Returns as soon as the refresh is \
            queued — call quota.get afterwards to read the result. Without 'force' this only refreshes \
            accounts whose cache is actually stale, which is almost always what you want. 'force: true' \
            refreshes regardless and is rate-limited to once per 20 seconds per server; it also requires \
            the 'Allow agents to refresh' toggle in Vibe Bar's MCP settings. Do not poll: quota moves on \
            the provider's clock, not yours.
            """,
        inputSchema: object(properties: [
            "tools": toolFilter,
            "force": boolean("Refresh even when the cache is fresh. Default false.")
        ])
    )

    public static let usageSummary = MCPTool(
        name: "usage.summary",
        title: "Summarize token usage and spend",
        description: """
            Headline requests, tokens and cost over a window, from the local per-request usage ledger. \
            This is the usage/cost axis: rows are attributed to the local harness that produced them \
            (Codex, ChatGPT Work, Claude Code, Claude Cowork, Gemini CLI, AntiGravity, Grok Build, \
            Cursor). Use groupBy 'harness' for 'who used the most', 'provider' for company-level totals, \
            'model' for a per-model ranking. Token columns never overlap, so freshInput + output + \
            cacheRead + cacheCreation is the real total. Cost is exact in 'costMicros' (micro-USD) and \
            rounded in 'costUSD'; a non-zero 'unpricedRequests' means the total is a floor.
            """,
        inputSchema: object(properties: rangeProperties.merging([
            "groupBy": string(
                "Break the window down by 'harness' (the CLI or app), 'provider' (L1 company) or 'model'.",
                enumValues: ["harness", "provider", "model"]
            )
        ]) { _, new in new })
    )

    public static let usageTrend = MCPTool(
        name: "usage.trend",
        title: "Token usage over time",
        description: """
            A zero-filled time series of tokens and cost over the same window and filters as \
            usage.summary — every bucket is present, including the empty ones. Hourly buckets only \
            exist inside the ledger's detail window (the last 30 days); an hourly request over an older \
            range resolves down to daily, and the response says which bucket was actually used.
            """,
        inputSchema: object(properties: rangeProperties.merging([
            "bucket": string(
                "Bucket size. Omit to let the ledger pick from the range.",
                enumValues: UsageTrendBucket.allCases.map(\.rawValue)
            )
        ]) { _, new in new })
    )

    public static let usageRequests = MCPTool(
        name: "usage.requests",
        title: "List individual requests",
        description: """
            The per-request log, newest first, over the same window and filters as usage.summary. \
            Only the ledger's detail window (about the last 30 days) has request-level rows; older \
            history survives as daily totals and is visible through usage.summary and usage.trend only. \
            Page by passing the previous response's 'nextCursor' back as 'cursor' — the cursor is opaque, \
            do not construct or edit one.
            """,
        inputSchema: object(properties: rangeProperties.merging([
            "cursor": string("Opaque 'nextCursor' from a previous page. Omit for the first page."),
            "pageSize": integer("Rows per page, 1–200. Default 50.", minimum: 1, maximum: 200)
        ]) { _, new in new })
    )

    public static let costSnapshot = MCPTool(
        name: "cost.snapshot",
        title: "Cost and token totals per provider",
        description: """
            Today / last 7 days / last 30 days / all-time cost, tokens and request counts per provider, \
            from Vibe Bar's last cost scan. Cheaper than usage.summary and already aggregated, so prefer \
            it for 'what have I spent'. When 'privacyModeEnabled' is true every window is empty by \
            design — say so rather than reporting zero spend.
            """,
        inputSchema: object(properties: ["tools": toolFilter])
    )

    public static let costHistory = MCPTool(
        name: "cost.history",
        title: "Daily cost history for one provider",
        description: """
            Day-by-day cost and token totals for a single provider. Use it for 'how has my spend moved \
            this month'; use cost.snapshot for the current totals.
            """,
        inputSchema: object(
            properties: [
                "tool": string("Provider to report on.", enumValues: toolValues),
                "timeframe": string(
                    "How far back to go. Default '30d'.",
                    enumValues: ["7d", "30d", "all"]
                )
            ],
            required: ["tool"]
        )
    )

    public static let sessionsSearch = MCPTool(
        name: "sessions.search",
        title: "Full-text search local agent sessions",
        description: """
            Search titles, projects and message bodies across every local CLI session Vibe Bar has \
            indexed. Answers 'find my session about X'. Results carry the matching excerpt with <b> \
            markers around the hit, plus the on-disk path so the transcript can be opened. Body search \
            needs Vibe Bar's session body indexing enabled; with it off, titles and projects still match. \
            Rows are labelled with the harness (the usage axis), not the quota SubProvider.
            """,
        inputSchema: object(
            properties: [
                "query": string("Text to look for. Substring matching, so partial words and CJK both work."),
                "harnesses": harnessFilter,
                "providers": stringEnumList(
                    sessionProviderValues,
                    description: "On-disk session stores to search. Prefer 'harnesses' unless you specifically want a store."
                ),
                "limit": integer("Maximum hits, 1–50. Default 20.", minimum: 1, maximum: 50)
            ],
            required: ["query"]
        )
    )

    public static let sessionsList = MCPTool(
        name: "sessions.list",
        title: "List local agent sessions",
        description: """
            Recent local CLI sessions, newest first, with title, project directory, model, message count \
            and on-disk path. Use sessions.search when you know what the session was about. Rows are \
            labelled with the harness (the usage axis).
            """,
        inputSchema: object(properties: [
            "harnesses": harnessFilter,
            "providers": stringEnumList(
                sessionProviderValues,
                description: "On-disk session stores to list. Prefer 'harnesses' unless you specifically want a store."
            ),
            "since": string("Only sessions last active at or after this ISO-8601 instant."),
            "offset": integer("Rows to skip, for paging. Default 0.", minimum: 0),
            "limit": integer("Rows to return, 1–100. Default 50.", minimum: 1, maximum: 100)
        ])
    )

    public static let statusGet = MCPTool(
        name: "status.get",
        title: "Provider service status",
        description: """
            Each provider company's own status page, as Vibe Bar last read it: indicator \
            (none / minor / major / critical / maintenance) plus the page's own description. Rows are at \
            the L1 company level — Google AI covers Gemini and AntiGravity, SpaceXAI covers Grok and \
            Cursor. Useful when a provider looks broken and you want to know whether it is them or the \
            local setup.
            """,
        inputSchema: object(properties: ["tools": toolFilter])
    )

    public static let pricingEffective = MCPTool(
        name: "pricing.effective",
        title: "Effective model prices",
        description: """
            The rate card Vibe Bar is actually costing requests with, including any local overrides — \
            USD per one million tokens, per model. Use it to explain a cost number or to check whether a \
            model is priced at all (an unpriced model contributes 0 to every cost total).
            """,
        inputSchema: object(properties: [
            "provider": string(
                "Pricing family to keep.",
                enumValues: PricingProviderFamily.allCases.map(\.rawValue)
            ),
            "model": string("Case-insensitive substring of the model id.")
        ])
    )

    public static let skillsInstall = MCPTool(
        name: "skills.install",
        title: "Install an agent skill",
        description: """
            Install a skill through Vibe Bar's Skills manager: one copy in ~/.agents/skills/, projected \
            into whichever agent CLIs you name. This is the non-UI equivalent of Workbench → Skills → \
            Install, and the only write tool here. 'source' is 'owner/repo', 'owner/repo@branch', either \
            with '#<skill>' when the repository holds more than one (the error lists them), a github.com \
            repository / branch / archive URL, or an absolute path to a local directory containing \
            SKILL.md. Installing without 'apps' puts the skill on the machine without switching it on for \
            anyone — pass 'apps' to project it. Re-installing something already installed just enables the \
            extra apps; it never overwrites the local copy. Vibe Bar's own companion skill is \
            'AstroQore/vibe-bar'.
            """,
        inputSchema: object(
            properties: [
                "source": string(
                    "owner/repo[@branch][#skill], a github.com URL, or an absolute local directory."
                ),
                "apps": stringEnumList(
                    SkillAppTarget.allCases.map(\.rawValue),
                    description: "Agent CLIs to project the skill into. Omit to install without enabling it anywhere."
                ),
                "method": string(
                    "How to project it: 'symlink' (default, one copy) or 'copy' (independent per app).",
                    enumValues: [SkillSyncMethod.symlink.rawValue, SkillSyncMethod.copy.rawValue]
                )
            ],
            required: ["source"]
        )
    )
}
