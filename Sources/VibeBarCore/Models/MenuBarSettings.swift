import Foundation

public enum MenuBarItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact

    public var id: String { rawValue }

    public var label: String {
        L10n.Platform.macosMenuBarOverview
    }

    public var title: String {
        "VB"
    }
}

public enum MenuBarLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case singleLine
    case twoRows
    case compact

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .iconOnly: return L10n.Platform.macosMenuBarLayoutIconOnly
        case .singleLine: return L10n.Platform.macosMenuBarLayoutSingleLine
        case .twoRows: return L10n.Platform.macosMenuBarLayoutTwoRows
        case .compact: return L10n.Platform.macosMenuBarLayoutCompact
        }
    }

    public var showsMenuBarIcon: Bool {
        self == .iconOnly
    }
}

/// Which signal decides the color of a menu-bar percentage.
///
/// Declaration order is the Settings picker order, so the default sits first.
public enum MenuBarColorBasis: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Color by the bucket's pace forecast: whether the quota is projected to
    /// survive until it refills, and whether a chunk of it is projected to go
    /// unused.
    case forecast
    /// Color by the displayed percentage alone, against fixed thresholds.
    case actual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .forecast: return L10n.Platform.macosMenuBarColorForecast
        case .actual: return L10n.Platform.macosMenuBarColorActual
        }
    }

    /// Spelled out for the Settings caption: the menu bar has no room for a
    /// legend, and blue is the one color whose meaning nobody can guess.
    public var detail: String {
        switch self {
        case .forecast:
            return L10n.Platform.macosMenuBarColorForecastDetail
        case .actual:
            return L10n.Platform.macosMenuBarColorActualDetail
        }
    }
}

/// The semantic color one menu-bar percentage should be painted in.
///
/// Kept as a value rather than a platform color so the thresholds and the
/// verdict mapping are testable without AppKit; `StatusItemController` owns the
/// `NSColor` translation.
public enum MenuBarPercentColor: Equatable, Sendable {
    case healthy
    case surplus
    case watch
    case risk

    /// Resolves the color for one rendered percentage.
    ///
    /// `verdict` is `nil` when the bucket has no forecast at all (no account,
    /// no observations yet) and `.learning` while the forecast is still
    /// gathering evidence. Both fall back to the `.actual` thresholds on
    /// purpose: the menu bar shows one colored number with no legend and no
    /// room for an explanation, so a distinct "no opinion" shade would read as
    /// a broken app rather than as a forecast that has not converged.
    public static func resolve(
        basis: MenuBarColorBasis,
        verdict: QuotaPaceForecast.Verdict?,
        percent: Double,
        displayMode: DisplayMode
    ) -> MenuBarPercentColor {
        guard basis == .forecast, let verdict else {
            return threshold(percent: percent, displayMode: displayMode)
        }
        switch verdict {
        case .enough: return .healthy
        case .surplus: return .surplus
        case .watch: return .watch
        case .atRisk: return .risk
        case .learning: return threshold(percent: percent, displayMode: displayMode)
        }
    }

    /// The pre-forecast thresholds, unchanged so `.actual` is exact parity with
    /// what the menu bar has always shown. Never yields `.surplus`: an isolated
    /// percentage cannot tell whether capacity is going to waste.
    private static func threshold(percent: Double, displayMode: DisplayMode) -> MenuBarPercentColor {
        switch displayMode {
        case .remaining:
            if percent < 10 { return .risk }
            if percent < 30 { return .watch }
            return .healthy
        case .used:
            if percent >= 90 { return .risk }
            if percent >= 70 { return .watch }
            return .healthy
        }
    }
}

/// How one selected field draws itself on the status item: its label beside
/// the percent (the default), the provider's logo instead of the label, or
/// both. Chosen per field, so a crowded bar can shorten some quotas to a
/// logo while the ambiguous ones keep their words.
public enum MenuBarFieldStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case labelAndPercent
    case logoAndPercent
    case logoLabelAndPercent

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .labelAndPercent: return L10n.Platform.macosMenuBarFieldStyleLabel
        case .logoAndPercent: return L10n.Platform.macosMenuBarFieldStyleLogo
        case .logoLabelAndPercent: return L10n.Platform.macosMenuBarFieldStyleLogoAndLabel
        }
    }

    public var detail: String {
        switch self {
        case .labelAndPercent: return L10n.Platform.macosMenuBarFieldStyleLabelDetail
        case .logoAndPercent: return L10n.Platform.macosMenuBarFieldStyleLogoDetail
        case .logoLabelAndPercent: return L10n.Platform.macosMenuBarFieldStyleLogoAndLabelDetail
        }
    }
}

public struct MenuBarItemSettings: Codable, Equatable, Identifiable, Sendable {
    public var kind: MenuBarItemKind
    public var isVisible: Bool
    /// The retired "Show title text" flag: decoded, never written, never read
    /// by anything that draws.
    ///
    /// It survives only as the discriminator in
    /// `AppSettings.migratedMenuBarItem`, which recognises one specific legacy
    /// compact default and replaces it wholesale. Two of the three things that
    /// identified that default are still here; without the third, an item that
    /// kept the old field ids and the old renamed labels but had the toggle
    /// *off* — one click away, no hand-typed labels needed — would be mistaken
    /// for it and lose its layout, visibility, styles, merge setting and
    /// composed strip.
    ///
    /// It decays safely: dropped on the next write, so a later launch reads
    /// `nil` and the migration declines rather than fires.
    public private(set) var legacyShowsTitle: Bool?
    public var layout: MenuBarLayout
    public var selectedFieldIds: [String]
    public var customLabels: [String: String]
    /// Per-field display style; a missing entry is `.labelAndPercent`.
    public var fieldStyles: [String: MenuBarFieldStyle]
    /// Draw adjacent selected fields that share one quota group as a single
    /// entry — `Claude 5%/100%` instead of `5 Hours 5% · Weekly 100%`.
    /// Opt-in: the un-merged list is what every existing bar already shows.
    public var mergesGroupWindows: Bool
    /// The composed strip, when the user has ever opened the composer.
    ///
    /// `nil` means they never did, and the item renders the field-based strip
    /// this type has always rendered. A stored composition with
    /// `isEnabled == false` means they built one and switched back — the
    /// arrangement is kept so switching on again returns to it instead of
    /// reseeding over their work. Every field-mode setting above stays intact
    /// either way; the two modes never write over each other.
    public var composition: MenuBarComposition?
    /// Groups of blocks the user saved to insert again.
    ///
    /// Beside the composition rather than inside it, because "Start over"
    /// replaces the composition wholesale and a library that vanished with it
    /// would be a library nobody trusts. Beside it rather than at the top of
    /// `AppSettings` because a preset is a piece of *this* strip, there is one
    /// menu-bar item, and the item already has the tolerant per-item decoder
    /// this list wants.
    public var segmentPresets: [MenuBarSegmentPreset]

    public var id: MenuBarItemKind { kind }

    /// Whether this item draws the composed strip rather than the field list.
    public var usesComposedStrip: Bool { composition?.isEnabled == true }

    public init(
        kind: MenuBarItemKind,
        isVisible: Bool,
        layout: MenuBarLayout = .singleLine,
        selectedFieldIds: [String],
        customLabels: [String: String] = [:],
        fieldStyles: [String: MenuBarFieldStyle] = [:],
        mergesGroupWindows: Bool = false,
        composition: MenuBarComposition? = nil,
        segmentPresets: [MenuBarSegmentPreset] = []
    ) {
        self.kind = kind
        self.isVisible = isVisible
        self.layout = layout
        self.selectedFieldIds = selectedFieldIds
        self.customLabels = customLabels
        self.fieldStyles = fieldStyles
        self.mergesGroupWindows = mergesGroupWindows
        self.composition = composition
        self.segmentPresets = segmentPresets
    }

    public func style(for fieldId: String) -> MenuBarFieldStyle {
        fieldStyles[fieldId] ?? .labelAndPercent
    }

    /// Turn the composer on or off without losing anything.
    ///
    /// Seeding happens exactly once — the first time custom mode is switched
    /// on with no stored strip. Afterwards this only flips `isEnabled`, so a
    /// user who toggles back and forth keeps the arrangement they built, and
    /// the field-mode selection is never touched at all. Stage 2's editor
    /// should call `reseed(template:...)` when the user explicitly asks to
    /// start over.
    public mutating func setComposedStripEnabled(
        _ enabled: Bool,
        template: MenuBarComposition.Template = .roomy,
        registry: QuotaFieldRegistry = .empty,
        groupCatalogLabel: (String) -> String? = { _ in nil }
    ) {
        if var existing = composition {
            existing.isEnabled = enabled
            composition = existing
            return
        }
        guard enabled else { return }
        var seeded = MenuBarComposition.seeded(
            template: template,
            from: self,
            registry: registry,
            groupCatalogLabel: groupCatalogLabel
        )
        seeded.isEnabled = true
        composition = seeded
    }

    /// Replace the stored strip with a fresh seed of `template`, keeping the
    /// current on/off state. This is the destructive one; it exists so the
    /// editor's "start over" is explicit rather than a side effect of a toggle.
    public mutating func reseedComposedStrip(
        template: MenuBarComposition.Template,
        registry: QuotaFieldRegistry = .empty,
        groupCatalogLabel: (String) -> String? = { _ in nil }
    ) {
        let wasEnabled = composition?.isEnabled ?? false
        var seeded = MenuBarComposition.seeded(
            template: template,
            from: self,
            registry: registry,
            groupCatalogLabel: groupCatalogLabel
        )
        seeded.isEnabled = wasEnabled
        composition = seeded
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case isVisible
        /// Retired; decoded into `legacyShowsTitle` and never encoded.
        case showTitle
        case layout
        case selectedFieldIds
        case customLabels
        case fieldStyles
        case mergesGroupWindows
        case composition
        case segmentPresets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(MenuBarItemKind.self, forKey: .kind)
        self.isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        self.legacyShowsTitle = try c.decodeIfPresent(Bool.self, forKey: .showTitle)
        // `try?`: an unknown layout from a newer build used to throw, and
        // `LossyMenuBarItem` turns that into a dropped item — which discards
        // the field selection, every rename, every per-field style *and* the
        // composed strip, replacing the lot with defaults. One unreadable
        // enum must cost at most that enum.
        self.layout = (try? c.decode(MenuBarLayout.self, forKey: .layout))
            ?? (kind == .compact ? .iconOnly : .singleLine)
        self.selectedFieldIds = try c.decodeIfPresent([String].self, forKey: .selectedFieldIds) ?? []
        self.customLabels = try c.decodeIfPresent([String: String].self, forKey: .customLabels) ?? [:]
        // Lossy per entry: a style this build doesn't know falls back to the
        // default instead of discarding the settings blob.
        let rawStyles = try c.decodeIfPresent([String: String].self, forKey: .fieldStyles) ?? [:]
        self.fieldStyles = rawStyles.compactMapValues(MenuBarFieldStyle.init(rawValue:))
        // Absent in every settings file written before segment merging existed;
        // off is the layout those bars were arranged against.
        self.mergesGroupWindows = try c.decodeIfPresent(Bool.self, forKey: .mergesGroupWindows) ?? false
        // Absent for every item that predates the composer, and lossy on
        // purpose: an unreadable strip falls back to the field-based bar
        // instead of taking the whole settings file down.
        self.composition = try? c.decodeIfPresent(MenuBarComposition.self, forKey: .composition)
        // Absent before saved segments existed, and lossy per entry for the same
        // reason the strip is: one unreadable preset must not cost the rest of
        // the library, let alone the item around it.
        let storedPresets = (try? c.decodeIfPresent([LossyMenuBarSegmentPreset].self, forKey: .segmentPresets))
            .flatMap { $0 } ?? []
        self.segmentPresets = storedPresets.compactMap(\.value)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(isVisible, forKey: .isVisible)
        try c.encode(layout, forKey: .layout)
        try c.encode(selectedFieldIds, forKey: .selectedFieldIds)
        try c.encode(customLabels, forKey: .customLabels)
        try c.encode(fieldStyles, forKey: .fieldStyles)
        try c.encode(mergesGroupWindows, forKey: .mergesGroupWindows)
        try c.encodeIfPresent(composition, forKey: .composition)
        if !segmentPresets.isEmpty {
            try c.encode(segmentPresets, forKey: .segmentPresets)
        }
    }
}

/// Tolerant wrapper for one saved group. See `MenuBarItemSettings.segmentPresets`.
private struct LossyMenuBarSegmentPreset: Codable {
    let value: MenuBarSegmentPreset?

    init(from decoder: Decoder) throws {
        self.value = try? MenuBarSegmentPreset(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value?.encode(to: encoder)
    }
}

public struct MenuBarFieldOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var tool: ToolType
    public var bucketId: String
    public var title: String
    public var defaultLabel: String
    /// For a runtime-discovered field: the L3 group title its live bucket
    /// carried when it was recorded. Static catalog entries leave it nil —
    /// their grouping is the hand-maintained tables.
    public var dynamicGroupTitle: String?
    /// True for fields synthesized from `QuotaFieldRegistry` rather than the
    /// static catalog.
    public var isDynamic: Bool

    public init(
        id: String,
        tool: ToolType,
        bucketId: String,
        title: String,
        defaultLabel: String,
        dynamicGroupTitle: String? = nil,
        isDynamic: Bool = false
    ) {
        self.id = id
        self.tool = tool
        self.bucketId = bucketId
        self.title = title
        self.defaultLabel = defaultLabel
        self.dynamicGroupTitle = dynamicGroupTitle
        self.isDynamic = isDynamic
    }
}

/// One L2 SubProvider slice of a company's selected quota fields: the tool
/// whose adapter produced the buckets, the SubProvider name shown between the
/// company header and the quota-group titles, and the fields underneath it in
/// catalog order.
///
/// The owning tool is part of the identity because one adapter can serve two
/// SubProviders — Grok Bot rides Cursor's (see `ToolType.quotaSubProviderName`).
/// The label as it is *shown*, rather than as the naming contract spells it.
///
/// `title` is a quota-axis value — `docs/contracts/quota-naming-v1.json` —
/// and stays English wherever it is stored or compared. Only the rendered
/// form goes through `QuotaGroupLabelLocalizer`, and a label has several
/// readers: the field picker, the rename dialog's placeholder, the menu-bar
/// composer. Each one that reads `title` raw is a Chinese screen with an
/// English quota name on it, which is how the first two were found.
///
/// A composed title ("All Models · Weekly") is resolved part by part, so
/// "GPT-5.3 Codex Spark · 5 Hours" keeps its product name and translates
/// only the window.
///
/// Spelled to match the definition on the menu-bar composer branch, which
/// adds the same two properties: whichever lands second resolves a trivial
/// conflict instead of the app growing two names for one seam.
extension MenuBarFieldOption {
    public var displayTitle: String {
        title
            .components(separatedBy: " · ")
            .map(QuotaGroupLabelLocalizer.display)
            .joined(separator: " · ")
    }

    /// The short name, resolved the same way.
    public var displayDefaultLabel: String {
        QuotaGroupLabelLocalizer.display(defaultLabel)
    }
}

public struct MenuBarSubProviderGroup: Equatable, Sendable, Identifiable {
    public let tool: ToolType
    public let name: String
    public var fields: [MenuBarFieldOption]

    public init(tool: ToolType, name: String, fields: [MenuBarFieldOption]) {
        self.tool = tool
        self.name = name
        self.fields = fields
    }

    public var id: String { "\(tool.rawValue)/\(name)" }

    public var fieldIds: [String] { fields.map(\.id) }

    public var bucketIds: [String] { fields.map(\.bucketId) }
}

/// One L1 company column. Consecutive tools sharing a `vendorName` fold into
/// a single group (Gemini Web + AntiGravity → Google AI; Grok + Cursor →
/// SpaceXAI), each contributing one or more SubProviders.
public struct MenuBarCompanyFieldGroup: Equatable, Sendable, Identifiable {
    public let company: String
    public let accentTool: ToolType
    public var subProviders: [MenuBarSubProviderGroup]

    public init(company: String, accentTool: ToolType, subProviders: [MenuBarSubProviderGroup]) {
        self.company = company
        self.accentTool = accentTool
        self.subProviders = subProviders
    }

    public var id: String { company }
}

public enum MenuBarFieldCatalog {
    public static let codexFields: [MenuBarFieldOption] = [
        option(.codex, "five_hour", "5 Hours", "5 Hours"),
        option(.codex, "weekly", "Weekly", "Weekly"),
        option(.codex, "gpt_5_3_codex_spark_five_hour", "GPT-5.3 Codex Spark · 5 Hours", "Spark 5 Hours"),
        option(.codex, "gpt_5_3_codex_spark_weekly", "GPT-5.3 Codex Spark · Weekly", "Spark Weekly")
    ]

    public static let claudeFields: [MenuBarFieldOption] = [
        option(.claude, "five_hour", "5 Hours", "5 Hours"),
        option(.claude, "weekly", "All Models · Weekly", "Weekly"),
        option(.claude, "weekly_sonnet", "Sonnet · Weekly", "Sonnet Weekly"),
        option(.claude, "weekly_design", "Designs · Weekly", "Design Weekly"),
        option(.claude, "daily_routines", "Daily Routines", "Routines"),
        option(.claude, "weekly_opus", "Opus · Weekly", "Opus Weekly"),
        option(.claude, "weekly_fable", "Fable · Weekly", "Fable Weekly"),
        option(.claude, "weekly_oauth_apps", "OAuth Apps · Weekly", "OAuth Weekly")
    ]

    // Gemini Web (`gemini.google.com`) exposes a 5-hour rolling
    // window and a weekly bucket — that's the entire quota surface
    // the Gemini Web quota parser returns, regardless of model. Earlier
    // entries here were per-model CLI ids (Gemini 2.5 Pro / Flash /
    // Lite, Gemini 3 Pro / Flash) from the pre-PR-#45 telemetry
    // adapter the Web parser no longer produces; those ids get
    // migrated to the new pair in `fieldIdMigrations` below.
    public static let geminiFields: [MenuBarFieldOption] = [
        option(.gemini, "five_hour", "5 Hours", "5 Hours"),
        option(.gemini, "weekly", "Weekly", "Weekly")
    ]

    public static let antigravityFields: [MenuBarFieldOption] = [
        option(.antigravity, "gemini_five_hour", "Gemini Models · 5 Hours", "Gemini 5 Hours"),
        option(.antigravity, "gemini_weekly", "Gemini Models · Weekly", "Gemini Weekly"),
        option(.antigravity, "claude_gpt_five_hour", "Claude and GPT Models · 5 Hours", "Claude + GPT 5 Hours"),
        option(.antigravity, "claude_gpt_weekly", "Claude and GPT Models · Weekly", "Claude + GPT Weekly")
    ]

    public static let grokFields: [MenuBarFieldOption] = [
        option(.grok, "weekly", "Weekly Credits", "Weekly")
    ]

    public static let cursorFields: [MenuBarFieldOption] = [
        option(.cursor, "models", "Cursor Models · Monthly", "Cursor Models"),
        option(.cursor, "other_models", "Other Models · Monthly", "Other Models")
    ]

    /// Grok Bot rides Cursor's adapter but is its own L2 SubProvider (see
    /// `ToolType.quotaSubProviderName`), so it gets its own catalog slice and
    /// its own section header instead of hiding under "Cursor". The field id
    /// is unchanged — this is a regrouping, not a migration.
    public static let grokBotFields: [MenuBarFieldOption] = [
        option(.cursor, "grok_bot_weekly", "Grok Bot · Weekly", "Grok Bot")
    ]

    public static let allFields: [MenuBarFieldOption] =
        codexFields + claudeFields + geminiFields + antigravityFields
            + grokFields + cursorFields + grokBotFields

    public static func fields(for kind: MenuBarItemKind) -> [MenuBarFieldOption] {
        allFields
    }

    public static func field(id: String) -> MenuBarFieldOption? {
        allFields.first { $0.id == id }
    }

    public static func fieldId(tool: ToolType, bucketId: String) -> String {
        "\(tool.rawValue).\(bucketId)"
    }

    /// Buckets the selected quota fields into the three tiers of the quota
    /// naming axis — L1 company → L2 SubProvider → L3 quota bucket — walking
    /// `tools` in the order given and `allFields` in catalog order.
    ///
    /// This is the shape the mini window renders: one column per company, one
    /// labelled section per SubProvider, gauges underneath. A single tool can
    /// contribute more than one SubProvider (Cursor → Cursor + Grok Bot) and
    /// several tools can share one company (Gemini Web + AntiGravity). Tools
    /// and SubProviders with nothing selected are dropped, so the result never
    /// describes an empty column.
    ///
    /// Pure and adapter-free on purpose: the SwiftUI layout and the AppKit
    /// panel-sizing code both need the same grouping, and they must not
    /// disagree. See `AGENTS.md` § 7.1.
    public static func subProviderGroups(
        for tools: [ToolType],
        selectedFieldIds: Set<String>
    ) -> [MenuBarCompanyFieldGroup] {
        var groups: [MenuBarCompanyFieldGroup] = []
        for tool in tools {
            var subProviders: [MenuBarSubProviderGroup] = []
            var indexByName: [String: Int] = [:]
            for field in allFields
            where field.tool == tool && selectedFieldIds.contains(field.id) {
                let name = tool.quotaSubProviderName(bucketID: field.bucketId)
                if let index = indexByName[name] {
                    subProviders[index].fields.append(field)
                } else {
                    indexByName[name] = subProviders.count
                    subProviders.append(
                        MenuBarSubProviderGroup(tool: tool, name: name, fields: [field])
                    )
                }
            }
            guard !subProviders.isEmpty else { continue }
            if let last = groups.last, last.company == tool.vendorName {
                groups[groups.count - 1].subProviders.append(contentsOf: subProviders)
            } else {
                groups.append(
                    MenuBarCompanyFieldGroup(
                        company: tool.vendorName,
                        accentTool: tool,
                        subProviders: subProviders
                    )
                )
            }
        }
        return groups
    }

    public static func migratedFieldIds(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for id in ids {
            let resolved = fieldIdMigrations[id] ?? [id]
            for candidate in resolved where seen.insert(candidate).inserted {
                out.append(candidate)
            }
        }
        return out
    }

    public static func migratedCustomLabels(_ labels: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (id, label) in labels {
            let resolved = fieldIdMigrations[id] ?? [id]
            guard resolved.count == 1, let migratedId = resolved.first else { continue }
            out[migratedId] = label
        }
        return out
    }

    private static func option(
        _ tool: ToolType,
        _ bucketId: String,
        _ title: String,
        _ defaultLabel: String
    ) -> MenuBarFieldOption {
        MenuBarFieldOption(
            id: fieldId(tool: tool, bucketId: bucketId),
            tool: tool,
            bucketId: bucketId,
            title: title,
            defaultLabel: defaultLabel
        )
    }

    private static let fieldIdMigrations: [String: [String]] = [
        // Old Gemini CLI per-model fields all roll up to the Web
        // parser's two-bucket pair. We collapse them to a single
        // `gemini.five_hour` since users selecting one model
        // generally cared about a primary quota indicator; the
        // Weekly bucket is right next to it in the catalog.
        "gemini.gemini_pro":             ["gemini.five_hour"],
        "gemini.gemini_flash":           ["gemini.five_hour"],
        "gemini.gemini_flash_lite":      ["gemini.five_hour"],
        "gemini.gemini-2.5-pro":         ["gemini.five_hour"],
        "gemini.gemini-2.5-flash":       ["gemini.five_hour"],
        "gemini.gemini-2.5-flash-lite":  ["gemini.five_hour"],
        "gemini.gemini-3-pro":           ["gemini.five_hour"],
        "gemini.gemini-3-flash":         ["gemini.five_hour"],
        // Antigravity 2.x reports two shared pools, each with a 5-hour
        // and weekly lane. Every legacy per-model selection therefore
        // migrates to the matching pool's 5-hour lane; the weekly lane
        // remains independently selectable beside it.
        "antigravity.claude-sonnet-4-20250514": ["antigravity.claude_gpt_five_hour"],
        "antigravity.claude-sonnet-4-5": ["antigravity.claude_gpt_five_hour"],
        "antigravity.claude-sonnet-4.6-thinking": ["antigravity.claude_gpt_five_hour"],
        "antigravity.claude-opus-4.6-thinking": ["antigravity.claude_gpt_five_hour"],
        "antigravity.gpt-oss-120b-medium": ["antigravity.claude_gpt_five_hour"],
        "antigravity.gemini-2.5-pro": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-3-pro": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-3.1-pro-high": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-3.1-pro-low": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-2.5-flash": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-3-flash": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-3.5-flash-high": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-3.5-flash-medium": ["antigravity.gemini_five_hour"],
        "antigravity.gemini-2.5-flash-lite": ["antigravity.gemini_five_hour"],
        "grok.monthly": ["grok.weekly"]
    ]
}
