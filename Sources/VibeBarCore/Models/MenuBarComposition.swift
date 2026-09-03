import Foundation

// MARK: - Metric

/// What one quota token prints. Every case renders a *short* string — the
/// menu bar is the most width-constrained surface in the app — and every
/// format below is exact, because two clients and a screen reader all have to
/// agree on it.
///
/// | Metric             | Renders                | Example        | Renders nothing when |
/// | ------------------ | ---------------------- | -------------- | -------------------- |
/// | `usedPercent`      | `<n>%`                 | `73%`          | never (quota present) |
/// | `remainingPercent` | `<n>%`                 | `27%`          | never (quota present) |
/// | `displayPercent`   | `<n>%`                 | `27%` / `73%`  | never (quota present) |
/// | `pace`             | `+<n>%` / `-<n>%` / `±0%` | `+12%`      | no window or no reset |
/// | `forecastPercent`  | `<n>%`                 | `18%`          | no forecast yet       |
/// | `resetsIn`         | compact countdown      | `3h 16m`       | no reset date         |
/// | `resetAt`          | local wall time        | `18:30`        | no reset date         |
/// | `runsOutIn`        | compact countdown      | `2d 4h`        | not projected to run out |
/// | `label`            | the quota's own name   | `5 Hours`      | never (quota present) |
///
/// `usedPercent` / `remainingPercent` are the raw observation. `displayPercent`
/// is the provider-normalized number every other surface shows (Cursor rounds
/// any positive sub-1% pool up to 1%) and follows the app's Used/Remaining
/// setting, so a token set to it tracks whatever the user picked.
///
/// `pace` is the signed distance from the linear expectation — `+12%` means
/// twelve points *ahead* of where a flat burn would be, i.e. burning fast.
/// `forecastPercent` is the median projected quota **left at reset**, the same
/// number the Overview says "forecast N% left" about.
/// The two countdowns use `ResetCountdownFormatter`: `5d`, `2d 4h`, `3h 16m`,
/// `12m`, `<1m`, `now`.
public enum MenuBarQuotaMetric: String, Codable, CaseIterable, Sendable {
    case usedPercent
    case remainingPercent
    case displayPercent
    case pace
    case forecastPercent
    case resetsIn
    case resetAt
    case runsOutIn
    case label

    /// Menu label for the stage-2 editor's metric picker.
    public var title: String {
        switch self {
        case .usedPercent: return "Used %"
        case .remainingPercent: return "Remaining %"
        case .displayPercent: return "Percent (follows setting)"
        case .pace: return "Pace"
        case .forecastPercent: return "Forecast at reset"
        case .resetsIn: return "Resets in"
        case .resetAt: return "Resets at"
        case .runsOutIn: return "Runs out in"
        case .label: return "Name"
        }
    }

    /// Whether this metric needs the (expensive) personal forecast computed
    /// for its bucket. Drives `MenuBarComposition.quotaRequirements`.
    var needsForecast: Bool {
        switch self {
        case .forecastPercent, .runsOutIn: return true
        default: return false
        }
    }

    /// Whether the string this metric renders goes stale on its own, with no
    /// new data — a countdown ticks down between refreshes, an absolute reset
    /// time re-words itself once it crosses a day boundary, and pace drifts
    /// because the expectation it is measured against advances with the clock.
    /// A strip containing one of these needs a clock; a strip without one must
    /// not start a timer at all.
    public var isTimeBased: Bool {
        switch self {
        case .resetsIn, .resetAt, .runsOutIn, .pace: return true
        default: return false
        }
    }
}

// MARK: - Token

/// One block in a composed menu-bar strip.
///
/// The identity is a `UUID` rather than the content so the stage-2 editor can
/// drag, duplicate, and undo blocks that happen to render identically — two
/// `.text("·")` separators are two blocks, not one.
public struct MenuBarToken: Identifiable, Codable, Hashable, Sendable {
    /// What the block is.
    public enum Kind: Hashable, Sendable {
        /// A provider's brand mark, tinted like the surrounding text unless
        /// the style says otherwise. Any provider, not just the ones the user
        /// selected as quota fields.
        case logo(ToolType)
        /// Literal words the user typed.
        case text(String)
        /// One number (or name, or countdown) read off a live quota bucket.
        /// `fieldId` is a `MenuBarFieldCatalog` id — `"claude.five_hour"`.
        case quota(fieldId: String, metric: MenuBarQuotaMetric)
        /// Blank space, one base-font space glyph wide.
        case space
        /// A literal divider the user chose — `" · "`, `"/"`, `"|"`.
        case separator(String)
        /// Vibe Bar's own glyph — what the Icon Only layout draws, and the
        /// only mark on the strip that is not a provider's. Without it the
        /// composer could not seed an Icon Only item with what the user is
        /// actually looking at.
        case appIcon
        /// Ends the current row and starts the next one. Never draws.
        case lineBreak
    }

    /// How the block looks. Colour is the interesting axis: any block — a
    /// logo, a word, a number — may follow a quota's live colour, which is
    /// what makes "the label goes red with the number" expressible.
    public struct Style: Codable, Hashable, Sendable {
        public var color: ColorSource
        public var size: SizeStep
        public var weight: Weight
        public var monospacedDigits: Bool

        public init(
            color: ColorSource = .automatic,
            size: SizeStep = .regular,
            weight: Weight = .medium,
            monospacedDigits: Bool = false
        ) {
            self.color = color
            self.size = size
            self.weight = weight
            self.monospacedDigits = monospacedDigits
        }

        /// What today's percentages wear: automatic colour, semibold,
        /// monospaced digits so a changing number does not jiggle the strip.
        public static let percent = Style(
            color: .automatic,
            size: .regular,
            weight: .semibold,
            monospacedDigits: true
        )

        /// What today's labels wear.
        public static let label = Style(color: .primary, size: .regular, weight: .medium)

        /// What today's " · " dividers wear.
        public static let divider = Style(color: .tertiary, size: .regular, weight: .regular)
    }

    public enum ColorSource: Hashable, Sendable {
        /// Exactly what the strip does today: the token's own quota coloured
        /// under `AppSettings.menuBarColorBasis`. A token with no quota of its
        /// own is `.primary`.
        case automatic
        /// The token's own quota's forecast verdict colour, regardless of the
        /// app-wide basis. `.primary` for a token with no quota.
        case forecast
        /// Follow *another* quota's live colour — the way a text label can go
        /// red in step with the number beside it.
        case followsQuota(fieldId: String, basis: MenuBarColorBasis)
        /// The provider's accent from the shared brand table.
        case brand(ToolType)
        case primary
        case secondary
        case tertiary
        /// A literal colour. Always store the normalized `#rrggbb` /
        /// `#rrggbbaa` form — build it with `hex(_:)` rather than writing the
        /// case directly, so `#FF8000` and `#ff8000` are one value rather than
        /// two that survive a round trip differently.
        case fixed(String)

        /// `.fixed` with the string canonicalized, or `.primary` when the
        /// string is not a colour. The colour well in stage 2's editor and the
        /// decoder both go through here, so a hand-edited settings file and a
        /// picked swatch land on the same value.
        public static func hex(_ raw: String) -> ColorSource {
            guard let normalized = MenuBarHexColor.normalized(raw) else { return .primary }
            return .fixed(normalized)
        }
    }

    public enum SizeStep: String, Codable, CaseIterable, Sendable {
        case small
        case regular
        case large

        /// Multiplier on the row's base font size.
        public var multiplier: Double {
            switch self {
            case .small: return 0.85
            case .regular: return 1.0
            case .large: return 1.2
            }
        }

        public var title: String {
            switch self {
            case .small: return "Small"
            case .regular: return "Regular"
            case .large: return "Large"
            }
        }
    }

    public enum Weight: String, Codable, CaseIterable, Sendable {
        case regular
        case medium
        case semibold

        public var title: String {
            switch self {
            case .regular: return "Regular"
            case .medium: return "Medium"
            case .semibold: return "Semibold"
            }
        }
    }

    /// When the block is on screen at all.
    ///
    /// A rule that cannot be evaluated — it names a quota this build has never
    /// heard of, the provider stopped returning it, or it asks about a
    /// forecast that has not converged — resolves to *visible*. Hiding a block
    /// because its condition is unknowable is indistinguishable from the app
    /// being broken, and the user would have no way to find the block again.
    public enum Visibility: Hashable, Sendable {
        case always
        case whenUsedAtLeast(fieldId: String, percent: Double)
        case whenRemainingAtMost(fieldId: String, percent: Double)
        case whenForecast(fieldId: String, verdicts: Set<QuotaPaceForecast.Verdict>)

        /// The quota this rule watches, if any.
        public var fieldId: String? {
            switch self {
            case .always: return nil
            case let .whenUsedAtLeast(fieldId, _),
                 let .whenRemainingAtMost(fieldId, _):
                return fieldId
            case let .whenForecast(fieldId, _):
                return fieldId
            }
        }

        var needsForecast: Bool {
            if case .whenForecast = self { return true }
            return false
        }
    }

    /// How many characters a `.text` or `.separator` block draws before it is
    /// cut short. The menu bar is shared with every other status item on the
    /// machine, and a block with no ceiling can push the clock off screen —
    /// so the ceiling lives here rather than in whichever editor happens to
    /// be typing into it.
    public static let maximumTextLength = 24

    /// The drawn form of a block's literal text: at most
    /// `maximumTextLength` characters, the last of which becomes an ellipsis
    /// when anything was dropped. Spoken descriptions keep the full string —
    /// truncation is a drawing constraint, not a change to what the user
    /// wrote.
    public static func truncated(_ text: String) -> String {
        guard text.count > maximumTextLength else { return text }
        return text.prefix(maximumTextLength - 1) + "…"
    }

    public var id: UUID
    public var kind: Kind
    public var style: Style
    public var visibility: Visibility

    public init(
        id: UUID = UUID(),
        kind: Kind,
        style: Style = Style(),
        visibility: Visibility = .always
    ) {
        self.id = id
        self.kind = kind
        self.style = style
        self.visibility = visibility
    }

    /// The quota this token reads, if it is a quota token.
    public var quotaFieldId: String? {
        if case let .quota(fieldId, _) = kind { return fieldId }
        return nil
    }

    public var metric: MenuBarQuotaMetric? {
        if case let .quota(_, metric) = kind { return metric }
        return nil
    }
}

// MARK: - Composition

/// A composed menu-bar strip: a template, an ordered token list, and two
/// optional overrides for the template's spacing and scale.
///
/// `isEnabled` is deliberately inside the composition rather than being
/// modelled as "composition == nil": switching back to the plain field-based
/// strip must not throw away an arrangement the user built, and switching
/// back must not reseed over it. `MenuBarItemSettings.composition == nil`
/// therefore means "never opened the composer", not "composer off".
public struct MenuBarComposition: Codable, Equatable, Sendable {
    /// Starting points. A template is only a set of defaults — every one of
    /// them is a plain token list afterwards, and the user can edit it into
    /// any of the others.
    public enum Template: String, Codable, CaseIterable, Sendable {
        /// Tight and small: fits the most quotas in a crowded menu bar.
        case compact
        /// Today's proportions, with breathing room between blocks.
        case roomy
        /// Two stacked rows, drawn by the same rasterizer the two-row layout
        /// uses. Seeds with a `.lineBreak` in the middle.
        case twoColumn

        public var title: String {
            switch self {
            case .compact: return "Compact"
            case .roomy: return "Roomy"
            case .twoColumn: return "Two rows"
            }
        }

        public var detail: String {
            switch self {
            case .compact: return "Tight spacing and a slightly smaller face."
            case .roomy: return "Today's size, with more air between blocks."
            case .twoColumn: return "Two stacked rows in one status item."
            }
        }

        /// Gap between adjacent blocks, as a multiplier on the row's base font
        /// size. Realized as a space glyph, exactly the way the existing
        /// logo-to-label gap already is — a text attachment would inflate the
        /// line box and push the second row out of the bar.
        public var tokenSpacing: Double {
            switch self {
            case .compact: return 0.35
            case .roomy: return 0.9
            case .twoColumn: return 0.8
            }
        }

        /// Multiplier on the layout's base font size.
        public var fontScale: Double {
            switch self {
            case .compact: return 0.95
            case .roomy: return 1.0
            case .twoColumn: return 1.0
            }
        }

        var seedsSecondRow: Bool { self == .twoColumn }

        /// The template whose proportions match a field-mode layout, so
        /// seeding from that layout starts with matching spacing as well as
        /// matching content.
        public static func matching(_ layout: MenuBarLayout) -> Template {
            switch layout {
            case .twoRows: return .twoColumn
            case .compact: return .compact
            case .singleLine, .iconOnly: return .roomy
            }
        }
    }

    /// The status item is ~22pt tall: two rows is the most the rasterizer can
    /// fit legibly, so a third `.lineBreak` is ignored and its blocks continue
    /// on the second row. Stage 2's editor should stop offering a break past
    /// this rather than letting the user build a row that cannot appear.
    public static let maximumRows = 2

    public static let fontScaleRange: ClosedRange<Double> = 0.6...1.6
    public static let tokenSpacingRange: ClosedRange<Double> = 0...4

    public var isEnabled: Bool
    public var template: Template
    public var tokens: [MenuBarToken]
    /// Overrides `template.fontScale` when set.
    public var fontScale: Double?
    /// Overrides `template.tokenSpacing` when set.
    public var tokenSpacing: Double?

    public init(
        isEnabled: Bool = false,
        template: Template = .roomy,
        tokens: [MenuBarToken] = [],
        fontScale: Double? = nil,
        tokenSpacing: Double? = nil
    ) {
        self.isEnabled = isEnabled
        self.template = template
        self.tokens = tokens
        self.fontScale = fontScale.map { $0.clamped(to: Self.fontScaleRange) }
        self.tokenSpacing = tokenSpacing.map { $0.clamped(to: Self.tokenSpacingRange) }
    }

    public var effectiveFontScale: Double { fontScale ?? template.fontScale }
    public var effectiveTokenSpacing: Double { tokenSpacing ?? template.tokenSpacing }

    /// Every quota this strip touches — through a token, a colour that follows
    /// a quota, or a visibility rule — in first-appearance order, deduplicated.
    ///
    /// The renderer resolves exactly these once per render. Without it a strip
    /// that names one bucket in three tokens would look that bucket up (and
    /// forecast it) three times inside the 120 ms throttle.
    public var referencedFieldIds: [String] {
        quotaRequirements.map(\.fieldId)
    }

    /// Per-quota work the renderer must do, in `referencedFieldIds` order.
    /// The forecast is the expensive one — only ask for it where a token, a
    /// colour, or a rule actually reads it.
    public var quotaRequirements: [MenuBarQuotaRequirement] {
        // Linear rather than a dictionary on purpose: this runs inside the
        // menu bar's 120 ms render throttle, and a status item holds a handful
        // of quotas at most — scanning that array beats allocating a hash
        // table every tick.
        var out: [MenuBarQuotaRequirement] = []
        func requirement(_ fieldId: String, forecast: Bool) {
            if let position = out.firstIndex(where: { $0.fieldId == fieldId }) {
                out[position].needsForecast = out[position].needsForecast || forecast
            } else {
                out.append(MenuBarQuotaRequirement(fieldId: fieldId, needsForecast: forecast))
            }
        }
        for token in tokens {
            if let fieldId = token.quotaFieldId, let metric = token.metric {
                requirement(fieldId, forecast: metric.needsForecast)
            }
            // A colour that follows the block's own quota names no field, so
            // it has to be attributed here or nobody ever asks for its verdict.
            if token.style.color.followsOwnQuota, let fieldId = token.quotaFieldId {
                requirement(fieldId, forecast: token.style.color.needsForecast)
            }
            if let fieldId = token.style.color.fieldId {
                requirement(fieldId, forecast: token.style.color.needsForecast)
            }
            if let fieldId = token.visibility.fieldId {
                requirement(fieldId, forecast: token.visibility.needsForecast)
            }
        }
        return out
    }

    // MARK: Editing
    //
    // List surgery lives here rather than in the editor: the view that drags a
    // chip should not also be the thing that decides what dropping it means,
    // and none of this is testable once it is tangled with a gesture.

    public func index(of id: UUID) -> Int? {
        tokens.firstIndex { $0.id == id }
    }

    public func token(_ id: UUID) -> MenuBarToken? {
        tokens.first { $0.id == id }
    }

    /// Insert at `index`, clamped into range so a drop past either end lands
    /// at that end instead of trapping.
    public mutating func insert(_ token: MenuBarToken, at index: Int) {
        tokens.insert(token, at: Swift.max(0, Swift.min(index, tokens.count)))
    }

    public mutating func append(_ token: MenuBarToken) {
        tokens.append(token)
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard let index = index(of: id) else { return false }
        tokens.remove(at: index)
        return true
    }

    /// Copy a block in place, directly after the original. The copy is a new
    /// block, so it gets a new identity — two blocks that render identically
    /// are still two blocks the editor can drag apart.
    /// Returns the copy's id so the editor can select what it just made.
    @discardableResult
    public mutating func duplicate(_ id: UUID) -> UUID? {
        guard let index = index(of: id) else { return nil }
        var copy = tokens[index]
        copy.id = UUID()
        tokens.insert(copy, at: index + 1)
        return copy.id
    }

    /// Move `id` so it ends up at `index` in the *resulting* list.
    ///
    /// Stated in terms of the result rather than the source array on purpose:
    /// "insert before element N" changes meaning halfway through a drag once
    /// the dragged block has been lifted out, which is where reorder
    /// off-by-ones come from.
    public mutating func move(_ id: UUID, to index: Int) {
        guard let from = self.index(of: id) else { return }
        let token = tokens.remove(at: from)
        tokens.insert(token, at: Swift.max(0, Swift.min(index, tokens.count)))
    }

    /// Move `id` to sit immediately before `target`. No-op when they are the
    /// same block.
    public mutating func move(_ id: UUID, before target: UUID) {
        guard id != target, let destination = index(of: target) else { return }
        let from = index(of: id)
        // Dragging rightwards past the target lands *on* it once the source
        // has been lifted out; dragging leftwards lands in front of it.
        move(id, to: (from.map { $0 < destination } ?? false) ? destination - 1 : destination)
    }

    public var lineBreakCount: Int {
        tokens.reduce(0) { $0 + ($1.kind == .lineBreak ? 1 : 0) }
    }

    /// Whether another row can still be drawn. Past this the editor must stop
    /// offering a break rather than letting the user build a row that the
    /// status item silently folds away — see `maximumRows`.
    public var canAddLineBreak: Bool {
        lineBreakCount < Self.maximumRows - 1
    }

    // MARK: Availability

    /// Which blocks are held back by a quota that is not answering right now.
    ///
    /// The editor needs this to explain a strip that looks wrong: a block that
    /// draws nothing looks identical to a block the user mis-configured, and
    /// only the app knows which quotas the providers are actually returning.
    public struct Availability: Equatable, Sendable {
        /// Blocks that draw nothing at all — a quota block whose bucket is
        /// missing.
        public var silentTokenIds: Set<UUID>
        /// Blocks that still draw but lost something: a colour that follows a
        /// missing quota, or a rule that cannot be evaluated and so no longer
        /// gates anything.
        public var degradedTokenIds: Set<UUID>
        /// Every referenced quota that is not available, in first-reference
        /// order.
        public var missingFieldIds: [String]

        public init(
            silentTokenIds: Set<UUID> = [],
            degradedTokenIds: Set<UUID> = [],
            missingFieldIds: [String] = []
        ) {
            self.silentTokenIds = silentTokenIds
            self.degradedTokenIds = degradedTokenIds
            self.missingFieldIds = missingFieldIds
        }

        public var isFullyAvailable: Bool { missingFieldIds.isEmpty }
    }

    /// Whether any block prints something that goes stale on the clock.
    ///
    /// The renderer uses this to decide whether to run a countdown timer at
    /// all: a strip of percentages redraws when a refresh lands and must not
    /// cost a wakeup a minute for the rest of the day.
    public var hasTimeBasedBlock: Bool {
        tokens.contains { $0.metric?.isTimeBased == true }
    }

    /// Whether the strip shows anything derived from the personal forecast.
    ///
    /// Three different things make a strip forecast-driven and only one of
    /// them is a metric, which is why classifying on metrics alone left the
    /// other two stale until the next refresh:
    ///
    /// - a `.forecastPercent` or `.runsOutIn` **block**,
    /// - a `.whenForecast` **visibility rule**, which decides whether a block
    ///   is on screen at all,
    /// - a **colour** that follows a forecast — either explicitly, or
    ///   `.automatic` when the app-wide basis *is* the forecast, which is the
    ///   colour every seeded percentage wears.
    ///
    /// `QuotaService` recomputes forecasts on its own five-minute grid, so a
    /// strip like this needs a tick of its own; the refresh interval can be
    /// half an hour.
    public func needsForecastClock(colorBasis: MenuBarColorBasis) -> Bool {
        tokens.contains { token in
            if token.metric?.needsForecast == true { return true }
            if token.visibility.needsForecast { return true }
            if token.style.color.needsForecast { return true }
            return colorBasis == .forecast
                && token.style.color.followsOwnQuota
                && token.quotaFieldId != nil
        }
    }

    /// How often this strip has to be redrawn from nothing but the clock, or
    /// nil when it never does.
    ///
    /// A minute when anything counts down, otherwise the forecast's own
    /// quantum. A strip that needs both is served by the faster tick — the
    /// forecast is memoised on its five-minute grid, so the extra passes hit
    /// the memo rather than recomputing.
    public func clockInterval(colorBasis: MenuBarColorBasis) -> TimeInterval? {
        if hasTimeBasedBlock { return MenuBarCountdownClock.interval }
        if needsForecastClock(colorBasis: colorBasis) {
            return MenuBarCountdownClock.forecastInterval
        }
        return nil
    }

    public func availability(liveFieldIds: Set<String>) -> Availability {
        var result = Availability()
        for token in tokens {
            if let fieldId = token.quotaFieldId, !liveFieldIds.contains(fieldId) {
                result.silentTokenIds.insert(token.id)
                if !result.missingFieldIds.contains(fieldId) {
                    result.missingFieldIds.append(fieldId)
                }
            }
            for fieldId in [token.style.color.fieldId, token.visibility.fieldId] {
                guard let fieldId, !liveFieldIds.contains(fieldId) else { continue }
                // A silent block is already reported; do not also call it
                // degraded, which would show the user two warnings for one
                // cause.
                if !result.silentTokenIds.contains(token.id) {
                    result.degradedTokenIds.insert(token.id)
                }
                if !result.missingFieldIds.contains(fieldId) {
                    result.missingFieldIds.append(fieldId)
                }
            }
        }
        return result
    }

    // MARK: Seeding

    /// A token list that renders what `item` renders today, so turning the
    /// composer on starts from what the user is already looking at rather than
    /// from a blank bar.
    ///
    /// Walks the same runs the field path walks — merged group windows seed as
    /// one label with slash-joined percentages — and reproduces each field's
    /// `MenuBarFieldStyle`: a logo block where the style shows a logo, a text
    /// block where it shows a label, then one `.displayPercent` block per
    /// window in `.automatic` colour, which is the colour the strip is using
    /// for that number right now.
    /// `groupCatalogLabel` is the mini window's group-label table, which lives
    /// in the App target. Pass it and a merged group seeds with the same word
    /// the strip prints today ("Spark"); omit it and the seed falls back to
    /// the SubProvider name.
    public static func seeded(
        template: Template,
        from item: MenuBarItemSettings,
        registry: QuotaFieldRegistry = .empty,
        groupCatalogLabel: (String) -> String? = { _ in nil }
    ) -> MenuBarComposition {
        MenuBarComposition(
            isEnabled: false,
            template: template,
            tokens: seedTokens(
                template: template,
                item: item,
                registry: registry,
                groupCatalogLabel: groupCatalogLabel
            )
        )
    }

    private static func seedTokens(
        template: Template,
        item: MenuBarItemSettings,
        registry: QuotaFieldRegistry,
        groupCatalogLabel: (String) -> String?
    ) -> [MenuBarToken] {
        // Icon Only draws one glyph and nothing else — not the selected
        // fields, which it ignores entirely. Expanding them here would greet
        // the user with a four-quota strip they have never seen, which is the
        // opposite of "start from what you already have".
        if item.layout == .iconOnly {
            return [MenuBarToken(kind: .appIcon, style: .label)]
        }

        let fields = item.selectedFieldIds.compactMap {
            MenuBarFieldCatalog.field(id: $0, registry: registry)
        }
        let runs = MenuBarFieldCatalog.runs(fields, merging: item.mergesGroupWindows)
        var tokens: [MenuBarToken] = []

        if item.showTitle {
            tokens.append(MenuBarToken(kind: .text(item.kind.title), style: .label))
        }

        // What each renderer actually puts between two entries: Single line
        // appends a tertiary " · "; Compact appends a plain space; Two rows
        // packs entries into columns separated by `twoRowColumnSpacing` and
        // draws no divider at all. Seeding a dot into a Two rows strip put
        // punctuation on screen that the layout had never drawn, which is the
        // seed failing at its one job.
        let separator: MenuBarToken.Kind = item.layout == .singleLine
            ? .separator(" · ")
            : .space

        for (rowIndex, row) in seedRows(runs, item: item, template: template).enumerated() {
            if rowIndex > 0 { tokens.append(MenuBarToken(kind: .lineBreak)) }
            for (index, run) in row.enumerated() {
                if index > 0 {
                    tokens.append(MenuBarToken(kind: separator, style: .divider))
                }
                tokens.append(contentsOf: seedRunTokens(
                    run,
                    item: item,
                    groupCatalogLabel: groupCatalogLabel
                ))
            }
        }
        return tokens
    }

    /// How the seed splits runs across rows.
    ///
    /// The Two rows layout packs entries into two-cell columns, so its top row
    /// reads entries 0, 2, 4… and its bottom row 1, 3, 5…. Alternating here
    /// reproduces the reading order the user already has rather than cutting
    /// the list in half, which would move every entry.
    private static func seedRows(
        _ runs: [MenuBarFieldRun],
        item: MenuBarItemSettings,
        template: Template
    ) -> [[MenuBarFieldRun]] {
        let splits = item.layout == .twoRows || template.seedsSecondRow
        guard splits, runs.count > 1 else { return [runs] }
        var top: [MenuBarFieldRun] = []
        var bottom: [MenuBarFieldRun] = []
        for (index, run) in runs.enumerated() {
            if index.isMultiple(of: 2) { top.append(run) } else { bottom.append(run) }
        }
        return [top, bottom]
    }

    /// One entry: its logo and label where the field style shows them, then a
    /// percentage per window, slash-joined when the group is merged.
    private static func seedRunTokens(
        _ run: MenuBarFieldRun,
        item: MenuBarItemSettings,
        groupCatalogLabel: (String) -> String?
    ) -> [MenuBarToken] {
        var tokens: [MenuBarToken] = []
        let style = item.style(for: run.primary.id)
        if style != .labelAndPercent {
            tokens.append(MenuBarToken(kind: .logo(run.primary.tool), style: .label))
        }
        if style != .logoAndPercent {
            let label = run.isMerged
                ? MenuBarFieldCatalog.mergedGroupLabel(
                    for: run,
                    customLabels: item.customLabels,
                    groupCatalogLabel: groupCatalogLabel
                )
                : seedLabel(for: run.primary, customLabels: item.customLabels)
            tokens.append(MenuBarToken(kind: .text(label), style: .label))
        }
        for (offset, field) in run.fields.enumerated() {
            if offset > 0 {
                tokens.append(MenuBarToken(kind: .separator("/"), style: .divider))
            }
            tokens.append(MenuBarToken(
                kind: .quota(fieldId: field.id, metric: .displayPercent),
                style: .percent
            ))
        }
        return tokens
    }

    /// The catalog's default label, overridden by whatever the user renamed
    /// this field to for the menu bar. The live bucket's own short label wins
    /// at render time in the field path; a seed has no bucket in hand, so it
    /// captures the static name and the user can edit the text block after.
    private static func seedLabel(
        for field: MenuBarFieldOption,
        customLabels: [String: String]
    ) -> String {
        let custom = customLabels[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        return field.defaultLabel
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case template
        case tokens
        case fontScale
        case tokenSpacing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.template = (try? c.decodeIfPresent(Template.self, forKey: .template)) ?? .roomy
        // Lossy per token: a block kind a future build introduces is dropped
        // rather than taking the whole settings file down with it.
        let stored = try c.decodeIfPresent([LossyMenuBarToken].self, forKey: .tokens) ?? []
        self.tokens = stored.compactMap(\.value)
        self.fontScale = try c.decodeIfPresent(Double.self, forKey: .fontScale)
            .map { $0.clamped(to: Self.fontScaleRange) }
        self.tokenSpacing = try c.decodeIfPresent(Double.self, forKey: .tokenSpacing)
            .map { $0.clamped(to: Self.tokenSpacingRange) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(template, forKey: .template)
        try c.encode(tokens, forKey: .tokens)
        try c.encodeIfPresent(fontScale, forKey: .fontScale)
        try c.encodeIfPresent(tokenSpacing, forKey: .tokenSpacing)
    }
}

/// Tolerant wrapper so one unreadable block cannot discard a whole strip —
/// the same treatment `AppSettings` gives an unknown menu-bar item.
private struct LossyMenuBarToken: Codable {
    let value: MenuBarToken?

    init(from decoder: Decoder) throws {
        self.value = try? MenuBarToken(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value?.encode(to: encoder)
    }
}

/// What the renderer must resolve for one quota before it can build the plan.
public struct MenuBarQuotaRequirement: Equatable, Sendable {
    public var fieldId: String
    /// Some token, colour, or rule reads the personal forecast — the one
    /// genuinely expensive input. Pace is not here: it is arithmetic over
    /// numbers the snapshot already carries, so the planner does it at draw
    /// time and it advances with the clock instead of freezing at whatever the
    /// last refresh computed.
    public var needsForecast: Bool

    public init(fieldId: String, needsForecast: Bool) {
        self.fieldId = fieldId
        self.needsForecast = needsForecast
    }
}

// MARK: - Render inputs

/// One live quota, resolved by the App layer and handed to the planner.
///
/// Deliberately a value: the planner is pure, so every format and every
/// visibility decision below is testable without AppKit, a quota service, or
/// a running app — the same split `ResetHistoryComparison` uses.
public struct MenuBarQuotaSnapshot: Equatable, Sendable {
    /// The forecast half, present only where `quotaRequirements` asked for it.
    public struct Forecast: Equatable, Sendable {
        public var verdict: QuotaPaceForecast.Verdict
        /// Median projected quota left when the window refills.
        public var projectedRemainingPercent: Double
        public var runOutAt: Date?

        public init(
            verdict: QuotaPaceForecast.Verdict,
            projectedRemainingPercent: Double,
            runOutAt: Date? = nil
        ) {
            self.verdict = verdict
            self.projectedRemainingPercent = projectedRemainingPercent
            self.runOutAt = runOutAt
        }
    }

    public var fieldId: String
    public var tool: ToolType
    /// What this quota is called on the strip — the item's custom label if the
    /// user set one, else the live bucket's short label.
    public var label: String
    /// The raw observation, 0…100.
    public var usedPercent: Double
    /// Provider-normalized and already resolved against the app's Used /
    /// Remaining setting.
    public var displayPercent: Double
    public var resetAt: Date?
    /// The bucket's window length, so pace can be computed at draw time rather
    /// than frozen into the snapshot.
    public var rawWindowSeconds: Int?
    public var forecast: Forecast?

    public init(
        fieldId: String,
        tool: ToolType,
        label: String,
        usedPercent: Double,
        displayPercent: Double,
        resetAt: Date? = nil,
        rawWindowSeconds: Int? = nil,
        forecast: Forecast? = nil
    ) {
        self.fieldId = fieldId
        self.tool = tool
        self.label = label
        self.usedPercent = usedPercent
        self.displayPercent = displayPercent
        self.resetAt = resetAt
        self.rawWindowSeconds = rawWindowSeconds
        self.forecast = forecast
    }

    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

// MARK: - Render plan

/// The colour a block ends up with, still as a role: the App owns the
/// `NSColor` translation, exactly as `MenuBarPercentColor` already arranges it.
public enum MenuBarTokenColorRole: Equatable, Sendable {
    /// Colour this block the way that quota's percentage is coloured, under
    /// `basis`. The planner only emits this for a quota it was given, so the
    /// renderer's lookup always succeeds.
    case quota(fieldId: String, basis: MenuBarColorBasis)
    case brand(ToolType)
    case primary
    case secondary
    case tertiary
    /// Normalized `#rrggbb` / `#rrggbbaa`.
    case fixed(hex: String)
}

/// One block, ready to draw.
public struct MenuBarRenderedToken: Equatable, Sendable, Identifiable {
    /// A mark rather than words: a provider's brand, or Vibe Bar's own icon.
    public enum Glyph: Equatable, Sendable {
        case provider(ToolType)
        case app
    }

    /// The source token's id, so stage 2's editor can map a hit test or a
    /// live preview back to the block the user is dragging.
    public var id: UUID
    /// Nil only for a glyph block.
    public var text: String?
    public var glyph: Glyph?
    public var color: MenuBarTokenColorRole
    /// Template scale × size step. The renderer multiplies its base font size
    /// by this.
    public var fontScale: Double
    public var weight: MenuBarToken.Weight
    public var monospacedDigits: Bool
    /// This block in words, or nil when it contributes nothing to a spoken
    /// description (spaces and separators).
    public var spoken: String?

    public init(
        id: UUID,
        text: String?,
        glyph: Glyph?,
        color: MenuBarTokenColorRole,
        fontScale: Double,
        weight: MenuBarToken.Weight,
        monospacedDigits: Bool,
        spoken: String?
    ) {
        self.id = id
        self.text = text
        self.glyph = glyph
        self.color = color
        self.fontScale = fontScale
        self.weight = weight
        self.monospacedDigits = monospacedDigits
        self.spoken = spoken
    }
}

public struct MenuBarRenderRow: Equatable, Sendable {
    public var tokens: [MenuBarRenderedToken]

    public init(tokens: [MenuBarRenderedToken] = []) {
        self.tokens = tokens
    }

    public var isEmpty: Bool { tokens.isEmpty }
}

/// Everything the status item needs for one render of a composed strip.
public struct MenuBarRenderPlan: Equatable, Sendable {
    public var rows: [MenuBarRenderRow]
    /// Gap between adjacent blocks, as a multiplier on the base font size.
    public var tokenSpacing: Double
    /// Multiplier on the base font size for the whole strip.
    public var fontScale: Double
    /// The strip in words, one clause per meaningful block, rows joined with
    /// " · ". Never the drawn shorthand — this is what a screen reader and the
    /// tooltip say.
    public var spokenDescription: String

    public init(
        rows: [MenuBarRenderRow],
        tokenSpacing: Double,
        fontScale: Double,
        spokenDescription: String
    ) {
        self.rows = rows
        self.tokenSpacing = tokenSpacing
        self.fontScale = fontScale
        self.spokenDescription = spokenDescription
    }

    /// Nothing survived: every block was hidden, or every quota it named is
    /// unavailable. The renderer draws the same "—" the field path draws.
    public var isEmpty: Bool { rows.allSatisfy(\.isEmpty) }
}

// MARK: - Planner

public extension MenuBarComposition {
    /// Turn this composition plus a quota snapshot into a draw plan.
    ///
    /// One forward pass over the tokens. `quotas` is a small array — the
    /// distinct fields `referencedFieldIds` named — scanned linearly, which
    /// beats building a dictionary per render for the handful of quotas a
    /// menu bar can hold.
    ///
    /// A quota token whose bucket is missing renders nothing and does not
    /// disturb the rest of the strip. Rows past `maximumRows` fold back into
    /// the last row.
    func plan(
        quotas: [MenuBarQuotaSnapshot],
        displayMode: DisplayMode,
        colorBasis: MenuBarColorBasis,
        now: Date = Date()
    ) -> MenuBarRenderPlan {
        let scale = effectiveFontScale
        // A seeded strip draws `5 Hours` and then `5 Hours 73% used`. That is
        // what the bar has always looked like, so the block keeps drawing —
        // but read aloud it stutters every field name, so it stops speaking.
        let echoed = Self.labelEchoTokenIds(
            tokens: tokens,
            quotas: quotas,
            displayMode: displayMode,
            now: now
        )
        var rows: [MenuBarRenderRow] = [MenuBarRenderRow()]
        var spokenRows: [[String]] = [[]]

        func snapshot(_ fieldId: String?) -> MenuBarQuotaSnapshot? {
            guard let fieldId else { return nil }
            return quotas.first { $0.fieldId == fieldId }
        }

        for token in tokens {
            // Before the row break, not after it: a row break is a block like
            // any other, and a conditional one is the point — stay on one row
            // normally, split to two when a quota goes critical. Checking
            // visibility afterwards made the strip always split.
            guard Self.isVisible(token.visibility, quotas: quotas) else { continue }
            if case .lineBreak = token.kind {
                // Ignored past the second row: a third row cannot be drawn, so
                // its blocks stay on the second rather than vanishing. A rule
                // that hides the break simply never opens the row, so honouring
                // it cannot collide with the cap.
                if rows.count < Self.maximumRows {
                    rows.append(MenuBarRenderRow())
                    spokenRows.append([])
                }
                continue
            }

            let own = snapshot(token.quotaFieldId)
            guard let content = Self.content(
                for: token,
                quota: own,
                displayMode: displayMode,
                now: now
            ) else { continue }

            let color = Self.colorRole(
                for: token,
                own: own,
                quotas: quotas,
                colorBasis: colorBasis
            )
            let spoken = echoed.contains(token.id) ? nil : content.spoken
            rows[rows.count - 1].tokens.append(MenuBarRenderedToken(
                id: token.id,
                text: content.text,
                glyph: content.glyph,
                color: color,
                fontScale: scale * token.style.size.multiplier,
                weight: token.style.weight,
                monospacedDigits: token.style.monospacedDigits,
                spoken: spoken
            ))
            if let spoken {
                spokenRows[spokenRows.count - 1].append(spoken)
            }
        }

        let spoken = spokenRows
            .map { $0.joined(separator: ", ") }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return MenuBarRenderPlan(
            rows: rows,
            tokenSpacing: effectiveTokenSpacing,
            fontScale: scale,
            spokenDescription: spoken
        )
    }

    /// Text blocks that only repeat the name of the quota block right after
    /// them, and so contribute nothing to a spoken description.
    ///
    /// Purely a speech concern: the strip still draws the label, because that
    /// is what a seeded strip looks like and what the user arranged. Only
    /// blocks separated from the quota by nothing but spacing count — a row
    /// break, a logo, or another word in between means the label is doing its
    /// own work and is read out.
    ///
    /// The quota block has to actually *say* something for the label to be
    /// redundant. A `runsOutIn` block whose forecast predicts no exhaustion,
    /// or a `forecastPercent` block with no forecast yet, renders nothing —
    /// and then the label beside it is the only content still on screen, so
    /// silencing it would leave the strip describing less than it shows.
    static func labelEchoTokenIds(
        tokens: [MenuBarToken],
        quotas: [MenuBarQuotaSnapshot],
        displayMode: DisplayMode,
        now: Date
    ) -> Set<UUID> {
        var echoed: Set<UUID> = []
        for (index, token) in tokens.enumerated() {
            guard case let .text(text) = token.kind else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var cursor = index + 1
            scan: while cursor < tokens.count {
                switch tokens[cursor].kind {
                case .space, .separator:
                    cursor += 1
                case let .quota(fieldId, metric):
                    if let quota = quotas.first(where: { $0.fieldId == fieldId }),
                       isVisible(tokens[cursor].visibility, quotas: quotas),
                       value(of: metric, in: quota, displayMode: displayMode, now: now) != nil,
                       quota.label.trimmingCharacters(in: .whitespacesAndNewlines)
                           .caseInsensitiveCompare(trimmed) == .orderedSame {
                        echoed.insert(token.id)
                    }
                    break scan
                default:
                    break scan
                }
            }
        }
        return echoed
    }

    // MARK: Visibility

    /// A rule the inputs cannot answer never hides its block. See
    /// `MenuBarToken.Visibility`.
    static func isVisible(
        _ visibility: MenuBarToken.Visibility,
        quotas: [MenuBarQuotaSnapshot]
    ) -> Bool {
        switch visibility {
        case .always:
            return true
        case let .whenUsedAtLeast(fieldId, percent):
            guard let quota = quotas.first(where: { $0.fieldId == fieldId }) else { return true }
            return quota.usedPercent >= percent
        case let .whenRemainingAtMost(fieldId, percent):
            guard let quota = quotas.first(where: { $0.fieldId == fieldId }) else { return true }
            return quota.remainingPercent <= percent
        case let .whenForecast(fieldId, verdicts):
            guard let quota = quotas.first(where: { $0.fieldId == fieldId }) else { return true }
            guard let forecast = quota.forecast else { return true }
            return verdicts.contains(forecast.verdict)
        }
    }

    // MARK: Content

    private struct TokenContent {
        var text: String?
        var glyph: MenuBarRenderedToken.Glyph?
        var spoken: String?
    }

    private static func content(
        for token: MenuBarToken,
        quota: MenuBarQuotaSnapshot?,
        displayMode: DisplayMode,
        now: Date
    ) -> TokenContent? {
        switch token.kind {
        case let .logo(tool):
            return TokenContent(
                text: nil,
                glyph: .provider(tool),
                spoken: tool.quotaSubProviderName()
            )
        case .appIcon:
            return TokenContent(text: nil, glyph: .app, spoken: "Vibe Bar")
        case let .text(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TokenContent(
                text: MenuBarToken.truncated(text),
                glyph: nil,
                // The full string, not the drawn one: a screen reader should
                // hear what the user wrote.
                spoken: trimmed.isEmpty ? nil : trimmed
            )
        case .space:
            return TokenContent(text: " ", glyph: nil, spoken: nil)
        case let .separator(separator):
            guard !separator.isEmpty else { return nil }
            return TokenContent(text: MenuBarToken.truncated(separator), glyph: nil, spoken: nil)
        case .lineBreak:
            return nil
        case let .quota(_, metric):
            // A bucket the provider is not returning right now takes its block
            // off the strip and leaves everything else alone.
            guard let quota, let text = value(of: metric, in: quota, displayMode: displayMode, now: now)
            else { return nil }
            return TokenContent(
                text: text,
                glyph: nil,
                spoken: spokenClause(metric: metric, value: text, quota: quota, displayMode: displayMode)
            )
        }
    }

    /// The exact string each metric renders. See `MenuBarQuotaMetric`.
    static func value(
        of metric: MenuBarQuotaMetric,
        in quota: MenuBarQuotaSnapshot,
        displayMode: DisplayMode,
        now: Date
    ) -> String? {
        switch metric {
        case .usedPercent:
            return percent(quota.usedPercent)
        case .remainingPercent:
            return percent(quota.remainingPercent)
        case .displayPercent:
            return percent(quota.displayPercent)
        case .pace:
            // Computed here, not in the snapshot: the linear expectation pace
            // is measured against advances every minute, so a value frozen at
            // resolve time would drift until the next refresh.
            guard let pace = UsagePace.compute(
                usedPercent: quota.usedPercent,
                resetAt: quota.resetAt,
                rawWindowSeconds: quota.rawWindowSeconds,
                now: now,
                allowsPostResetGrace: true
            ) else { return nil }
            let rounded = Int(pace.deltaPercent.rounded())
            if rounded == 0 { return "±0%" }
            return rounded > 0 ? "+\(rounded)%" : "\(rounded)%"
        case .forecastPercent:
            guard let forecast = quota.forecast else { return nil }
            return percent(forecast.projectedRemainingPercent)
        case .resetsIn:
            return ResetCountdownFormatter.string(from: quota.resetAt, now: now)
        case .resetAt:
            guard let resetAt = quota.resetAt else { return nil }
            return ResetCountdownFormatter.absoluteTime(for: resetAt, now: now)
        case .runsOutIn:
            guard let runOutAt = quota.forecast?.runOutAt else { return nil }
            return ResetCountdownFormatter.string(from: runOutAt, now: now)
        case .label:
            let trimmed = quota.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static func spokenClause(
        metric: MenuBarQuotaMetric,
        value: String,
        quota: MenuBarQuotaSnapshot,
        displayMode: DisplayMode
    ) -> String {
        switch metric {
        case .label:
            return value
        case .usedPercent:
            return "\(quota.label) \(value) used"
        case .remainingPercent:
            return "\(quota.label) \(value) remaining"
        case .displayPercent:
            return "\(quota.label) \(value) \(displayMode == .used ? "used" : "remaining")"
        case .pace:
            return "\(quota.label) pace \(value)"
        case .forecastPercent:
            return "\(quota.label) forecast \(value) left at reset"
        case .resetsIn:
            return "\(quota.label) resets in \(value)"
        case .resetAt:
            return "\(quota.label) resets at \(value)"
        case .runsOutIn:
            return "\(quota.label) runs out in \(value)"
        }
    }

    // MARK: Colour

    private static func colorRole(
        for token: MenuBarToken,
        own: MenuBarQuotaSnapshot?,
        quotas: [MenuBarQuotaSnapshot],
        colorBasis: MenuBarColorBasis
    ) -> MenuBarTokenColorRole {
        switch token.style.color {
        case .automatic:
            guard let own else { return .primary }
            return .quota(fieldId: own.fieldId, basis: colorBasis)
        case .forecast:
            guard let own else { return .primary }
            return .quota(fieldId: own.fieldId, basis: .forecast)
        case let .followsQuota(fieldId, basis):
            // Falls back rather than disappearing: a word coloured by a quota
            // that went away is still a word the user wrote.
            guard quotas.contains(where: { $0.fieldId == fieldId }) else { return .primary }
            return .quota(fieldId: fieldId, basis: basis)
        case let .brand(tool):
            return .brand(tool)
        case .primary:
            return .primary
        case .secondary:
            return .secondary
        case .tertiary:
            return .tertiary
        case let .fixed(hex):
            guard let normalized = MenuBarHexColor.normalized(hex) else { return .primary }
            return .fixed(hex: normalized)
        }
    }
}

// MARK: - Hex

/// Validation for `ColorSource.fixed`. Kept separate so both the decoder and
/// the stage-2 colour well can reject the same strings, and so an invalid
/// value degrades to `.primary` instead of failing the settings file.
public enum MenuBarHexColor {
    /// Accepts `#rgb`, `#rrggbb`, `#rrggbbaa`, with or without the `#`, in any
    /// case. Returns the normalized lowercase `#rrggbb` / `#rrggbbaa` form, or
    /// nil when the string is not a colour.
    public static func normalized(_ raw: String) -> String? {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if body.hasPrefix("#") { body.removeFirst() }
        guard body.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch body.count {
        case 3:
            return "#" + body.flatMap { [$0, $0] }
        case 6, 8:
            return "#" + body
        default:
            return nil
        }
    }

    /// Red, green, blue, alpha in 0…1, or nil for a string `normalized`
    /// rejects. The App turns this into an `NSColor`.
    public static func components(_ raw: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard let normalized = normalized(raw) else { return nil }
        let digits = Array(normalized.dropFirst())
        func byte(_ index: Int) -> Double {
            let high = digits[index].hexDigitValue ?? 0
            let low = digits[index + 1].hexDigitValue ?? 0
            return Double(high * 16 + low) / 255.0
        }
        return (
            byte(0),
            byte(2),
            byte(4),
            digits.count == 8 ? byte(6) : 1.0
        )
    }
}

// MARK: - Codable for the payload enums

extension MenuBarToken.Kind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case tool
        case text
        case fieldId
        case metric
    }

    private enum Discriminator: String, Codable {
        case logo, text, quota, space, separator, lineBreak, appIcon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Discriminator.self, forKey: .type) {
        case .logo:
            self = .logo(try c.decode(ToolType.self, forKey: .tool))
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .quota:
            self = .quota(
                fieldId: try c.decode(String.self, forKey: .fieldId),
                // An unknown metric from a newer build reads as the plain
                // percentage rather than dropping the block.
                metric: (try? c.decode(MenuBarQuotaMetric.self, forKey: .metric)) ?? .displayPercent
            )
        case .space:
            self = .space
        case .separator:
            self = .separator(try c.decode(String.self, forKey: .text))
        case .lineBreak:
            self = .lineBreak
        case .appIcon:
            self = .appIcon
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .logo(tool):
            try c.encode(Discriminator.logo, forKey: .type)
            try c.encode(tool, forKey: .tool)
        case let .text(text):
            try c.encode(Discriminator.text, forKey: .type)
            try c.encode(text, forKey: .text)
        case let .quota(fieldId, metric):
            try c.encode(Discriminator.quota, forKey: .type)
            try c.encode(fieldId, forKey: .fieldId)
            try c.encode(metric, forKey: .metric)
        case .space:
            try c.encode(Discriminator.space, forKey: .type)
        case let .separator(separator):
            try c.encode(Discriminator.separator, forKey: .type)
            try c.encode(separator, forKey: .text)
        case .lineBreak:
            try c.encode(Discriminator.lineBreak, forKey: .type)
        case .appIcon:
            try c.encode(Discriminator.appIcon, forKey: .type)
        }
    }
}

extension MenuBarToken.ColorSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case tool
        case hex
        case fieldId
        case basis
    }

    private enum Discriminator: String, Codable {
        case automatic, forecast, followsQuota, brand, primary, secondary, tertiary, fixed
    }

    /// Any shape this build cannot read becomes `.primary`: a colour is not
    /// worth losing a strip over.
    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
              let type = try? c.decode(Discriminator.self, forKey: .type)
        else {
            self = .primary
            return
        }
        switch type {
        case .automatic: self = .automatic
        case .forecast: self = .forecast
        case .followsQuota:
            guard let fieldId = try? c.decode(String.self, forKey: .fieldId) else {
                self = .primary
                return
            }
            let basis = (try? c.decode(MenuBarColorBasis.self, forKey: .basis)) ?? .forecast
            self = .followsQuota(fieldId: fieldId, basis: basis)
        case .brand:
            guard let tool = try? c.decode(ToolType.self, forKey: .tool) else {
                self = .primary
                return
            }
            self = .brand(tool)
        case .primary: self = .primary
        case .secondary: self = .secondary
        case .tertiary: self = .tertiary
        case .fixed:
            guard let raw = try? c.decode(String.self, forKey: .hex) else {
                self = .primary
                return
            }
            self = .hex(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic: try c.encode(Discriminator.automatic, forKey: .type)
        case .forecast: try c.encode(Discriminator.forecast, forKey: .type)
        case let .followsQuota(fieldId, basis):
            try c.encode(Discriminator.followsQuota, forKey: .type)
            try c.encode(fieldId, forKey: .fieldId)
            try c.encode(basis, forKey: .basis)
        case let .brand(tool):
            try c.encode(Discriminator.brand, forKey: .type)
            try c.encode(tool, forKey: .tool)
        case .primary: try c.encode(Discriminator.primary, forKey: .type)
        case .secondary: try c.encode(Discriminator.secondary, forKey: .type)
        case .tertiary: try c.encode(Discriminator.tertiary, forKey: .type)
        case let .fixed(hex):
            try c.encode(Discriminator.fixed, forKey: .type)
            try c.encode(MenuBarHexColor.normalized(hex) ?? hex, forKey: .hex)
        }
    }

    /// The quota this colour follows, if any.
    var fieldId: String? {
        if case let .followsQuota(fieldId, _) = self { return fieldId }
        return nil
    }

    /// Whether resolving this colour needs the personal forecast.
    var needsForecast: Bool {
        switch self {
        case .forecast: return true
        case let .followsQuota(_, basis): return basis == .forecast
        // `.automatic` follows the app-wide basis, which the renderer already
        // resolves for every quota it draws; it never adds a forecast the
        // field path would not have computed anyway.
        default: return false
        }
    }

    /// Whether this source colours the block from the block's *own* quota —
    /// the one field it never names, because naming it would be redundant.
    ///
    /// `quotaRequirements` has to special-case these: `.forecast` carries no
    /// `fieldId`, so without this the requirement walk skipped it entirely and
    /// a block that explicitly asked for the forecast colour got no verdict to
    /// resolve against, silently falling back to the percentage thresholds
    /// whenever the app-wide basis was `.actual`.
    var followsOwnQuota: Bool {
        switch self {
        case .automatic, .forecast: return true
        default: return false
        }
    }
}

extension MenuBarToken.Visibility: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case fieldId
        case percent
        case verdicts
    }

    private enum Discriminator: String, Codable {
        case always, whenUsedAtLeast, whenRemainingAtMost, whenForecast
    }

    /// An unreadable rule becomes `.always`, for the same reason an
    /// unevaluatable one resolves to visible.
    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
              let type = try? c.decode(Discriminator.self, forKey: .type)
        else {
            self = .always
            return
        }
        switch type {
        case .always:
            self = .always
        case .whenUsedAtLeast:
            guard let fieldId = try? c.decode(String.self, forKey: .fieldId),
                  let percent = try? c.decode(Double.self, forKey: .percent)
            else {
                self = .always
                return
            }
            self = .whenUsedAtLeast(fieldId: fieldId, percent: percent.clamped(to: 0...100))
        case .whenRemainingAtMost:
            guard let fieldId = try? c.decode(String.self, forKey: .fieldId),
                  let percent = try? c.decode(Double.self, forKey: .percent)
            else {
                self = .always
                return
            }
            self = .whenRemainingAtMost(fieldId: fieldId, percent: percent.clamped(to: 0...100))
        case .whenForecast:
            guard let fieldId = try? c.decode(String.self, forKey: .fieldId),
                  let raw = try? c.decode([String].self, forKey: .verdicts)
            else {
                self = .always
                return
            }
            let verdicts = Set(raw.compactMap(QuotaPaceForecast.Verdict.init(rawValue:)))
            // A rule that matches nothing would hide the block forever.
            self = verdicts.isEmpty ? .always : .whenForecast(fieldId: fieldId, verdicts: verdicts)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .always:
            try c.encode(Discriminator.always, forKey: .type)
        case let .whenUsedAtLeast(fieldId, percent):
            try c.encode(Discriminator.whenUsedAtLeast, forKey: .type)
            try c.encode(fieldId, forKey: .fieldId)
            try c.encode(percent, forKey: .percent)
        case let .whenRemainingAtMost(fieldId, percent):
            try c.encode(Discriminator.whenRemainingAtMost, forKey: .type)
            try c.encode(fieldId, forKey: .fieldId)
            try c.encode(percent, forKey: .percent)
        case let .whenForecast(fieldId, verdicts):
            try c.encode(Discriminator.whenForecast, forKey: .type)
            try c.encode(fieldId, forKey: .fieldId)
            // Sorted so an unchanged rule writes an unchanged settings file.
            try c.encode(verdicts.map(\.rawValue).sorted(), forKey: .verdicts)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}


/// The menu bar's countdown clock.
///
/// A composed strip can print `resets in 12m`, which is wrong a minute later
/// with no new data behind it. The render pipeline is driven by settings,
/// quota, account, cost and status publishers — none of which is a clock — so
/// with a 30-minute refresh interval that countdown could sit unchanged past
/// its own deadline.
///
/// Ticks are phase-aligned rather than free-running: the app already floors a
/// process-wide anchor to a five-minute boundary so every surface asks for the
/// same instant, and a menu-bar countdown that drifts a few seconds away from
/// the popover's would show two different numbers for one quota.
public enum MenuBarCountdownClock {
    /// A minute: the finest granularity any menu-bar metric renders.
    public static let interval: TimeInterval = 60

    /// The tick a forecast-driven strip needs. Paced to the forecast's own
    /// quantization — `QuotaService` floors its clock to five minutes and
    /// memoises on it, so a faster tick buys nothing but wakeups on the
    /// menu bar's hot path.
    public static let forecastInterval: TimeInterval =
        QuotaService.paceForecastClockQuantumSeconds

    /// The next grid point strictly after `date`, on the phase grid anchored
    /// at `anchor`. Strictly after, so a tick that fires a hair early cannot
    /// schedule itself for the instant it just handled and spin.
    public static func nextTick(
        after date: Date,
        anchor: Date,
        interval: TimeInterval = MenuBarCountdownClock.interval
    ) -> Date {
        let step = max(1, interval)
        let elapsed = date.timeIntervalSinceReferenceDate - anchor.timeIntervalSinceReferenceDate
        let steps = (elapsed / step).rounded(.down) + 1
        return Date(timeIntervalSinceReferenceDate: anchor.timeIntervalSinceReferenceDate + steps * step)
    }
}

/// Fitting a composed strip into the height it actually has.
///
/// The status item is about 22 points tall. Two rows of `.large` blocks at the
/// composition's top font scale do not fit, and the drawing code used to keep
/// the full row heights while the canvas was capped — so the upper row was
/// cropped or the two rows overlapped. Shrinking the type is the honest
/// answer: the strip stays legible and nothing is silently cut off.
public enum MenuBarStripFit {
    /// Below this the type is too small to read, so the strip accepts being
    /// tight rather than becoming a smudge.
    public static let minimumScale: Double = 0.55

    /// Uniform font scale that makes `contentHeight` fit `availableHeight`.
    /// Returns 1 when it already fits.
    public static func scale(
        contentHeight: Double,
        availableHeight: Double,
        minimumScale: Double = MenuBarStripFit.minimumScale
    ) -> Double {
        guard contentHeight > 0, availableHeight > 0, contentHeight > availableHeight else {
            return 1
        }
        return Swift.max(minimumScale, availableHeight / contentHeight)
    }
}


/// Geometry shared by the status item's two-row rasterizer and its tests.
///
/// A cell is a list of runs — glyphs and text — drawn left to right. The gap
/// *between* runs belongs to whoever built the cell, and getting that wrong is
/// invisible until you measure it: the built-in two-row layout draws one
/// leading logo and needs a fixed gap after it, while a composed row already
/// carries the user's configured spacing inside its own text runs. Adding the
/// built-in gap to a composed row double-counts it, so zero spacing still
/// shows a gap and non-zero spacing comes out wider in the bar than in the
/// preview.
public enum MenuBarStripGeometry {
    /// Total width of a cell: its runs, plus one `gap` between each adjacent
    /// pair. A composed row passes `gap: 0`.
    public static func cellWidth(runWidths: [Double], gap: Double) -> Double {
        guard !runWidths.isEmpty else { return 0 }
        return runWidths.reduce(0, +) + gap * Double(runWidths.count - 1)
    }
}
