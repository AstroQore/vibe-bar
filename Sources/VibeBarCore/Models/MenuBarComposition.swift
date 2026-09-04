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
/// `12m`, `<1m`, `now`. `resetAt` prints whatever `Style.resetFormat` asks
/// for — a bare time by default while the reset is still today, the weekday
/// and date once it is not.
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
        case .usedPercent: return L10n.MenuBar.composerMetricUsedPercent
        case .remainingPercent: return L10n.MenuBar.composerMetricRemainingPercent
        case .displayPercent: return L10n.MenuBar.composerMetricDisplayPercent
        case .pace: return L10n.MenuBar.composerMetricPace
        case .forecastPercent: return L10n.MenuBar.composerMetricForecastPercent
        case .resetsIn: return L10n.MenuBar.composerMetricResetsIn
        case .resetAt: return L10n.MenuBar.composerMetricResetAt
        case .runsOutIn: return L10n.MenuBar.composerMetricRunsOutIn
        case .label: return L10n.MenuBar.composerMetricLabel
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
        /// Blank space, `width` space glyphs wide at the block's own size.
        ///
        /// A count rather than a length: the gap is drawn as literal spaces in
        /// the same attributed string as the words beside it, which is the one
        /// idiom that works in the two-row canvas (an attachment inflates the
        /// line box). Measuring a point width instead would need a second
        /// mechanism in three drawing paths to buy sub-space precision nobody
        /// asked for.
        case space(width: Int)
        /// A literal divider the user chose — `" · "`, `"/"`, `"|"`.
        case separator(String)
        /// Vibe Bar's own glyph — what the Icon Only layout draws, and the
        /// only mark on the strip that is not a provider's. Without it the
        /// composer could not seed an Icon Only item with what the user is
        /// actually looking at.
        case appIcon
        /// A block written by a build that knew something this one does not —
        /// a kind it has never heard of, or a provider added after it shipped.
        /// Kept exactly as found and handed back on the next save, because the
        /// alternative is deleting a block the user made and never telling
        /// them. Draws nothing and says nothing; the editor labels it and lets
        /// it be removed.
        case unsupported(JSONValue)
    }

    /// How the block looks. Colour is the interesting axis: any block — a
    /// logo, a word, a number — may follow a quota's live colour, which is
    /// what makes "the label goes red with the number" expressible.
    public struct Style: Codable, Hashable, Sendable {
        public var color: ColorSource
        public var size: SizeStep
        public var weight: Weight
        public var monospacedDigits: Bool
        /// The shape a `.resetAt` block prints its time in. It sits here for
        /// the same reason `monospacedDigits` does: it changes how the block's
        /// content is rendered, not which datum the block reads — that is
        /// `metric`'s job — and it is inert on every block that draws no reset
        /// time. Putting it on `Kind.quota` instead would make an unknown
        /// value from a newer build take the whole block down (see the
        /// `metric` note in `Kind`'s decoder), which is far too harsh a
        /// penalty for a date format.
        public var resetFormat: ResetTimeFormat

        public init(
            color: ColorSource = .automatic,
            size: SizeStep = .regular,
            weight: Weight = .medium,
            monospacedDigits: Bool = false,
            resetFormat: ResetTimeFormat = .default
        ) {
            self.color = color
            self.size = size
            self.weight = weight
            self.monospacedDigits = monospacedDigits
            self.resetFormat = resetFormat
        }

        private enum CodingKeys: String, CodingKey {
            case color, size, weight, monospacedDigits, resetFormat
        }

        /// Every field degrades to its default.
        ///
        /// This decoder is hand-written for one reason: the synthesized one
        /// throws when it meets a `SizeStep` or `Weight` a newer build wrote,
        /// and `LossyMenuBarToken` turns a throw into a *dropped block* — so
        /// running a newer build and going back deleted the user's blocks, and
        /// the next save wrote that deletion to disk. A block that comes back
        /// a little plainer can be fixed in a second; a block that is gone
        /// cannot be recovered at all.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.color = (try? c.decode(ColorSource.self, forKey: .color)) ?? .automatic
            // Also how the retired `large` arrives: it asked to be bigger
            // than the strip, and the biggest thing now is the strip's own
            // size, which is what an unreadable step already falls back to.
            self.size = (try? c.decode(SizeStep.self, forKey: .size)) ?? .regular
            self.weight = (try? c.decode(Weight.self, forKey: .weight)) ?? .medium
            self.monospacedDigits =
                (try? c.decode(Bool.self, forKey: .monospacedDigits)) ?? false
            self.resetFormat =
                (try? c.decode(ResetTimeFormat.self, forKey: .resetFormat)) ?? .default
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

    /// The sizes a block can be drawn at, all of them at or below the
    /// strip's own.
    ///
    /// There used to be a Large, and it could not work: the status item is
    /// about 22 points tall and the default already fills it, so anything
    /// bigger had to be paid for by the blocks around it. Every attempt to
    /// make that fair — capping the grower, sharing a surplus, fitting rows
    /// separately — was machinery for dividing room that does not exist.
    ///
    /// Going down instead needs none of it. Nothing can exceed the strip's
    /// own scale, so no choice can cost a block that did not make it, and
    /// the question of who pays never arises.
    public enum SizeStep: String, Codable, CaseIterable, Sendable {
        case regular
        case small
        case mini

        /// Multiplier on the row's base font size. Never above 1.
        public var multiplier: Double {
            switch self {
            case .regular: return 1.0
            case .small: return 0.85
            case .mini: return 0.72
            }
        }

        public var title: String {
            switch self {
            case .regular: return L10n.MenuBar.composerSizeRegular
            case .small: return L10n.MenuBar.composerSizeSmall
            case .mini: return L10n.MenuBar.composerSizeMini
            }
        }

    }

    public enum Weight: String, Codable, CaseIterable, Sendable {
        case regular
        case medium
        case semibold

        public var title: String {
            switch self {
            case .regular: return L10n.MenuBar.composerWeightRegular
            case .medium: return L10n.MenuBar.composerWeightMedium
            case .semibold: return L10n.MenuBar.composerWeightSemibold
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

    /// How wide a new `.space` block is, and how wide the editor lets one get.
    ///
    /// One is what the strip has always drawn. The ceiling is a menu-bar
    /// ceiling, not a modelling one: eight spaces at the compact face is
    /// already a fifth of a typical status item, and the bar is shared with
    /// every other item on the machine.
    public static let defaultSpaceWidth = 1
    public static let spaceWidthRange: ClosedRange<Int> = 1...8

    public static func clampedSpaceWidth(_ width: Int) -> Int {
        Swift.min(Swift.max(width, spaceWidthRange.lowerBound), spaceWidthRange.upperBound)
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
    /// The run of blocks this one is bound into, if any.
    ///
    /// Blocks sharing a `groupID` move as one — drag any member and the whole
    /// run goes. `MenuBarComposition` keeps the invariant that they are always
    /// side by side in one row: an edit that would scatter them dissolves the
    /// group instead, because silently reordering the user's blocks to keep a
    /// binding intact is the worse of the two.
    ///
    /// Not the segment: a segment is a column of the strip, and a group is a
    /// handful of blocks inside one of its rows.
    public var groupID: UUID?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        style: Style = Style(),
        visibility: Visibility = .always,
        groupID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.style = style
        self.visibility = visibility
        self.groupID = groupID
    }

    // MARK: Palette

    /// The blocks the palette can add, built in one place.
    ///
    /// **A stored string is user-authored, full stop.** Copy that exists to be
    /// *shown* — a placeholder, a caption, a prompt — must never become a
    /// block's content, because settings outlive the language that was
    /// selected when the block was made. A text block added while the app was
    /// in Chinese used to persist the Chinese placeholder and then render it
    /// after a switch to English, which is the same defect the seeded labels
    /// had: a derived name is a reference resolved at render, and only text
    /// the user actually typed is stored.
    ///
    /// Building every palette block here is what makes that checkable rather
    /// than remembered: `MenuBarCompositionTests` constructs all of them under
    /// each supported language and asserts the stored values are identical.
    public static func newText() -> MenuBarToken {
        // Empty on purpose. The editor shows the placeholder; settings hold
        // nothing until the user types.
        MenuBarToken(kind: .text(""), style: .label)
    }

    public static func newAppIcon() -> MenuBarToken {
        MenuBarToken(kind: .appIcon, style: .label)
    }

    public static func newLogo(_ tool: ToolType) -> MenuBarToken {
        MenuBarToken(kind: .logo(tool), style: .label)
    }

    public static func newQuota(fieldId: String) -> MenuBarToken {
        MenuBarToken(kind: .quota(fieldId: fieldId, metric: .displayPercent), style: .percent)
    }

    public static func newSpace() -> MenuBarToken {
        MenuBarToken(kind: .space(width: defaultSpaceWidth))
    }

    public static func newSeparator() -> MenuBarToken {
        // Punctuation, not copy: a middle dot reads the same in every
        // language the app ships.
        MenuBarToken(kind: .separator(" · "), style: .divider)
    }

    /// One of each, for the test that pins the invariant above.
    public static func paletteSamples(
        tool: ToolType = .claude,
        fieldId: String = "claude.five_hour"
    ) -> [MenuBarToken] {
        [
            newAppIcon(), newLogo(tool), newText(),
            newQuota(fieldId: fieldId), newSpace(), newSeparator()
        ]
    }

    /// The quota this token reads, if it is a quota token.
    private enum CodingKeys: String, CodingKey {
        case id, kind, style, visibility, groupID
    }

    /// Same reasoning as `Style`: everything except the block's own identity
    /// degrades rather than taking the block down. `kind` is the exception —
    /// a block whose kind this build cannot read is preserved verbatim
    /// instead, see `Kind.unsupported`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.style = (try? c.decode(Style.self, forKey: .style)) ?? Style()
        self.visibility = (try? c.decode(Visibility.self, forKey: .visibility)) ?? .always
        // Absent in every settings file written before groups existed, and a
        // block that arrives unbound is simply a block on its own.
        self.groupID = try? c.decode(UUID.self, forKey: .groupID)
    }

    public var quotaFieldId: String? {
        if case let .quota(fieldId, _) = kind { return fieldId }
        return nil
    }

    public var metric: MenuBarQuotaMetric? {
        if case let .quota(_, metric) = kind { return metric }
        return nil
    }
}

// MARK: - Segment

/// A stored column's rows, however they were written.
///
/// A group and a saved group spell them identically, and the migration off the
/// break marker is the kind of thing that goes subtly wrong in the second copy
/// — so both read it here. `top`/`bottom` is what this build writes; a file
/// with neither is one whose rows were still a single list with a marker in
/// the middle, and it is split there.
///
/// Lossy per block throughout: one unreadable block must not take a row with
/// it.
private struct StoredMenuBarRows: Decodable {
    let top: [MenuBarToken]
    let bottom: [MenuBarToken]?

    private enum CodingKeys: String, CodingKey {
        case top
        case bottom
        case tokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let storedTop = (try? c.decodeIfPresent([LossyMenuBarToken].self, forKey: .top))
            .flatMap({ $0 })
        else {
            let stored = try c.decodeIfPresent([MenuBarFlatToken].self, forKey: .tokens) ?? []
            (top, bottom) = MenuBarFlatToken.rows(stored)
            return
        }
        top = storedTop.compactMap(\.value)
        bottom = (try? c.decodeIfPresent([LossyMenuBarToken].self, forKey: .bottom))
            .flatMap { $0 }?
            .compactMap(\.value)
    }
}

/// One group of blocks — what the strip draws as a single *column*.
///
/// A column holds its rows as two containers: `top`, and `bottom` when the
/// column stacks. That is the whole of the row model. It used to be one list
/// with a `.lineBreak` block in the middle, and the difference is not
/// cosmetic — a marker in a list can be dragged, duplicated, given a colour,
/// and written twice, so every one of those had to be forbidden somewhere.
/// Two containers cannot express a third row, a row break in the wrong place,
/// or a block that is neither above nor below.
///
/// A column with no bottom row is a one-cell column, which the rasterizer
/// centres across both rows — the same structure `twoRowMenuColumns` has
/// always handed it.
public struct MenuBarSegment: Identifiable, Codable, Equatable, Sendable {
    /// Which of a column's two rows. There is no third case, and that is the
    /// point: `MenuBarComposition.maximumRows` is a fact about this type now
    /// rather than a rule something has to remember to check.
    public enum Row: String, Codable, CaseIterable, Sendable {
        case top
        case bottom
    }

    public var id: UUID
    public var top: [MenuBarToken]
    /// Nil when the column does not stack. Empty-but-present is a row the user
    /// opened and has not filled yet; it is kept, because a row that vanished
    /// on the next launch would be a control that does not hold.
    public var bottom: [MenuBarToken]?

    public init(id: UUID = UUID(), top: [MenuBarToken] = [], bottom: [MenuBarToken]? = nil) {
        self.id = id
        self.top = top
        self.bottom = bottom
    }

    /// A one-row column. The shape most callers want — a seed, a fixture, a
    /// preset with nothing stacked.
    public init(id: UUID = UUID(), tokens: [MenuBarToken]) {
        self.init(id: id, top: tokens, bottom: nil)
    }

    public var isStacked: Bool { bottom != nil }
    public var isEmpty: Bool { top.isEmpty && (bottom?.isEmpty ?? true) }

    /// Every block in this column, in reading order: the top cell, then the
    /// bottom one.
    public var tokens: [MenuBarToken] { top + (bottom ?? []) }

    public subscript(row: Row) -> [MenuBarToken] {
        get { row == .top ? top : (bottom ?? []) }
        set {
            switch row {
            case .top: top = newValue
            case .bottom: bottom = newValue
            }
        }
    }

    /// Which row a block is in, and where inside it.
    public func position(of id: UUID) -> (row: Row, offset: Int)? {
        if let offset = top.firstIndex(where: { $0.id == id }) { return (.top, offset) }
        if let offset = bottom?.firstIndex(where: { $0.id == id }) { return (.bottom, offset) }
        return nil
    }

    /// Open the second row. No-op when the column already stacks.
    public mutating func addRow() {
        guard bottom == nil else { return }
        bottom = []
    }

    /// Close the second row, its blocks joining the end of the first.
    ///
    /// Nothing is deleted: a row is a place blocks live, so removing the place
    /// has to say where they go, and the row above is the only answer that
    /// keeps the reading order the column already had.
    public mutating func removeRow() {
        guard let bottom else { return }
        top.append(contentsOf: bottom)
        self.bottom = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case top
        case bottom
    }

    /// Same tolerance the composition's own token list has always had: one
    /// unreadable block must not take the group down with it, and a missing
    /// id is a new id rather than a dropped segment.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        let rows = try StoredMenuBarRows(from: decoder)
        self.top = rows.top
        self.bottom = rows.bottom
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(top, forKey: .top)
        try c.encodeIfPresent(bottom, forKey: .bottom)
    }
}

/// A named group of blocks the user saved to use again.
///
/// The blocks are stored exactly as they were arranged, quota ids included. A
/// preset that names a bucket this Mac no longer returns is not repaired or
/// filtered on the way in or out: inserted, it is a block like any other, and
/// `MenuBarComposition.availability(liveFieldIds:)` already marks it and says
/// why. Rewriting it would be the same destruction a substituted metric was.
public struct MenuBarSegmentPreset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// The user's own words. Stored verbatim and never translated, for the
    /// reason `MenuBarToken.newText` spells out.
    public var name: String
    /// A saved group is a saved column, rows and all — a preset that came back
    /// flat would not be the group the user pointed at when they saved it.
    public var top: [MenuBarToken]
    public var bottom: [MenuBarToken]?

    public init(
        id: UUID = UUID(),
        name: String,
        top: [MenuBarToken],
        bottom: [MenuBarToken]? = nil
    ) {
        self.id = id
        self.name = name
        self.top = top
        self.bottom = bottom
    }

    public init(id: UUID = UUID(), name: String, segment: MenuBarSegment) {
        self.init(id: id, name: name, top: segment.top, bottom: segment.bottom)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case top
        case bottom
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        let rows = try StoredMenuBarRows(from: decoder)
        self.top = rows.top
        self.bottom = rows.bottom
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(top, forKey: .top)
        try c.encodeIfPresent(bottom, forKey: .bottom)
    }

    /// A copy of this preset's blocks with fresh identities, ready to become a
    /// segment. Two insertions of one preset are two groups the editor can
    /// drag apart, the same rule `duplicate` follows.
    public func segment() -> MenuBarSegment {
        // Fresh bindings as well as fresh identities, and one per original
        // group so a run stays a run. Reusing the saved ids would make two
        // copies of the same preset read as one group once they shared a row,
        // and dragging either would move both.
        var rebound: [UUID: UUID] = [:]
        func copies(_ tokens: [MenuBarToken]) -> [MenuBarToken] {
            tokens.map { token in
                var copy = token
                copy.id = UUID()
                if let group = token.groupID {
                    copy.groupID = rebound[group] ?? {
                        let fresh = UUID()
                        rebound[group] = fresh
                        return fresh
                    }()
                }
                return copy
            }
        }
        return MenuBarSegment(top: copies(top), bottom: bottom.map(copies))
    }
}

// MARK: - Composition

/// A composed menu-bar strip: a template, an ordered list of block groups, and
/// two optional overrides for the template's spacing and scale.
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
        /// uses. Seeds each column with a second row.
        case twoColumn

        public var title: String {
            switch self {
            case .compact: return L10n.MenuBar.composerTemplateCompact
            case .roomy: return L10n.MenuBar.composerTemplateRoomy
            case .twoColumn: return L10n.MenuBar.composerTemplateTwoRows
            }
        }

        public var detail: String {
            switch self {
            case .compact: return L10n.MenuBar.composerTemplateCompactDetail
            case .roomy: return L10n.MenuBar.composerTemplateRoomyDetail
            case .twoColumn: return L10n.MenuBar.composerTemplateTwoRowsDetail
            }
        }

        /// Gap between adjacent blocks, as a multiplier on the row's base font
        /// size. Realized as a space glyph, exactly the way the existing
        /// logo-to-label gap already is — a text attachment would inflate the
        /// line box and push the second row out of the bar.
        /// One space, in every template.
        ///
        /// The composed renderer puts this between *every* pair of blocks,
        /// including a label and its number — and one space is exactly what
        /// each field renderer draws there. Anything else makes a seeded strip
        /// a different width from the strip it reproduces, which is what a
        /// larger value did. The templates differ by face and by rows, not by
        /// how far apart the words sit.
        public var tokenSpacing: Double { 1.0 }

        /// Multiplier on the layout's base font size.
        public var fontScale: Double {
            switch self {
            // 1.0, not 0.95: Compact's smallness is its *face* — the 9pt one
            // the built-in compact layout draws at — and scaling that down
            // again would make the seeded strip smaller than the strip it is
            // meant to reproduce. See `MenuBarStripGeometry.face`.
            case .compact: return 1.0
            case .roomy: return 1.0
            case .twoColumn: return 1.0
            }
        }

        var seedsSecondRow: Bool { self == .twoColumn }

        /// What this template draws between two entries sharing a row, when a
        /// two-row strip collapses back to one.
        ///
        /// The same answer the seed uses, from the same table — a row break
        /// and an entry boundary are the same boundary seen two ways, so they
        /// must round-trip.
        var inlineSeparator: MenuBarToken.Kind? {
            MenuBarFieldStripRules.separator(for: seededFrom)
        }

        /// The field layout this template reproduces.
        var seededFrom: MenuBarLayout {
            switch self {
            case .compact: return .compact
            case .roomy: return .singleLine
            case .twoColumn: return .twoRows
            }
        }

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

        /// Layouts this template can be the match for. `.iconOnly` also maps
        /// to `.roomy`, since an icon-only seed is a single glyph and has no
        /// spacing or separator of its own to reproduce.
        static var allLayouts: [MenuBarLayout] { MenuBarLayout.allCases }
    }

    /// The status item is ~22pt tall: two rows is the most the rasterizer can
    /// fit legibly. `MenuBarSegment.Row` is what enforces it — this constant
    /// is the number the renderers size against, not a limit anything checks.
    public static let maximumRows = MenuBarSegment.Row.allCases.count

    public static let fontScaleRange: ClosedRange<Double> = 0.6...1.6
    public static let tokenSpacingRange: ClosedRange<Double> = 0...4

    public var isEnabled: Bool
    public var template: Template
    /// The strip's groups, left to right. Never empty in a strip that draws
    /// anything; an empty list and a list of one empty segment both draw "—".
    public var segments: [MenuBarSegment]
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
        self.init(
            isEnabled: isEnabled,
            template: template,
            segments: tokens.isEmpty ? [] : [MenuBarSegment(tokens: tokens)],
            fontScale: fontScale,
            tokenSpacing: tokenSpacing
        )
    }

    public init(
        isEnabled: Bool = false,
        template: Template = .roomy,
        segments: [MenuBarSegment],
        fontScale: Double? = nil,
        tokenSpacing: Double? = nil
    ) {
        self.isEnabled = isEnabled
        self.template = template
        self.segments = segments
        self.fontScale = fontScale.map { $0.clamped(to: Self.fontScaleRange) }
        self.tokenSpacing = tokenSpacing.map { $0.clamped(to: Self.tokenSpacingRange) }
    }

    /// Every block on the strip, groups concatenated left to right.
    ///
    /// Read-only, and the read is what most of this type wants: which quotas
    /// are named, whether anything ticks, which blocks a provider silenced —
    /// none of that cares where the group boundaries are. Writing through it
    /// would have to guess where the boundaries went, so the mutations below
    /// address a group instead.
    public var tokens: [MenuBarToken] { segments.flatMap(\.tokens) }

    /// Replace the whole strip with one group holding these blocks.
    ///
    /// The one operation that genuinely has no grouping to preserve — a seed,
    /// a test fixture, a strip rebuilt from scratch.
    public mutating func setSingleSegment(_ tokens: [MenuBarToken]) {
        segments = tokens.isEmpty ? [] : [MenuBarSegment(tokens: tokens)]
    }

    /// Choose a template, and take the row structure it describes with it.
    ///
    /// A template is mostly spacing and type size, but "Two rows" is a claim
    /// about shape — so setting the enum without touching the blocks left the
    /// picker promising two rows and drawing one. Selecting it opens a second
    /// row and moves the tail of a column into it; selecting a single-row
    /// template folds every second row back up.
    ///
    /// The split lands where the seed would put it: at the seam between the
    /// two halves of the entries, taking over the divider that was already
    /// there rather than leaving it at the end of a row. Folding back restores
    /// that divider, so the two directions round-trip.
    public mutating func setTemplate(_ newTemplate: Template) {
        template = newTemplate
        defer { normalizeGroups() }
        if newTemplate.seedsSecondRow {
            guard !segments.contains(where: \.isStacked) else { return }
            // The seam is looked for inside each group, longest first: a
            // strip the user has already grouped has its columns, and the one
            // with the most to say is the one worth stacking. An ungrouped
            // strip is one group, which is the case this rule was written for.
            guard let target = segments.indices.max(by: {
                segments[$0].top.count < segments[$1].top.count
            }) else { return }
            var top = segments[target].top
            guard let seam = Self.rowSeamIndex(in: top) else { return }
            var moved = Array(top[seam...])
            top.removeSubrange(seam...)
            // The spacing in front of the second half is the boundary the row
            // break takes over, so it goes rather than dangling at a row end.
            switch moved.first?.kind {
            case .space, .separator: moved.removeFirst()
            default: break
            }
            segments[target].top = top
            segments[target].bottom = moved
        } else {
            for index in segments.indices {
                guard let bottom = segments[index].bottom else { continue }
                segments[index].bottom = nil
                guard !bottom.isEmpty else { continue }
                // Restore whatever this template draws between two entries
                // sharing a row. Nothing on a template that separates by
                // spacing alone — the strip's own gaps do the work there.
                if let inline = newTemplate.inlineSeparator, !segments[index].top.isEmpty {
                    segments[index].top.append(MenuBarToken(kind: inline, style: .divider))
                }
                segments[index].top.append(contentsOf: bottom)
            }
        }
    }

    /// Where a strip splits into two rows: before the first block of the
    /// second half, preferring the spacing block just in front of it so the
    /// break replaces the divider instead of joining it. `nil` when there is
    /// not enough on the strip to split.
    private static func rowSeamIndex(in tokens: [MenuBarToken]) -> Int? {
        // Between entries, never through one. Counting raw content tokens put
        // the seam in the middle of the *second* entry of three — an entry is
        // a name and a number, so six tokens bisected the pair — leaving one
        // field's label on the first row and its percentage on the second.
        // A strip the user built out of words and logos has no values, so
        // nothing closes an entry and the whole thing reads as one. Splitting
        // between blocks is the honest answer there: choosing Two rows has to
        // produce two rows, and a control that quietly produces one is the
        // defect this seam was written to fix.
        let starts = entryStartIndices(in: tokens).count >= 2
            ? entryStartIndices(in: tokens)
            : blockStartIndices(in: tokens)
        guard starts.count >= 2 else { return nil }
        let start = starts[(starts.count + 1) / 2]
        // The spacing in front of the entry is the boundary the break takes
        // over, so it goes with the break rather than dangling at a row end.
        if start > 0 {
            switch tokens[start - 1].kind {
            case .space, .separator: return start - 1
            default: break
            }
        }
        return start
    }

    /// Where each entry begins.
    ///
    /// An entry is a name and the value it names — optionally behind a logo.
    /// A new one starts at the first naming block that follows a value, which
    /// finds the boundaries whether or not the strip has divider blocks
    /// between them (Compact and Two rows seed none).
    /// Every drawn block, used when nothing in the strip closes an entry.
    private static func blockStartIndices(in tokens: [MenuBarToken]) -> [Int] {
        tokens.indices.filter { index in
            switch tokens[index].kind {
            case .space, .separator: return false
            default: return true
            }
        }
    }

    private static func entryStartIndices(in tokens: [MenuBarToken]) -> [Int] {
        var starts: [Int] = []
        var sawValue = true
        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case .space, .separator:
                continue
            case let .quota(_, metric) where metric != .label:
                sawValue = true
            case .logo, .appIcon, .text, .quota, .unsupported:
                if sawValue {
                    starts.append(index)
                    sawValue = false
                }
            }
        }
        return starts
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

    /// Where a block sits: which group, which of its rows, and where inside
    /// that row.
    public struct Location: Equatable, Sendable {
        public var segment: Int
        public var row: MenuBarSegment.Row
        public var offset: Int

        public init(segment: Int, row: MenuBarSegment.Row, offset: Int) {
            self.segment = segment
            self.row = row
            self.offset = offset
        }
    }

    /// One row of one group, named the way a drop target has to name it.
    ///
    /// By the group's identity rather than its index, because the editor holds
    /// this across a drag that reorders the groups underneath it.
    public struct RowAddress: Hashable, Sendable {
        public var segment: UUID
        public var row: MenuBarSegment.Row

        public init(segment: UUID, row: MenuBarSegment.Row) {
            self.segment = segment
            self.row = row
        }
    }

    public func location(of id: UUID) -> Location? {
        for (segment, group) in segments.enumerated() {
            if let position = group.position(of: id) {
                return Location(segment: segment, row: position.row, offset: position.offset)
            }
        }
        return nil
    }

    public func token(_ id: UUID) -> MenuBarToken? {
        for group in segments {
            if let position = group.position(of: id) { return group[position.row][position.offset] }
        }
        return nil
    }

    /// Change one block in place, wherever it lives.
    public mutating func updateToken(_ id: UUID, _ change: (inout MenuBarToken) -> Void) {
        guard let location = location(of: id) else { return }
        change(&segments[location.segment][location.row][location.offset])
    }

    /// Append to the last row of the last group, opening a group when the
    /// strip has none. "The end of the strip" in the order it is read.
    public mutating func append(_ token: MenuBarToken) {
        guard let segment = segments.indices.last else {
            segments.append(MenuBarSegment(tokens: [token]))
            return
        }
        append(token, to: RowAddress(
            segment: segments[segment].id,
            row: segments[segment].isStacked ? .bottom : .top
        ))
    }

    public mutating func append(_ token: MenuBarToken, to address: RowAddress?) {
        guard let address, let segment = segmentIndex(of: address.segment) else {
            segments.append(MenuBarSegment(tokens: [token]))
            return
        }
        // A row that has since been closed took its blocks up with it, so a
        // block aimed at it belongs where they went rather than in a group of
        // its own.
        let row: MenuBarSegment.Row = segments[segment].isStacked ? address.row : .top
        segments[segment][row].append(token)
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard let location = location(of: id) else { return false }
        segments[location.segment][location.row].remove(at: location.offset)
        // Removing one member leaves the rest bound; removing the
        // second-to-last leaves a group of one, which is not a group.
        normalizeGroups()
        return true
    }

    /// Copy a block in place, directly after the original. The copy is a new
    /// block, so it gets a new identity — two blocks that render identically
    /// are still two blocks the editor can drag apart.
    /// Returns the copy's id so the editor can select what it just made.
    @discardableResult
    public mutating func duplicate(_ id: UUID) -> UUID? {
        guard let location = location(of: id) else { return nil }
        var copy = segments[location.segment][location.row][location.offset]
        copy.id = UUID()
        // The copy lands inside the run, so it joins it rather than splitting
        // it — carrying `groupID` over is what keeps that true.
        segments[location.segment][location.row].insert(copy, at: location.offset + 1)
        return copy.id
    }

    /// Move `id` into `target`'s row, immediately before it. No-op when they
    /// are the same block.
    ///
    /// Row-relative rather than flattened, because a flattened index cannot
    /// say which side of a boundary it means — and a drag onto the first chip
    /// of a row has to land *in* that row or the gesture does nothing.
    ///
    /// A grouped block brings its whole run: that is what being in a group
    /// means, and dragging one member out of the middle of one would break
    /// the invariant the group is holding.
    public mutating func move(_ id: UUID, before target: UUID) {
        let run = groupedRun(of: id)
        // Both ends checked before anything is lifted. Validating the target
        // afterwards could not recover: the source is already out, so the
        // "put it back" lookup finds nothing and strands the run in a segment
        // of its own — a move to nowhere would rearrange the strip.
        guard !run.contains(target),
              location(of: target) != nil,
              let origin = location(of: id)
        else { return }
        let lifted = lift(run)
        guard !lifted.isEmpty else { return }
        guard let destination = location(of: target) else {
            reinsert(lifted, at: origin)
            return
        }
        segments[destination.segment][destination.row]
            .insert(contentsOf: lifted, at: destination.offset)
        normalizeGroups()
    }

    /// Move `id` to the end of a row — the trailing landing strip a drag aims
    /// at when it is past every chip.
    public mutating func move(_ id: UUID, toEndOf address: RowAddress) {
        guard let destination = segmentIndex(of: address.segment),
              address.row == .top || segments[destination].isStacked
        else { return }
        let lifted = lift(groupedRun(of: id))
        guard !lifted.isEmpty else { return }
        segments[destination][address.row].append(contentsOf: lifted)
        normalizeGroups()
    }

    /// Take a run of blocks out of the arrangement, in row order. Empty when
    /// the ids are not all present.
    private mutating func lift(_ ids: [UUID]) -> [MenuBarToken] {
        let ordered = ids.compactMap { id -> (Location, MenuBarToken)? in
            guard let at = location(of: id) else { return nil }
            return (at, segments[at.segment][at.row][at.offset])
        }
        guard ordered.count == ids.count else { return [] }
        // Back to front, so each removal leaves the offsets before it intact.
        for (at, _) in ordered.sorted(by: { $0.0.offset > $1.0.offset }) {
            segments[at.segment][at.row].remove(at: at.offset)
        }
        return ordered.map(\.1)
    }

    /// Put a lifted run back where it came from, for a move that could not
    /// find its destination after the lift.
    private mutating func reinsert(_ tokens: [MenuBarToken], at location: Location?) {
        guard !tokens.isEmpty else { return }
        guard let location else {
            segments.append(MenuBarSegment(tokens: tokens))
            return
        }
        let row = segments[location.segment][location.row]
        segments[location.segment][location.row]
            .insert(contentsOf: tokens, at: Swift.max(0, Swift.min(location.offset, row.count)))
    }

    // MARK: Blocks bound together

    /// The run `id` belongs to, in row order — `[id]` alone when it is not
    /// bound to anything.
    public func groupedRun(of id: UUID) -> [UUID] {
        guard let at = location(of: id),
              let group = segments[at.segment][at.row][at.offset].groupID
        else { return [id] }
        return segments[at.segment][at.row].filter { $0.groupID == group }.map(\.id)
    }

    /// Whether `id` is bound to at least one other block.
    ///
    /// Walks the strip, so a caller asking once per block is quadratic — the
    /// editor draws every chip on every body pass and reads `boundGroupIDs`
    /// once instead.
    public func isGrouped(_ id: UUID) -> Bool {
        groupedRun(of: id).count > 1
    }

    /// Every binding that is real: an id held by more than one block. One walk
    /// of the strip, for callers that need the answer for all of them.
    public var boundGroupIDs: Set<UUID> {
        var counts: [UUID: Int] = [:]
        for segment in segments {
            for row in MenuBarSegment.Row.allCases {
                for token in segment[row] {
                    guard let group = token.groupID else { continue }
                    counts[group, default: 0] += 1
                }
            }
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// Bind blocks that already sit side by side in one row.
    ///
    /// Refused rather than repaired when they do not: two blocks with a third
    /// between them are not a run, and quietly moving that third one is an
    /// edit the user did not ask for. Returns the new group's id.
    @discardableResult
    public mutating func group(_ ids: [UUID]) -> UUID? {
        guard let run = contiguousRun(ids) else { return nil }
        let group = UUID()
        for offset in run.offsets {
            segments[run.segment][run.row][offset].groupID = group
        }
        // Binding B and C when A-B were bound leaves A holding an id nobody
        // else has. It is not a group any more, and a stale one would be
        // copied by `duplicate` and quietly bind the copy to nothing.
        normalizeGroups()
        return group
    }

    /// Whether `group(_:)` would bind these. One predicate, so the button that
    /// offers the action and the action itself cannot disagree about it.
    public func canGroup(_ ids: [UUID]) -> Bool {
        contiguousRun(ids) != nil
    }

    /// Where these blocks are, if they are two or more sitting side by side in
    /// one row. `nil` says they are not a run — which is a refusal, not a
    /// problem to fix by moving them.
    private func contiguousRun(
        _ ids: [UUID]
    ) -> (segment: Int, row: MenuBarSegment.Row, offsets: [Int])? {
        let wanted = Set(ids)
        guard wanted.count > 1 else { return nil }
        // One walk of the strip rather than `location(of:)` per id, which
        // scans it each time: this runs on every redraw while a selection is
        // being built, and a big selection on a big strip made that quadratic.
        var home: (segment: Int, row: MenuBarSegment.Row)?
        var offsets: [Int] = []
        for segmentIndex in segments.indices {
            for row in MenuBarSegment.Row.allCases {
                for (offset, token) in segments[segmentIndex][row].enumerated()
                where wanted.contains(token.id) {
                    if let home {
                        // A selection spanning two rows is not a run, and
                        // finding that out early costs nothing.
                        guard home == (segmentIndex, row) else { return nil }
                    } else {
                        home = (segmentIndex, row)
                    }
                    offsets.append(offset)
                }
            }
        }
        guard let home, offsets.count == wanted.count else { return nil }
        offsets.sort()
        guard offsets.last! - offsets.first! == offsets.count - 1 else { return nil }
        return (home.segment, home.row, offsets)
    }

    /// Unbind the run `id` belongs to. The blocks stay exactly where they are.
    public mutating func ungroup(_ id: UUID) {
        guard let at = location(of: id),
              let group = segments[at.segment][at.row][at.offset].groupID
        else { return }
        for index in segments[at.segment][at.row].indices
        where segments[at.segment][at.row][index].groupID == group {
            segments[at.segment][at.row][index].groupID = nil
        }
    }

    /// Dissolve every binding that is no longer true.
    ///
    /// Two ways a group stops being one: an edit scattered its members — into
    /// another row, or with a stranger dropped between them — or it is down to
    /// its last block. Both dissolve rather than repair, so an edit never
    /// silently reorders the strip to preserve a binding.
    ///
    /// Every structural mutation ends here, which is what lets the operations
    /// above stay simple: they move blocks, and this decides what survives.
    public mutating func normalizeGroups() {
        // Every id, everywhere. A row-local pass cannot see a four-block group
        // cut 2+2 by a template change: each half is contiguous inside its own
        // row, so both would survive holding the same id, and a later merge
        // would fuse two runs the user never bound together.
        struct Placement { var row: (segment: Int, row: MenuBarSegment.Row); var offsets: [Int] }
        var seen: [UUID: Placement] = [:]
        var doomed: Set<UUID> = []
        for segmentIndex in segments.indices {
            for row in MenuBarSegment.Row.allCases {
                for (offset, token) in segments[segmentIndex][row].enumerated() {
                    guard let group = token.groupID else { continue }
                    if var placement = seen[group] {
                        guard placement.row == (segmentIndex, row) else {
                            doomed.insert(group)
                            continue
                        }
                        placement.offsets.append(offset)
                        seen[group] = placement
                    } else {
                        seen[group] = Placement(row: (segmentIndex, row), offsets: [offset])
                    }
                }
            }
        }
        for (group, placement) in seen {
            let offsets = placement.offsets.sorted()
            let contiguous = offsets.last! - offsets.first! == offsets.count - 1
            if offsets.count < 2 || !contiguous { doomed.insert(group) }
        }
        guard !doomed.isEmpty else { return }
        for segmentIndex in segments.indices {
            for row in MenuBarSegment.Row.allCases {
                for offset in segments[segmentIndex][row].indices {
                    guard let group = segments[segmentIndex][row][offset].groupID,
                          doomed.contains(group)
                    else { continue }
                    segments[segmentIndex][row][offset].groupID = nil
                }
            }
        }
    }

    // MARK: Segments

    public func segmentIndex(of id: UUID) -> Int? {
        segments.firstIndex { $0.id == id }
    }

    /// Add an empty group at the end. Blocks are dragged into it, or added to
    /// it while it is selected.
    @discardableResult
    public mutating func appendSegment(_ segment: MenuBarSegment = MenuBarSegment()) -> UUID {
        segments.append(segment)
        // Presets arrive through here, and they carry blocks this composition
        // has never normalized: a preset whose own file lost one member's
        // binding would land as a run with a stranger through it.
        normalizeGroups()
        return segment.id
    }

    @discardableResult
    public mutating func removeSegment(_ id: UUID) -> Bool {
        guard let index = segmentIndex(of: id) else { return false }
        segments.remove(at: index)
        return true
    }

    /// Move a group `offset` places left (negative) or right (positive),
    /// clamped so the ends are no-ops rather than traps.
    public mutating func moveSegment(_ id: UUID, by offset: Int) {
        guard let index = segmentIndex(of: id) else { return }
        let destination = Swift.max(0, Swift.min(index + offset, segments.count - 1))
        guard destination != index else { return }
        let segment = segments.remove(at: index)
        segments.insert(segment, at: destination)
    }

    /// Give a group a second row.
    ///
    /// Per group, not per strip: every group is its own column with its own
    /// two rows, so a group beside a stacked one can still be given a row.
    @discardableResult
    public mutating func addRow(toSegment id: UUID) -> Bool {
        guard let index = segmentIndex(of: id), !segments[index].isStacked else { return false }
        segments[index].addRow()
        return true
    }

    /// Close a group's second row, its blocks joining the end of the first.
    @discardableResult
    public mutating func removeRow(fromSegment id: UUID) -> Bool {
        guard let index = segmentIndex(of: id), segments[index].isStacked else { return false }
        segments[index].removeRow()
        return true
    }

    /// Whether `segment` can still be given a second row.
    public func canAddRow(toSegment id: UUID) -> Bool {
        guard let index = segmentIndex(of: id) else { return false }
        return !segments[index].isStacked
    }

    /// Start a new group at `id`, which becomes the first block of its top row.
    ///
    /// The blocks after it come along, and so does the second row: splitting a
    /// column is a vertical cut, not a lift. Only offered inside a top row —
    /// cutting through a bottom row alone would leave one group with a hole
    /// where its first cell should be, which is not a column the strip can
    /// draw and not a shape the editor should let anyone build.
    /// Whether `splitSegment(before:)` would do anything — the predicate the
    /// button offering it reads, so a visible action is never a no-op.
    ///
    /// Never through a run: a group with half in each column would dissolve,
    /// which is not what "start a segment here" says it does. A run's first
    /// block may start a segment; a later member may not.
    public func canSplitSegment(before id: UUID) -> Bool {
        guard let location = location(of: id),
              location.row == .top,
              location.offset > 0
        else { return false }
        return groupedRun(of: id).first == id
    }

    public mutating func splitSegment(before id: UUID) {
        guard canSplitSegment(before: id), let location = location(of: id) else { return }
        let moved = Array(segments[location.segment].top[location.offset...])
        segments[location.segment].top.removeSubrange(location.offset...)
        let bottom = segments[location.segment].bottom
        segments[location.segment].bottom = nil
        segments.insert(
            MenuBarSegment(top: moved, bottom: bottom),
            at: location.segment + 1
        )
        normalizeGroups()
    }

    /// Fold a group into the one before it. The inverse of `splitSegment`.
    ///
    /// Row by row: the folded group's top joins the previous group's top and
    /// its bottom joins the previous group's bottom, so two stacked columns
    /// merge into one stacked column rather than into one long row.
    public mutating func mergeSegmentIntoPrevious(_ id: UUID) {
        guard let index = segmentIndex(of: id), index > 0 else { return }
        let folded = segments.remove(at: index)
        segments[index - 1].top.append(contentsOf: folded.top)
        guard let bottom = folded.bottom else { return }
        if segments[index - 1].bottom == nil {
            segments[index - 1].bottom = bottom
        } else {
            segments[index - 1].bottom?.append(contentsOf: bottom)
        }
        normalizeGroups()
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
            segments: seedSegments(
                template: template,
                item: item,
                registry: registry,
                groupCatalogLabel: groupCatalogLabel
            )
        )
    }

    private static func seedSegments(
        template: Template,
        item: MenuBarItemSettings,
        registry: QuotaFieldRegistry,
        groupCatalogLabel: (String) -> String?
    ) -> [MenuBarSegment] {
        // Icon Only draws one glyph and nothing else — not the selected
        // fields, which it ignores entirely. Expanding them here would greet
        // the user with a four-quota strip they have never seen, which is the
        // opposite of "start from what you already have".
        if item.layout == .iconOnly {
            return [MenuBarSegment(tokens: [MenuBarToken(kind: .appIcon, style: .label)])]
        }

        let fields = item.selectedFieldIds.compactMap {
            MenuBarFieldCatalog.field(id: $0, registry: registry)
        }
        let runs = MenuBarFieldCatalog.runs(fields, merging: item.mergesGroupWindows)
        // A stacked strip is a row of two-cell columns, and now the model can
        // say so. Before segments existed the seed had to flatten that into
        // two long rows, which lost the pairing — `5 Hours` no longer sat
        // above `Weekly` — the divergence this function used to have to
        // apologise for. A group *is* a column, and a group with one row is
        // the one-cell column the rasterizer centres across both rows.
        if item.layout == .twoRows || template.seedsSecondRow, runs.count > 1 {
            var segments: [MenuBarSegment] = []
            var index = 0
            while index < runs.count {
                let top = seedRunTokens(runs[index], item: item, groupCatalogLabel: groupCatalogLabel)
                let bottom = index + 1 < runs.count
                    ? seedRunTokens(
                        runs[index + 1],
                        item: item,
                        groupCatalogLabel: groupCatalogLabel
                    )
                    : nil
                segments.append(MenuBarSegment(top: top, bottom: bottom))
                index += 2
            }
            // Nothing between two columns: the rasterizer spaces them, which
            // is the answer `MenuBarFieldStripRules` gives for this layout.
            return segments
        }

        // One row, one group — byte for byte the strip this seed has always
        // produced. Splitting it into a group per entry would move the
        // dividers out of the blocks the user can edit and into a template
        // rule they cannot, which is a worse strip for a tidier model.
        var tokens: [MenuBarToken] = []
        let separator = MenuBarFieldStripRules.separator(for: item.layout)
        for (index, run) in runs.enumerated() {
            if index > 0, let separator {
                tokens.append(MenuBarToken(kind: separator, style: .divider))
            }
            tokens.append(contentsOf: seedRunTokens(
                run,
                item: item,
                groupCatalogLabel: groupCatalogLabel
            ))
        }
        return tokens.isEmpty ? [] : [MenuBarSegment(tokens: tokens)]
    }

    /// One entry: its logo and label where the field style shows them, then a
    /// percentage per window, slash-joined when the group is merged.
    private static func seedRunTokens(
        _ run: MenuBarFieldRun,
        item: MenuBarItemSettings,
        groupCatalogLabel: (String) -> String?
    ) -> [MenuBarToken] {
        var tokens: [MenuBarToken] = []
        // The style the renderer honours on this layout, not the one stored:
        // Single line draws words only, so a saved logo style must not put a
        // logo on a strip that has never shown one.
        let style = MenuBarFieldStripRules.effectiveStyle(
            item.style(for: run.primary.id),
            layout: item.layout
        )
        if style != .labelAndPercent {
            tokens.append(MenuBarToken(kind: .logo(run.primary.tool), style: .label))
        }
        if style != .logoAndPercent {
            tokens.append(seedLabelToken(
                run,
                item: item,
                groupCatalogLabel: groupCatalogLabel
            ))
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
    /// The block that names an entry.
    ///
    /// Two genuinely different things, kept apart in the *model* rather than
    /// only in this function:
    ///
    /// - A name the user typed is `.text`. It is theirs, it is derived from
    ///   nothing, and it is stored verbatim and never translated.
    /// - A name the app derives from the quota is `.quota(_, .label)` — a
    ///   *reference*, resolved when the strip is drawn. Seeding the resolved
    ///   words instead would freeze whichever language was selected at that
    ///   moment into `settings.json`: seed in Chinese, switch to English, and
    ///   the strip would stay Chinese forever.
    ///
    /// A merged group is the third case and is a literal on purpose: its name
    /// is a naming-axis identifier — a SubProvider, a model-group name — or
    /// the user's own rename, and `AGENTS.md` § 7.1 says neither is
    /// translated.
    ///
    /// A strip seeded by an earlier build carries the resolved words as
    /// `.text` and is **left alone**. There is no way to tell a seeded literal
    /// from one the user typed over — the model says a `.text` block is the
    /// user's text — so migrating would mean rewriting content on a guess, and
    /// guessing wrong silently edits something they wrote. "Start over from
    /// the current strip" is the explicit way to adopt the new shape.
    private static func seedLabelToken(
        _ run: MenuBarFieldRun,
        item: MenuBarItemSettings,
        groupCatalogLabel: (String) -> String?
    ) -> MenuBarToken {
        if run.isMerged {
            return MenuBarToken(
                kind: .text(MenuBarFieldCatalog.mergedGroupLabel(
                    for: run,
                    customLabels: item.customLabels,
                    groupCatalogLabel: groupCatalogLabel
                )),
                style: .label
            )
        }
        let custom = item.customLabels[run.primary.id]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty {
            return MenuBarToken(kind: .text(custom), style: .label)
        }
        return MenuBarToken(
            kind: .quota(fieldId: run.primary.id, metric: .label),
            style: .label
        )
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case template
        case tokens
        case segments
        case fontScale
        case tokenSpacing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.template = (try? c.decodeIfPresent(Template.self, forKey: .template)) ?? .roomy
        // `segments` is what this build writes and what it reads back. `tokens`
        // is the flattened mirror below, and it is the *only* thing a build
        // that predates segments knows how to read or write — so a file that
        // has been through one carries `tokens` and no `segments`, and its
        // whole strip decodes as a single group, its rows taken from where the
        // break marker sat. That is the honest maximum: the blocks all survive
        // the round trip, the grouping cannot, and nothing here rewrites a
        // block to make up the difference.
        //
        // Lossy per token throughout: a block kind a future build introduces
        // is dropped rather than taking the whole settings file down with it.
        let storedSegments = (try? c.decodeIfPresent([LossyMenuBarSegment].self, forKey: .segments))
            .flatMap { $0 }
        if let storedSegments {
            self.segments = storedSegments.compactMap(\.value)
        } else {
            let stored = try c.decodeIfPresent([MenuBarFlatToken].self, forKey: .tokens) ?? []
            let rows = MenuBarFlatToken.rows(stored)
            self.segments = rows.top.isEmpty && (rows.bottom?.isEmpty ?? true)
                ? []
                : [MenuBarSegment(top: rows.top, bottom: rows.bottom)]
        }
        // `try?`, not `try`: a malformed number here used to throw, and the
        // item's own decoder catches that into `composition = nil` — losing
        // every block over one bad scalar.
        self.fontScale = (try? c.decode(Double.self, forKey: .fontScale))
            .map { $0.clamped(to: Self.fontScaleRange) }
        self.tokenSpacing = (try? c.decode(Double.self, forKey: .tokenSpacing))
            .map { $0.clamped(to: Self.tokenSpacingRange) }
        // Settings are hand-editable and a decode is tolerant: one member's
        // `groupID` can arrive missing or malformed while its siblings keep
        // theirs, which leaves a group with a stranger through it. Nothing
        // else would notice — `groupedRun` filters the row by id and does
        // not check contiguity — so dragging one member would carry blocks
        // across the one between them.
        normalizeGroups()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(template, forKey: .template)
        try c.encode(segments, forKey: .segments)
        // The mirror. A build without rows or groups reads this key and only
        // this key, and a downgrade that finds nothing in it draws an empty
        // status item and then writes that emptiness back — which is how this
        // feature deleted a user's blocks once already. So every block is
        // written twice, and the shape chosen is the one that survives best:
        // every group's top row in order, then the break marker, then every
        // group's bottom row. An older build reads that as the two rows it has
        // always drawn, in the reading order the columns had.
        try c.encode(flattenedTokens, forKey: .tokens)
        try c.encodeIfPresent(fontScale, forKey: .fontScale)
        try c.encodeIfPresent(tokenSpacing, forKey: .tokenSpacing)
    }

    /// The strip as one list, for a reader that has no idea what a group or a
    /// row container is.
    ///
    /// Content-faithful and nothing more: it materialises neither the divider
    /// this build draws between two groups on a one-row strip, nor a break
    /// with nothing after it. Both are rules rather than blocks, and writing
    /// either into the mirror would hand the user something they never made
    /// the first time the file came back.
    var flattenedTokens: [MenuBarFlatToken] {
        let tops = segments.flatMap(\.top).map(MenuBarFlatToken.token)
        let bottoms = segments.compactMap(\.bottom).flatMap { $0 }.map(MenuBarFlatToken.token)
        guard !bottoms.isEmpty else { return tops }
        return tops + [.rowBreak] + bottoms
    }
}

/// One entry of the flat `tokens` list: a block, or the marker that ends the
/// first row.
///
/// The marker is a wire value, not a block. `MenuBarToken.Kind` used to carry a
/// `.lineBreak` case, and every place that had to refuse it — the palette, the
/// inspector, the size and colour controls, the planner's row split, the
/// per-group cap — was a rule about a value the type still allowed. Rows are
/// containers now, so the marker exists only where it is actually needed: on
/// the way out, so a build that reads nothing but the flat list still draws two
/// rows, and on the way in, so a file written before rows were containers
/// splits where its break sat.
enum MenuBarFlatToken: Codable {
    /// Nil for an entry this build could not read at all; dropped, the way
    /// `LossyMenuBarToken` drops one.
    case token(MenuBarToken?)
    case rowBreak

    /// What a row break is spelled as in a stored file. Unchanged from when it
    /// was a `Kind` discriminator, because that is exactly what an older build
    /// is looking for.
    static let rowBreakDiscriminator = "lineBreak"

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    private enum KindKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
           let kind = try? c.nestedContainer(keyedBy: KindKeys.self, forKey: .kind),
           (try? kind.decode(String.self, forKey: .type)) == Self.rowBreakDiscriminator {
            self = .rowBreak
            return
        }
        self = .token(try? MenuBarToken(from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .token(token):
            try token?.encode(to: encoder)
        case .rowBreak:
            // Kind and nothing else. Every build that can read this list at
            // all defaults the identity, the style and the rule when they are
            // absent, so the marker adds no bytes that change between saves.
            var c = encoder.container(keyedBy: CodingKeys.self)
            var kind = c.nestedContainer(keyedBy: KindKeys.self, forKey: .kind)
            try kind.encode(Self.rowBreakDiscriminator, forKey: .type)
        }
    }

    /// A stored flat list as the two rows it describes.
    ///
    /// A second marker cannot open a third row, so its blocks stay on the
    /// bottom — exactly the folding the flat model already did when it met one.
    static func rows(_ entries: [MenuBarFlatToken]) -> (top: [MenuBarToken], bottom: [MenuBarToken]?) {
        var top: [MenuBarToken] = []
        var bottom: [MenuBarToken]?
        for entry in entries {
            switch entry {
            case .rowBreak:
                if bottom == nil { bottom = [] }
            case let .token(token):
                guard let token else { continue }
                if bottom == nil { top.append(token) } else { bottom?.append(token) }
            }
        }
        return (top, bottom)
    }
}

/// Tolerant wrapper so one unreadable group cannot discard the rest.
private struct LossyMenuBarSegment: Codable {
    let value: MenuBarSegment?

    init(from decoder: Decoder) throws {
        self.value = try? MenuBarSegment(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value?.encode(to: encoder)
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

/// One group, ready to draw: the cell on top and, when the group has a row
/// break the rules currently allow, the cell underneath.
///
/// This is what `twoRowMenuColumns` already builds for the field-based strip —
/// the composed path now produces the same shape rather than two flat rows, so
/// one rasterizer draws both.
public struct MenuBarRenderColumn: Equatable, Sendable {
    public var top: MenuBarRenderRow
    /// Nil for a one-cell column, which the rasterizer centres across both
    /// rows. That is what lets a strip say "this label spans the height".
    public var bottom: MenuBarRenderRow?

    public init(top: MenuBarRenderRow, bottom: MenuBarRenderRow? = nil) {
        self.top = top
        self.bottom = bottom
    }

    public var isEmpty: Bool { top.isEmpty && (bottom?.isEmpty ?? true) }
}

/// Everything the status item needs for one render of a composed strip.
public struct MenuBarRenderPlan: Equatable, Sendable {
    public var columns: [MenuBarRenderColumn]
    /// What the renderer draws between two adjacent columns when the strip is
    /// only one row tall — the template's own divider, from
    /// `MenuBarFieldStripRules`. Nil where that layout draws none and the
    /// strip's spacing does the work. A two-row strip separates its columns
    /// with space, never a character, so this is ignored there.
    public var columnSeparator: String?
    /// Gap between adjacent blocks, as a multiplier on the base font size.
    public var tokenSpacing: Double
    /// Multiplier on the base font size for the whole strip.
    public var fontScale: Double
    /// The strip in words, one clause per meaningful block, columns joined
    /// with " · ". Never the drawn shorthand — this is what a screen reader
    /// and the tooltip say.
    public var spokenDescription: String

    public init(
        columns: [MenuBarRenderColumn],
        columnSeparator: String? = nil,
        tokenSpacing: Double,
        fontScale: Double,
        spokenDescription: String
    ) {
        self.columns = columns
        self.columnSeparator = columnSeparator
        self.tokenSpacing = tokenSpacing
        self.fontScale = fontScale
        self.spokenDescription = spokenDescription
    }

    /// Whether the strip stacks. One column with a bottom cell is enough: the
    /// rasterizer draws the whole image then, and a column without one is
    /// centred inside it.
    public var isTwoRow: Bool { columns.contains { $0.bottom != nil } }

    /// The strip as rows, columns flattened left to right.
    ///
    /// A derived view for everything that reasons about the strip as lines
    /// rather than as groups — which is what a one-group strip has always
    /// been, and what most of this type's tests are written against.
    public var rows: [MenuBarRenderRow] {
        let top = MenuBarRenderRow(tokens: columns.flatMap(\.top.tokens))
        guard isTwoRow else { return [top] }
        return [top, MenuBarRenderRow(tokens: columns.compactMap(\.bottom).flatMap(\.tokens))]
    }

    /// Nothing survived: every block was hidden, or every quota it named is
    /// unavailable. The renderer draws the same "—" the field path draws.
    public var isEmpty: Bool { columns.allSatisfy(\.isEmpty) }
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
        now: Date = Date(),
        canvas: MenuBarStripCanvas = .nominalTwoRow
    ) -> MenuBarRenderPlan {
        let scale = effectiveFontScale

        func snapshot(_ fieldId: String?) -> MenuBarQuotaSnapshot? {
            guard let fieldId else { return nil }
            return quotas.first { $0.fieldId == fieldId }
        }

        /// One cell: the blocks that survive their rules, drawn.
        func cell(_ tokens: [MenuBarToken], echoed: Set<UUID>) -> (row: MenuBarRenderRow, spoken: [String]) {
            var row = MenuBarRenderRow()
            var spokenClauses: [String] = []
            for token in tokens {
                guard Self.isVisible(token.visibility, quotas: quotas) else { continue }
                let own = snapshot(token.quotaFieldId)
                guard let content = Self.content(
                    for: token,
                    quota: own,
                    displayMode: displayMode,
                    now: now
                ) else { continue }
                let spoken = echoed.contains(token.id) ? nil : content.spoken
                row.tokens.append(MenuBarRenderedToken(
                    id: token.id,
                    text: content.text,
                    glyph: content.glyph,
                    color: Self.colorRole(
                        for: token,
                        own: own,
                        quotas: quotas,
                        colorBasis: colorBasis
                    ),
                    fontScale: scale * token.style.size.multiplier,
                    weight: token.style.weight,
                    monospacedDigits: token.style.monospacedDigits,
                    spoken: spoken
                ))
                if let spoken { spokenClauses.append(spoken) }
            }
            return (row, spokenClauses)
        }

        var columns: [MenuBarRenderColumn] = []
        var spokenColumns: [String] = []
        for segment in segments {
            // A seeded strip draws `5 Hours` and then `5 Hours 73% used`. That
            // is what the bar has always looked like, so the block keeps
            // drawing — but read aloud it stutters every field name, so it
            // stops speaking. Per row: a name at the end of one cell does not
            // name the number at the start of the next.
            func echoes(_ tokens: [MenuBarToken]) -> Set<UUID> {
                Self.labelEchoTokenIds(
                    tokens: tokens,
                    quotas: quotas,
                    displayMode: displayMode,
                    now: now
                )
            }
            let top = cell(segment.top, echoed: echoes(segment.top))
            let bottom = segment.bottom.map { cell($0, echoed: echoes($0)) }

            // A cell whose blocks all fell away is not a cell. A group left
            // with only its lower cell collapses to a one-cell column rather
            // than a column with a hole in it, which is the same thing the
            // renderers used to do by filtering empty rows.
            var column: MenuBarRenderColumn
            switch (top.row.isEmpty, bottom?.row.isEmpty ?? true) {
            case (true, true):
                continue
            case (true, false):
                column = MenuBarRenderColumn(top: bottom!.row)
            case (false, true):
                column = MenuBarRenderColumn(top: top.row)
            case (false, false):
                column = MenuBarRenderColumn(top: top.row, bottom: bottom!.row)
            }
            columns.append(column)
            // One entry per *cell*, column-major — which is the order a
            // stacked strip is read in, and the same order the seed packs
            // entries into columns. Blocks inside a cell are joined with a
            // comma and cells with " · ", so a one-group strip is described
            // exactly as it was before groups existed.
            for cell in [top.spoken, bottom?.spoken ?? []] {
                let clause = cell.filter { !$0.isEmpty }.joined(separator: ", ")
                if !clause.isEmpty { spokenColumns.append(clause) }
            }
        }


        return MenuBarRenderPlan(
            columns: columns,
            columnSeparator: Self.columnSeparatorText(template: template),
            tokenSpacing: effectiveTokenSpacing,
            fontScale: scale,
            spokenDescription: spokenColumns.joined(separator: " · ")
        )
    }

    /// The divider a one-row strip draws between two groups.
    ///
    /// From the same table the seed reads, so a strip that was seeded from a
    /// layout and then grouped by hand is separated the way that layout
    /// separates its entries — a middle dot on Single line, nothing but space
    /// on Compact and Two rows.
    private static func columnSeparatorText(template: Template) -> String? {
        guard case let .separator(text)? = template.inlineSeparator else { return nil }
        return text
    }

    /// Give a size choice back to the block that made it.
    ///
    /// A two-row strip shares one ~18–20pt canvas, so a block cannot grow
    /// without something giving. What used to give was *the whole strip*: the
    /// content was measured, one uniform scale was solved for, and every block
    /// shrank — so choosing Large for one number made every other number
    /// smaller, which is the opposite of what the control says.
    ///
    /// The rule now: a block's size choice costs the block that made it and
    /// nothing else. Each row's ceiling is worked out from the height that row
    /// would occupy with every block at the strip's own scale — the size
    /// nobody chose — and the surplus left over is what growth may spend,
    /// shared between the rows that asked for it. A row that asked for nothing
    /// keeps exactly the size it had; a row that asked for more gets as much
    /// of it as the canvas can pay for. When even the untouched strip does not
    /// fit, nobody's choice caused that and the shrink is uniform again.
    ///
    /// One row is not fitted at all: it has the whole bar, and a Large block
    /// there simply is large.
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
            // A block that names a quota, either way it can be written: words
            // the user typed, or a reference to the quota's own name.
            let typed: String?
            let referenced: String?
            switch token.kind {
            case let .text(text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                (typed, referenced) = (trimmed, nil)
            case let .quota(fieldId, .label):
                (typed, referenced) = (nil, fieldId)
            default:
                continue
            }
            var cursor = index + 1
            scan: while cursor < tokens.count {
                switch tokens[cursor].kind {
                case .space, .separator:
                    cursor += 1
                case let .quota(fieldId, metric):
                    // Two names in a row is not an echo; the second is not
                    // saying anything the first already said.
                    guard metric != .label else { break scan }
                    guard let quota = quotas.first(where: { $0.fieldId == fieldId }),
                          isVisible(tokens[cursor].visibility, quotas: quotas),
                          value(
                              of: metric,
                              in: quota,
                              displayMode: displayMode,
                              resetFormat: tokens[cursor].style.resetFormat,
                              now: now
                          ) != nil
                    else { break scan }
                    let echoes = referenced.map { $0 == fieldId }
                        ?? (quota.label.trimmingCharacters(in: .whitespacesAndNewlines)
                            .caseInsensitiveCompare(typed ?? "") == .orderedSame)
                    if echoes { echoed.insert(token.id) }
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
            // A text block with nothing in it draws nothing — no reserved gap.
            // The menu bar is the most width-constrained surface in the app,
            // and spending pixels on a block that has nothing to say reads as
            // a rendering fault rather than as an empty field. The block is
            // still there in the editor, which says so.
            //
            // Whitespace the user typed is content: they wanted a gap.
            guard !text.isEmpty else { return nil }
            return TokenContent(
                text: MenuBarToken.truncated(text),
                glyph: nil,
                // The full string, not the drawn one: a screen reader should
                // hear what the user wrote.
                spoken: trimmed.isEmpty ? nil : trimmed
            )
        case let .space(width):
            return TokenContent(
                text: String(repeating: " ", count: MenuBarToken.clampedSpaceWidth(width)),
                glyph: nil,
                spoken: nil
            )
        case let .separator(separator):
            guard !separator.isEmpty else { return nil }
            return TokenContent(text: MenuBarToken.truncated(separator), glyph: nil, spoken: nil)
        case .unsupported:
            // Nothing to draw: this build does not know what it is. It is on
            // the strip only so the next save hands it back.
            return nil
        case let .quota(_, metric):
            // A bucket the provider is not returning right now takes its block
            // off the strip and leaves everything else alone.
            guard let quota,
                  let text = value(
                      of: metric,
                      in: quota,
                      displayMode: displayMode,
                      resetFormat: token.style.resetFormat,
                      now: now
                  )
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
        resetFormat: ResetTimeFormat,
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
            return ResetCountdownFormatter.absoluteTime(
                for: resetAt, now: now, format: resetFormat
            )
        case .runsOutIn:
            guard let runOutAt = quota.forecast?.runOutAt else { return nil }
            return ResetCountdownFormatter.string(from: runOutAt, now: now)
        case .label:
            let trimmed = quota.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func percent(_ value: Double) -> String {
        // Through the shared seam rather than a local "%": the sign's place is
        // a language's decision, and `common.percent` is where that is made.
        L10n.Common.percent(value: Int(value.rounded()))
    }

    private static func spokenClause(
        metric: MenuBarQuotaMetric,
        value: String,
        quota: MenuBarQuotaSnapshot,
        displayMode: DisplayMode
    ) -> String {
        // One key per sentence, with the label and the figure as named
        // placeholders: Chinese does not put the verb where English does, so a
        // clause assembled by concatenation would come out wrong.
        switch metric {
        case .label:
            return value
        case .usedPercent:
            return L10n.MenuBar.spokenUsed(label: quota.label, value: value)
        case .remainingPercent:
            return L10n.MenuBar.spokenRemaining(label: quota.label, value: value)
        case .displayPercent:
            return displayMode == .used
                ? L10n.MenuBar.spokenUsed(label: quota.label, value: value)
                : L10n.MenuBar.spokenRemaining(label: quota.label, value: value)
        case .pace:
            return L10n.MenuBar.spokenPace(label: quota.label, value: value)
        case .forecastPercent:
            return L10n.MenuBar.spokenForecast(label: quota.label, value: value)
        case .resetsIn:
            return L10n.MenuBar.spokenResetsIn(label: quota.label, value: value)
        case .resetAt:
            return L10n.MenuBar.spokenResetAt(label: quota.label, value: value)
        case .runsOutIn:
            return L10n.MenuBar.spokenRunsOutIn(label: quota.label, value: value)
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
        case width
    }

    private enum Discriminator: String, Codable {
        case logo, text, quota, space, separator, appIcon
    }

    public init(from decoder: Decoder) throws {
        // Anything unreadable is preserved rather than thrown, which is what
        // stops `LossyMenuBarToken` from turning it into a deletion. Covers a
        // discriminator this build lacks *and* a payload it cannot parse — a
        // `.logo` naming a provider added after this version, most likely.
        if let known = try? Self.known(from: decoder) {
            self = known
            return
        }
        self = .unsupported(try JSONValue(from: decoder))
    }

    private static func known(from decoder: Decoder) throws -> Self {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Discriminator.self, forKey: .type) {
        case .logo:
            return .logo(try c.decode(ToolType.self, forKey: .tool))
        case .text:
            return .text(try c.decode(String.self, forKey: .text))
        case .quota:
            return .quota(
                fieldId: try c.decode(String.self, forKey: .fieldId),
                // An unknown metric throws, so the block is preserved whole
                // rather than silently becoming a percentage. Defaulting here
                // looked like graceful degradation and was destructive: the
                // next save wrote the substitute back, so a round trip through
                // an older build permanently changed what the user chose.
                metric: try c.decode(MenuBarQuotaMetric.self, forKey: .metric)
            )
        case .space:
            // Absent in every file written before a space had a width, and
            // `try?` rather than `try` because a width this build cannot read
            // is worth a default space — losing the whole block over it would
            // preserve it as `.unsupported`, which draws nothing at all.
            return .space(width: MenuBarToken.clampedSpaceWidth(
                (try? c.decode(Int.self, forKey: .width)) ?? MenuBarToken.defaultSpaceWidth
            ))
        case .separator:
            return .separator(try c.decode(String.self, forKey: .text))
        case .appIcon:
            return .appIcon
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case let .unsupported(raw) = self {
            try raw.encode(to: encoder)
            return
        }
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
        case let .space(width):
            try c.encode(Discriminator.space, forKey: .type)
            // Only when it is not the default, so a strip that predates the
            // width control still writes the bytes it already had. An older
            // build ignores the key and draws one space — the block survives,
            // its width does not, which is the trade a downgrade always makes.
            if width != MenuBarToken.defaultSpaceWidth {
                try c.encode(MenuBarToken.clampedSpaceWidth(width), forKey: .width)
            }
        case let .separator(separator):
            try c.encode(Discriminator.separator, forKey: .type)
            try c.encode(separator, forKey: .text)
        case .appIcon:
            try c.encode(Discriminator.appIcon, forKey: .type)
        case .unsupported:
            break  // handled above, before the keyed container is opened
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
    /// The smallest face the strip is willing to draw at. Nothing enforces it
    /// in `scale` — it is the *property* the supported ranges are chosen to
    /// respect, and `MenuBarCompositionTests` asserts that every supported
    /// combination stays above it. A floor applied inside the arithmetic is
    /// what let two rows keep overflowing: it made the numbers look reasonable
    /// while the rows were still cropped.
    public static let legibleFontSize: Double = 6

    /// Uniform font scale that makes `contentHeight` fit `availableHeight`,
    /// exactly. Returns 1 when it already fits.
    ///
    /// No floor. A scale that does not fit is not a fit — the canvas is capped
    /// afterwards regardless, so returning something too large just moves the
    /// cropping one step later and hides it.
    ///
    /// Still the last word on a *measured* strip: the caps below are solved
    /// from type metrics, and the status item measures real attributed
    /// strings, so this stays as the guard against a glyph or a face that is
    /// taller than the arithmetic expected.
    public static func scale(contentHeight: Double, availableHeight: Double) -> Double {
        guard contentHeight > 0, availableHeight > 0, contentHeight > availableHeight else {
            return 1
        }
        return availableHeight / contentHeight
    }

    /// What a two-row strip may actually draw at.
    public struct Fit: Equatable, Sendable {
        /// Ceiling on each row's font scale. A block draws at
        /// `min(its own scale, this)` — so a block that never asked to be
        /// bigger is never touched by one that did.
        public var rowCaps: [Double]
        /// Shrink applied to the whole strip, 1 unless the strip overflows
        /// with every block already at the size nobody chose.
        public var uniform: Double

        public init(rowCaps: [Double], uniform: Double) {
            self.rowCaps = rowCaps
            self.uniform = uniform
        }

        /// Whether applying this changes anything.
        public var isConstraining: Bool {
            uniform != 1 || rowCaps.contains { $0.isFinite }
        }
    }

    /// Solve the per-row ceilings for a stacked strip.
    ///
    /// `rowScales` is each row's largest requested font scale and
    /// `neutralScale` the strip's own — the size a block that was never
    /// touched draws at. See `MenuBarComposition.fitted` for why the answer is
    /// per row rather than one number for the strip.
    public static func fit(
        rowScales: [Double],
        neutralScale: Double,
        canvas: MenuBarStripCanvas
    ) -> Fit {
        let uncapped = Fit(rowCaps: rowScales.map { _ in .infinity }, uniform: 1)
        guard !rowScales.isEmpty,
              canvas.baseFontSize > 0,
              canvas.availableHeight > 0,
              canvas.lineHeightRatio > 0
        else { return uncapped }

        // Height one unit of font scale costs on one row, and what the gaps
        // between the rows cost regardless.
        let unit = canvas.baseFontSize * canvas.lineHeightRatio
        let gaps = canvas.lineSpacing * Double(rowScales.count - 1)
        let requested = rowScales.reduce(gaps) { $0 + unit * $1 }
        guard requested > canvas.availableHeight else { return uncapped }

        // What the strip would occupy with nothing grown. A row that only got
        // *smaller* keeps its smaller height here: it gave that space back,
        // and taking it away again would be charging it for someone else's
        // choice in the opposite direction.
        let neutral = rowScales.reduce(gaps) { $0 + unit * Swift.min($1, neutralScale) }
        guard neutral < canvas.availableHeight else {
            // Nobody's choice caused this — the bar is simply this short. The
            // only honest answer left is the one this type started with.
            return Fit(
                rowCaps: rowScales.map { Swift.min($0, neutralScale) },
                uniform: scale(contentHeight: neutral, availableHeight: canvas.availableHeight)
            )
        }

        let surplus = canvas.availableHeight - neutral
        let growth = rowScales.reduce(0.0) { $0 + unit * Swift.max(0, $1 - neutralScale) }
        // Shared in proportion to what each row asked for, so two rows that
        // both grew are cut equally rather than first-come-first-served.
        let allowance = growth > 0 ? Swift.min(1, surplus / growth) : 0
        return Fit(
            rowCaps: rowScales.map { requested in
                requested <= neutralScale
                    ? requested
                    : neutralScale + (requested - neutralScale) * allowance
            },
            uniform: 1
        )
    }
}

/// The height a composed strip has to fit into, and the type metrics it is
/// measured with.
///
/// A value rather than a constant because the status bar's thickness is a
/// runtime fact — but the *shape* is the same everywhere, so the planner, the
/// preview and the tests can all state it the same way.
public struct MenuBarStripCanvas: Equatable, Sendable {
    public var availableHeight: Double
    public var baseFontSize: Double
    public var lineHeightRatio: Double
    public var lineSpacing: Double

    public init(
        availableHeight: Double,
        baseFontSize: Double,
        lineHeightRatio: Double,
        lineSpacing: Double
    ) {
        self.availableHeight = availableHeight
        self.baseFontSize = baseFontSize
        self.lineHeightRatio = lineHeightRatio
        self.lineSpacing = lineSpacing
    }

    /// The two-row canvas as the status bar usually presents it. The App
    /// passes the real thickness; this is what a test — and a planner nobody
    /// gave a canvas to — measures against.
    public static let nominalTwoRow = MenuBarStripCanvas(
        availableHeight: MenuBarStripGeometry.nominalTwoRowAvailableHeight,
        baseFontSize: MenuBarStripGeometry.nominalTwoRowFontSize,
        lineHeightRatio: MenuBarStripGeometry.nominalLineHeightRatio,
        lineSpacing: MenuBarStripGeometry.nominalTwoRowLineSpacing
    )
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
/// The rules the field-based renderer draws by.
///
/// Five review rounds found the seed disagreeing with the renderer in five
/// different dimensions — separator characters, row structure, glyph size,
/// font face, and now style coercion and spacing. Each was checked against the
/// dimension that was reported, and none of them stopped the next one, because
/// the two sides kept their own copy of each rule.
///
/// Face and glyph size already live in `MenuBarStripGeometry`, and the layout
/// to template mapping in `Template.matching`. These are the two that were
/// still duplicated. A rule that lives here cannot drift; a rule that does not
/// is a sixth round waiting to happen.
public enum MenuBarFieldStripRules {
    /// What the renderer puts *between* two entries, beyond the ordinary gap
    /// it already leaves between everything.
    ///
    /// Only Single line draws a character. Compact butts entries together with
    /// the same single space it puts between a label and its number, and the
    /// two-row rasterizer separates columns with spacing and draws nothing at
    /// all — so for those the answer is nil and the strip's own token spacing
    /// does the work. Seeding a literal `" · "` and then having the composed
    /// renderer add its gap on both sides is what made a seeded strip wider
    /// than the one it copied.
    public static func separator(for layout: MenuBarLayout) -> MenuBarToken.Kind? {
        layout == .singleLine ? .separator("·") : nil
    }

    /// The field style the renderer actually honours.
    ///
    /// `singleLineMenuTitle` draws words only and has never consulted the
    /// per-field style; a saved `.logoAndPercent` is deliberately ignored
    /// there. The seed applied it anyway and inserted a logo the user had
    /// never seen on that layout.
    public static func effectiveStyle(
        _ style: MenuBarFieldStyle,
        layout: MenuBarLayout
    ) -> MenuBarFieldStyle {
        layout == .singleLine ? .labelAndPercent : style
    }
}

public enum MenuBarStripGeometry {
    /// Total width of a cell: its runs, plus one `gap` between each adjacent
    /// pair. A composed row passes `gap: 0`.
    public static func cellWidth(runWidths: [Double], gap: Double) -> Double {
        guard !runWidths.isEmpty else { return 0 }
        return runWidths.reduce(0, +) + gap * Double(runWidths.count - 1)
    }

    /// Past this a glyph, rather than the type, decides a two-row band's
    /// height.
    public static let maximumTwoRowGlyphSide: Double = 12

    /// The two-row canvas as the status bar usually presents it: a 22pt bar
    /// less the rasterizer's 2pt inset. The App reads the real thickness at
    /// draw time; these exist so the fit property can be asserted against the
    /// shape users actually get. No padding comes off it — see
    /// `MenuBarStripMetrics.twoRowAvailableHeight`.
    public static let nominalTwoRowAvailableHeight: Double = 20
    public static let nominalTwoRowFontSize: Double = 9
    public static let nominalTwoRowLineSpacing: Double = -2
    public static let nominalLineHeightRatio: Double = 1.2

    /// Which face a composed strip is drawn at. The point sizes belong to
    /// AppKit; the *choice* belongs here, so the status item and the preview
    /// cannot disagree about it.
    public enum Face: Equatable, Sendable {
        /// The small system face the single-line status item draws at.
        case system
        /// The 9pt face the built-in Compact and two-row layouts draw at.
        case compact
    }

    /// One decision, the way glyph size is one decision.
    ///
    /// Two rows always go through the rasterizer, which draws at the compact
    /// face whatever the template says. A single row follows the layout its
    /// template was seeded from: the Compact template reproduces the built-in
    /// compact renderer, and that renderer uses the 9pt face — drawing a
    /// compact seed at the system face instead made it noticeably larger than
    /// the strip it was meant to reproduce.
    public static func face(
        template: MenuBarComposition.Template,
        rowCount: Int
    ) -> Face {
        if rowCount >= 2 { return .compact }
        return template == .compact ? .compact : .system
    }

    /// Stacked height of a set of rows, from the type metrics rather than a
    /// measurement. The status item measures its real attributed strings; the
    /// preview and the tests estimate with this, so both apply the same rule.
    public static func twoRowContentHeight(
        rowFontSizes: [Double],
        lineSpacing: Double,
        lineHeightRatio: Double
    ) -> Double {
        guard !rowFontSizes.isEmpty else { return 0 }
        return rowFontSizes.reduce(0) { $0 + $1 * lineHeightRatio }
            + lineSpacing * Double(rowFontSizes.count - 1)
    }

    /// The glyph box for a block drawn at `fontSize` in a strip of
    /// `rowCount` rows.
    ///
    /// One decision for three drawing paths — the status item's single-row
    /// text attachment, its two-row rasterizer, and the Settings preview —
    /// which each used to carry their own arithmetic and agreed only by
    /// coincidence, until they stopped: a `.large` block previewed at the
    /// 12pt cap while the bar drew it at roughly 16.
    ///
    /// The two shapes really are different and both are kept. A one-row strip
    /// has the whole bar and grows with its type; the two-row rasterizer has
    /// a fixed band per row, so a glyph that outgrew it would be the thing
    /// that forced the whole strip to shrink.
    public static func glyphSide(fontSize: Double, rowCount: Int) -> Double {
        rowCount >= 2
            ? twoRowGlyphSide(fontSize: fontSize)
            : singleRowGlyphSide(fontSize: fontSize)
    }

    public static func singleRowGlyphSide(fontSize: Double) -> Double {
        (fontSize + 3).rounded()
    }

    public static func twoRowGlyphSide(fontSize: Double) -> Double {
        Swift.min((fontSize + 1).rounded(), maximumTwoRowGlyphSide)
    }
}
