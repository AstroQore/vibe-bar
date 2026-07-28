import Foundation

/// Width split between the two columns of a page.
///
/// Three presets rather than a free slider: the popover is narrow, and a
/// continuous ratio makes it trivial to produce an unusable 5 % column.
public enum PageColumnRatio: String, CaseIterable, Codable, Hashable, Sendable {
    case narrowWide = "narrow-wide"
    case equal
    case wideNarrow = "wide-narrow"

    /// What an unknown ratio in `layout.json` decodes to.
    public static let fallback: PageColumnRatio = .equal

    /// Share of the available content width given to the left column, before
    /// inter-column spacing.
    public var leftFraction: Double {
        switch self {
        case .narrowWide: return 0.38
        case .equal:      return 0.5
        case .wideNarrow: return 0.62
        }
    }

    public var rightFraction: Double { 1 - leftFraction }

    public func fraction(forColumn index: Int) -> Double {
        index <= 0 ? leftFraction : rightFraction
    }

    /// Forward-tolerant: a ratio written by a newer build decodes to `.equal`
    /// instead of throwing away the whole page entry.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = PageColumnRatio(rawValue: raw) ?? Self.fallback
    }
}

/// How a page decides where its cards go.
///
/// Three modes rather than a customized/not-customized flag, because "let the
/// app arrange it" turned out to mean two different things:
///
/// - `auto` keeps each page's built-in behaviour — the Overview's phase-aware
///   `ColumnMasonryLayout` balancer, a provider page's hand-coded split.
/// - `compact` ignores phases entirely and asks `PageLayoutPacker` for the
///   partition that makes the page as short as possible. The balancer cannot
///   reach that arrangement: it places every quota card before any cost card,
///   and that constraint alone can cost a page a few hundred points.
/// - `manual` renders the arrangement the user dragged, and nothing else
///   touches it.
public enum PageLayoutMode: String, CaseIterable, Codable, Hashable, Sendable {
    case auto
    case compact
    case manual

    /// What an unrecognized mode decodes to when there is nothing better to go
    /// on. `StoredPageLayout` has more context and uses it — see its decoder.
    public static let fallback: PageLayoutMode = .auto

    /// Forward-tolerant, like `PageColumnRatio`: a mode written by a newer
    /// build decodes to `auto` instead of failing the enclosing value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = PageLayoutMode(rawValue: raw) ?? Self.fallback
    }

    /// True when the page draws itself and the saved columns are only a
    /// starting point for the editor.
    public var isComputed: Bool { self != .manual }
}

/// One page's saved layout: the column ratio, the two ordered module columns,
/// and the last-known measured height of each module.
///
/// `measuredHeights` exists for the Settings editor. The editor draws modules
/// as proportional rectangles, and a page the user has not opened this session
/// has never reported a height — without a persisted last-known value the
/// editor would have to render every card as the same featureless block.
///
/// Invariants, enforced by `init` / `setColumns(_:)` / `moving(_:toColumn:at:)`
/// and re-applied on decode:
///
/// - `columns.count == 2` exactly.
/// - No module identifier appears twice, in either column.
/// - `measuredHeights` holds only finite, positive values.
public struct PageLayoutConfig: Hashable, Sendable {
    /// The layout editor is a two-column model by design; the popover is too
    /// narrow for three and one column needs no editor.
    public static let columnCount = 2

    public var ratio: PageColumnRatio
    public private(set) var columns: [[PageLayoutModuleID]]
    public var measuredHeights: [PageLayoutModuleID: Double]

    public init(
        ratio: PageColumnRatio = .equal,
        columns: [[PageLayoutModuleID]] = [],
        measuredHeights: [PageLayoutModuleID: Double] = [:]
    ) {
        self.ratio = ratio
        self.columns = Self.normalized(columns)
        self.measuredHeights = Self.sanitized(measuredHeights)
    }

    // MARK: - Accessors

    public var leftColumn: [PageLayoutModuleID] { columns[0] }
    public var rightColumn: [PageLayoutModuleID] { columns[1] }

    /// Left column first, then right — the reading order the editor uses.
    public var moduleIDs: [PageLayoutModuleID] { columns.flatMap { $0 } }

    /// True when the config carries no layout intent at all. A heights-only
    /// entry (written by `PageLayoutStore.updateMeasuredHeights` for a page the
    /// user has never customized) is empty in this sense, and the resolver
    /// treats it as "not configured".
    public var isEmpty: Bool { columns.allSatisfy(\.isEmpty) }

    public func column(_ index: Int) -> [PageLayoutModuleID] {
        columns[min(max(0, index), Self.columnCount - 1)]
    }

    public func columnIndex(of moduleID: PageLayoutModuleID) -> Int? {
        columns.firstIndex { $0.contains(moduleID) }
    }

    public func measuredHeight(for moduleID: PageLayoutModuleID) -> Double? {
        measuredHeights[moduleID]
    }

    // MARK: - Mutation

    /// Replace both columns, re-applying the two-column and no-duplicate
    /// invariants.
    public mutating func setColumns(_ columns: [[PageLayoutModuleID]]) {
        self.columns = Self.normalized(columns)
    }

    /// Result of dragging `moduleID` to `index` in `column`. The module is
    /// removed from wherever it currently sits first, so a drag can never
    /// duplicate a card. `column` and `index` are clamped into range.
    public func moving(
        _ moduleID: PageLayoutModuleID,
        toColumn column: Int,
        at index: Int
    ) -> PageLayoutConfig {
        var next = columns
        for columnIndex in next.indices {
            next[columnIndex].removeAll { $0 == moduleID }
        }
        let target = min(max(0, column), Self.columnCount - 1)
        let position = min(max(0, index), next[target].count)
        next[target].insert(moduleID, at: position)

        var updated = self
        updated.setColumns(next)
        return updated
    }

    // MARK: - Normalization

    static func normalized(_ columns: [[PageLayoutModuleID]]) -> [[PageLayoutModuleID]] {
        var result = [[PageLayoutModuleID]](repeating: [], count: columnCount)
        var seen = Set<PageLayoutModuleID>()
        for (index, column) in columns.enumerated() {
            // A file written by a build with more columns folds its extras into
            // the last column rather than losing those modules.
            let target = min(index, columnCount - 1)
            for moduleID in column where !moduleID.rawValue.isEmpty {
                guard seen.insert(moduleID).inserted else { continue }
                result[target].append(moduleID)
            }
        }
        return result
    }

    static func sanitized(_ heights: [PageLayoutModuleID: Double]) -> [PageLayoutModuleID: Double] {
        heights.filter { $0.value.isFinite && $0.value > 0 }
    }
}

/// One page's layout **intent** — the half of `PageLayoutConfig` the user
/// actually chose — as stored in `AppSettings`.
///
/// `PageLayoutConfig` stays the canonical model: the invariants live there, and
/// this type round-trips through its `init` so a hand-edited settings file
/// cannot smuggle in a duplicate or a third column. This is a thin DTO, not a
/// second model.
///
/// It deliberately omits `measuredHeights`. Those are render-time telemetry
/// that changes whenever a card grows a row or the popover is resized, and
/// every `AppSettings` write fans out to every Combine subscriber — the same
/// reason mini-window geometry is kept out of settings (`AGENTS.md` § 11).
/// Heights stay in `~/.vibebar/layout.json` via `PageLayoutStore`; the two are
/// recombined at render time.
public struct StoredPageLayout: Hashable, Sendable {
    /// Which arrangement the page renders. `columns` is kept in every mode:
    /// switching to `auto` or `compact` and back must not throw away an
    /// arrangement the user dragged by hand.
    public var mode: PageLayoutMode
    public var ratio: PageColumnRatio
    public private(set) var columns: [[PageLayoutModuleID]]

    /// - Parameter mode: `nil` derives the mode from the columns — an entry
    ///   that carries an arrangement is a `manual` one, an entry that carries
    ///   none is `auto`. That is the same rule the decoder applies to an entry
    ///   written before modes existed, kept in one place so the two cannot
    ///   drift apart.
    public init(
        mode: PageLayoutMode? = nil,
        ratio: PageColumnRatio = .equal,
        columns: [[PageLayoutModuleID]] = []
    ) {
        let normalized = PageLayoutConfig(ratio: ratio, columns: columns)
        self.mode = mode ?? (normalized.isEmpty ? .auto : .manual)
        self.ratio = normalized.ratio
        self.columns = normalized.columns
    }

    /// The intent half of a live config; measured heights are dropped.
    public init(_ config: PageLayoutConfig, mode: PageLayoutMode? = nil) {
        self.init(mode: mode, ratio: config.ratio, columns: config.columns)
    }

    /// Back to the canonical model, with this page's measurements folded in.
    public func config(
        measuredHeights: [PageLayoutModuleID: Double] = [:]
    ) -> PageLayoutConfig {
        PageLayoutConfig(ratio: ratio, columns: columns, measuredHeights: measuredHeights)
    }

    /// True when the entry carries no arrangement — the same "not customized"
    /// test `PageLayoutConfig.isEmpty` makes. Independent of `mode`: an `auto`
    /// page can still be holding the columns it had before the user switched.
    public var isEmpty: Bool { columns.allSatisfy(\.isEmpty) }

    /// The entry a page should get when the user switches it back to `manual`.
    ///
    /// `auto` and `compact` deliberately keep the columns they were handed, so
    /// returning to `manual` has to give the user back the arrangement they
    /// dragged — not whatever the computed mode happened to be showing when
    /// they flipped the switch. Overwriting it with the computed columns would
    /// make a round trip through Compact a silent, unannounced reset of a hand
    /// arrangement, which is precisely what keeping the columns was for.
    ///
    /// `nil` when nothing was ever arranged by hand; the caller then
    /// materializes what is on screen instead, which is the right starting
    /// point for a first-time edit. The restored columns still go through
    /// `PageLayoutResolver` at render time, so modules that came or went while
    /// the page was computed are reconciled as usual.
    public func restoredAsManual() -> StoredPageLayout? {
        guard !isEmpty else { return nil }
        return StoredPageLayout(mode: .manual, ratio: ratio, columns: columns)
    }
}

extension StoredPageLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case ratio
        case columns
    }

    /// Field-by-field tolerant, like `PageLayoutConfig`'s own decoder: a page
    /// entry written by a newer build degrades to defaults for the field it
    /// cannot read instead of discarding the user's whole arrangement.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decoded by hand rather than through `PageLayoutMode`'s own tolerant
        // decoder, because the two absence shapes mean different things. A
        // MISSING key is an entry written before modes existed — a hand-dragged
        // arrangement that must come back as `manual`. A PRESENT key with an
        // unrecognized value is a newer build's mode — that falls back to
        // `auto` instead of promoting the saved columns to a fixed manual
        // layout after a downgrade.
        let mode: PageLayoutMode?
        if container.contains(.mode) {
            mode = (try? container.decode(String.self, forKey: .mode))
                .flatMap(PageLayoutMode.init(rawValue:)) ?? PageLayoutMode.fallback
        } else {
            mode = nil
        }
        let ratio = (try? container.decode(PageColumnRatio.self, forKey: .ratio)) ?? .equal
        let columns = (try? container.decode([[PageLayoutModuleID]].self, forKey: .columns)) ?? []
        self.init(mode: mode, ratio: ratio, columns: columns)
    }
}

/// One saved arrangement the user named, so a layout worth keeping can be put
/// back later without re-dragging it.
///
/// Stores a whole `StoredPageLayout` — mode, ratio and columns — so a preset
/// records what it was captured from. Applying one always lands in `manual`
/// mode: a preset is "this exact arrangement", and re-entering `compact` would
/// just recompute from whatever the heights happen to be now.
public struct StoredPageLayoutPreset: Hashable, Sendable {
    /// Long enough for "Wide left, cost on the right", short enough that a
    /// pasted paragraph cannot bloat `settings.json`.
    public static let maximumNameLength = 48

    public var name: String
    public var layout: StoredPageLayout

    public init(name: String, layout: StoredPageLayout) {
        self.name = Self.normalizedName(name)
        self.layout = layout
    }

    /// Trimmed and length-capped. The UI shows the normalized form, so what
    /// the user sees in the menu is exactly what was stored.
    public static func normalizedName(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumNameLength))
    }

    /// A preset with no name cannot be picked out of a menu, so it is dropped
    /// on the way in rather than rendered as a blank row.
    public var isValid: Bool { !name.isEmpty }

    /// Case-insensitive identity. Two presets whose names differ only by case
    /// are the same menu entry, so they are the same preset.
    public var matchKey: String { name.lowercased() }

    /// Where `name` would land in `presets`, under the one matching rule the
    /// whole feature uses — `AppSettings` dedupes with it, saving replaces
    /// with it, deleting removes with it.
    ///
    /// `nil` means the name is new, which is also what decides whether saving
    /// costs a slot against the per-page cap: replacing an existing preset
    /// leaves the count unchanged and must stay available even when the page
    /// is full.
    public static func index(
        of name: String,
        in presets: [StoredPageLayoutPreset]
    ) -> Int? {
        let key = normalizedName(name).lowercased()
        guard !key.isEmpty else { return nil }
        return presets.firstIndex { $0.matchKey == key }
    }
}

extension StoredPageLayoutPreset: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case layout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = (try? container.decode(String.self, forKey: .name)) ?? ""
        let layout = (try? container.decode(StoredPageLayout.self, forKey: .layout)) ?? StoredPageLayout()
        self.init(name: name, layout: layout)
    }
}

extension PageLayoutConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case ratio
        case columns
        case measuredHeights
    }

    /// Every field is optional and individually tolerant: a page entry written
    /// by a newer build, or hand-edited into something malformed, degrades to
    /// defaults for that field instead of throwing the whole layout away.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ratio = (try? container.decode(PageColumnRatio.self, forKey: .ratio)) ?? .equal
        let columns = (try? container.decode([[PageLayoutModuleID]].self, forKey: .columns)) ?? []
        let heights = (try? container.decode([PageLayoutModuleID: Double].self, forKey: .measuredHeights)) ?? [:]
        self.init(ratio: ratio, columns: columns, measuredHeights: heights)
    }
}
