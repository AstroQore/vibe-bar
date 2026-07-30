import Foundation
import SwiftUI
import VibeBarCore

/// App-side owner of the per-page card arrangement, stitched from the two
/// places its halves live.
///
/// - **Intent** — column order and width split — is a user preference, so it
///   round-trips through `AppSettings.pageLayouts` like every other Settings
///   control. Writing it there also repaints the popover for free:
///   `SettingsStore` publishes, and every page already observes it.
/// - **Measurement** — each card's last rendered height — is render-time
///   telemetry, so it lives in `~/.vibebar/layout.json` via `PageLayoutStore`.
///   Folding it into settings would push a Combine fan-out through every
///   subscriber each time a card grew a row (`AGENTS.md` § 11, the same rule
///   that keeps mini-window geometry out of `AppSettings`).
///
/// Heights are held here in a plain, unpublished dictionary: they are written
/// from inside a layout pass, and republishing there would invalidate the very
/// views being measured and spin.
@MainActor
final class PageLayoutModel: ObservableObject {
    /// Flips once, when the first read of `layout.json` lands. Published so a
    /// surface that rendered before then picks the heights up; it is a single
    /// startup event, not churn.
    @Published private(set) var measurementsLoaded = false

    /// Last-known rendered height per module, per page. Deliberately not
    /// `@Published` — see the type comment.
    private var measured: [PageLayoutPageID: [PageLayoutModuleID: Double]] = [:]

    /// Chosen partition per `compact` page, with the inputs it was chosen
    /// from. Not `@Published` for the same reason the heights are not: it is
    /// read and refreshed from inside a layout pass.
    private var compactPackings: [PageLayoutPageID: CompactPacking] = [:]

    /// Sub-pixel wobble is not a layout change. Matches
    /// `PageLayoutStore.heightChangeEpsilon` so a measurement the store would
    /// discard never even reaches it.
    private static let heightEpsilon: Double = 0.5

    /// Total height change, summed across a page's cards, before a `compact`
    /// page is re-packed. A card settles over several passes as its content
    /// arrives — a chart gets its axis, a quota card its second bucket — and
    /// re-packing on each of those would shuffle cards while the user watches.
    private static let compactRepackThreshold: Double = 4

    /// How much shorter a fresh packing has to be before it displaces the one
    /// already on screen.
    ///
    /// The two columns are not the same width, so a card that moves sides is
    /// re-measured at a new height — which can be exactly the evidence that
    /// sends it back. Requiring each move to strictly improve the page by this
    /// margin makes such a cycle impossible: a loop would have to shorten the
    /// page forever.
    private static let compactRepackHysteresis: Double = 8

    /// One `compact` page's chosen partition, plus everything it depended on.
    private struct CompactPacking {
        var moduleIDs: [PageLayoutModuleID]
        /// Segment membership the partition was computed under. Part of the key,
        /// not of the answer: re-grouping a page changes what "shortest" means,
        /// so a cached packing from the old segments cannot be reused.
        var segments: [[PageLayoutModuleID]]
        var ratio: PageColumnRatio
        var spacing: Double
        /// Heights the partition was packed from — the baseline drift is
        /// measured against.
        var heights: [PageLayoutModuleID: Double]
        /// Two columns per segment, in segment order.
        var segmentColumns: [[[PageLayoutModuleID]]]
    }

    private let settingsStore: SettingsStore
    private let store: PageLayoutStore

    init(settingsStore: SettingsStore, store: PageLayoutStore = .shared) {
        self.settingsStore = settingsStore
        self.store = store
        Task { [weak self] in
            let loaded = await store.allMeasuredHeights()
            guard let self else { return }
            self.measured = loaded
            self.measurementsLoaded = true
        }
    }

    // MARK: - Reading

    /// Saved intent for every page, as the user arranged it.
    private var storedLayouts: [PageLayoutPageID: StoredPageLayout] {
        settingsStore.settings.pageLayouts
    }

    /// The saved arrangement for a page — intent plus the measurements that go
    /// with it — or `nil` when it has never been customized.
    func configuredConfig(for page: PageLayoutPageID) -> PageLayoutConfig? {
        guard let stored = storedLayouts[page] else { return nil }
        return stored.config(measuredHeights: measuredHeights(for: page))
    }

    /// How this page decides where its cards go. A page with no saved entry is
    /// `auto`, which is also what every page was before modes existed.
    func mode(for page: PageLayoutPageID) -> PageLayoutMode {
        storedLayouts[page]?.mode ?? .auto
    }

    /// Width split this page renders at. Only consulted outside `auto`, where
    /// each page keeps its built-in widths.
    func ratio(for page: PageLayoutPageID) -> PageColumnRatio {
        storedLayouts[page]?.ratio ?? PageModuleCatalog.defaultRatio(for: page)
    }

    /// True when the page no longer draws itself the way it always did. Pages
    /// answer this to decide between their built-in layout path and fixed-order
    /// rendering; the editor uses it for the "customized" marker.
    ///
    /// `compact` counts: the page is arranged by Vibe Bar, but by a rule the
    /// user picked, not the one the page ships with.
    func isCustomized(_ page: PageLayoutPageID) -> Bool {
        mode(for: page) != .auto
    }

    /// True when the page carries any saved intent at all — a non-default mode,
    /// a hand arrangement, a chosen segmentation, or a card switched off.
    ///
    /// Distinct from `isCustomized` on purpose: that one answers "does this page
    /// still draw itself the way it always did", which is what a provider page's
    /// column widths hang off, and re-grouping or hiding a card does not change
    /// the answer to it. This one is what "Restore Defaults" has to enable.
    func hasSavedIntent(_ page: PageLayoutPageID) -> Bool {
        guard let stored = storedLayouts[page] else { return false }
        return stored.mode != .auto
            || !stored.isEmpty
            || !stored.segments.isEmpty
            || !stored.hidden.isEmpty
    }

    func measuredHeights(for page: PageLayoutPageID) -> [PageLayoutModuleID: Double] {
        measured[page] ?? [:]
    }

    // MARK: - Visibility

    /// Cards the user switched off on this page.
    func hiddenModules(for page: PageLayoutPageID) -> [PageLayoutModuleID] {
        storedLayouts[page]?.hidden ?? []
    }

    func isHidden(_ moduleID: PageLayoutModuleID, on page: PageLayoutPageID) -> Bool {
        storedLayouts[page]?.isHidden(moduleID) ?? false
    }

    /// The descriptors a page actually draws — every arrangement path starts
    /// here, so a hidden card is invisible to the packer, the planner and the
    /// resolver alike rather than being filtered out at the last moment by each
    /// renderer.
    func visibleDescriptors(
        for page: PageLayoutPageID,
        descriptors: [PageModuleDescriptor]
    ) -> [PageModuleDescriptor] {
        guard let stored = storedLayouts[page], !stored.hidden.isEmpty else { return descriptors }
        return descriptors.filter { !stored.isHidden($0.id) }
    }

    /// Module identities the page can arrange right now — what every
    /// `mergingEdit` call has to be handed as `available`.
    ///
    /// Hidden modules are deliberately absent: the merge machinery already knows
    /// how to keep the saved column and segment of something it cannot see, so
    /// switching a card off and back on returns it to where it was.
    func visibleModuleIDs(
        for page: PageLayoutPageID,
        descriptors: [PageModuleDescriptor]
    ) -> [PageLayoutModuleID] {
        visibleDescriptors(for: page, descriptors: descriptors).map(\.id)
    }

    /// Switch one card off, or back on. Nothing else about the page changes —
    /// not the mode, not the columns, not the segmentation — so un-hiding is a
    /// true undo.
    func setHidden(
        _ isHidden: Bool,
        for moduleID: PageLayoutModuleID,
        page: PageLayoutPageID
    ) {
        let stored = storedLayouts[page] ?? StoredPageLayout(
            mode: mode(for: page),
            ratio: ratio(for: page)
        )
        let next = stored.settingHidden(moduleID, isHidden)
        guard next != storedLayouts[page] else { return }
        settingsStore.settings.pageLayouts[page] = next
        // The module set changed, so the cached packing was computed for a
        // different page.
        compactPackings.removeValue(forKey: page)
    }

    /// The arrangement to render right now: the saved one reconciled against
    /// the modules the page can actually draw this pass.
    func resolvedConfig(
        for page: PageLayoutPageID,
        available: [PageLayoutModuleID],
        default defaultConfig: PageLayoutConfig
    ) -> PageLayoutConfig {
        var resolved = PageLayoutResolver.resolve(
            configured: configuredConfig(for: page),
            available: available,
            defaultConfig: defaultConfig
        )
        // Measurement lives outside the saved intent, so merge it back in for
        // the editor, which sizes its blocks from these values.
        for (moduleID, height) in measuredHeights(for: page) {
            resolved.measuredHeights[moduleID] = height
        }
        return resolved
    }

    // MARK: - Modes

    /// Segments this page arranges within — in every mode, not just `compact`:
    /// the ones the user chose, or the page's default grouping when they have
    /// not.
    ///
    /// Every currently drawable module lands in exactly one segment.
    ///
    /// - Parameter includingHidden: pass `true` for the editor, which has to
    ///   show a switched-off card in the segment it will come back to. The
    ///   render path always wants the default, `false`.
    func resolvedSegments(
        for page: PageLayoutPageID,
        descriptors: [PageModuleDescriptor],
        includingHidden: Bool = false
    ) -> [[PageLayoutModuleID]] {
        let available = includingHidden
            ? descriptors.map(\.id)
            : visibleModuleIDs(for: page, descriptors: descriptors)
        return PageLayoutSegments.resolve(
            stored: storedLayouts[page]?.segments ?? [],
            available: available,
            defaultSegments: PageModuleCatalog.defaultSegments(for: page, descriptors: descriptors)
        )
    }

    /// The arrangement this page should render right now, for whichever mode
    /// it is in.
    ///
    /// The single place the three modes are turned into columns, so the
    /// popover and the Settings preview cannot disagree about what `compact`
    /// currently produces. The Overview's `auto` mode is the one caller that
    /// does not render from this: it hands its cards to `ColumnMasonryLayout`
    /// and lets SwiftUI balance them live. What comes back here for that case
    /// is the same planner's answer the editor has always previewed.
    ///
    /// All three modes obey the page's segmentation, each in the way its own
    /// engine can: `compact` packs the segments as a relay, `auto` plans them in
    /// order, and `manual` stable-sorts its saved columns by segment. What comes
    /// back always renders as two continuous columns — `PageLayoutArrangement`
    /// keeps the per-segment structure only so the editor can draw the grouping.
    ///
    /// Cards the user switched off are filtered out here, once, so no mode has
    /// to know about visibility.
    func arrangement(
        for page: PageLayoutPageID,
        descriptors: [PageModuleDescriptor],
        spacing: Double
    ) -> PageLayoutArrangement {
        let visible = visibleDescriptors(for: page, descriptors: descriptors)
        let segments = resolvedSegments(for: page, descriptors: descriptors)
        let measured = measuredHeights(for: page)
        let defaults = PageModuleCatalog.defaultConfig(
            for: page,
            descriptors: visible,
            measuredHeights: measured,
            spacing: spacing,
            segments: segments
        )
        switch mode(for: page) {
        case .auto:
            // `defaults` was already planned inside the segments, so the columns
            // obey them; splitting them back apart is only for the editor.
            return Self.segmented(
                columns: defaults.columns,
                segments: segments,
                ratio: defaults.ratio,
                measured: measured
            )
        case .compact:
            return compactArrangement(for: page, descriptors: descriptors, spacing: spacing)
        case .manual:
            let resolved = resolvedConfig(
                for: page,
                available: visible.map(\.id),
                default: defaults
            )
            return Self.segmented(
                // The saved columns are the user's, the segmentation is the
                // user's, and where the two disagree the segmentation wins:
                // it is an ordering constraint the columns obey, and the stable
                // sort keeps the hand order inside each segment.
                columns: PageLayoutSegments.sortedColumns(resolved.columns, segments: segments),
                segments: segments,
                ratio: resolved.ratio,
                measured: measured
            )
        }
    }

    /// Two already-flowing columns split back into the per-segment structure the
    /// editor draws. The columns must already obey the segmentation, which every
    /// caller guarantees, so this is a partition into contiguous runs and never
    /// re-orders anything.
    private static func segmented(
        columns: [[PageLayoutModuleID]],
        segments: [[PageLayoutModuleID]],
        ratio: PageColumnRatio,
        measured: [PageLayoutModuleID: Double]
    ) -> PageLayoutArrangement {
        guard segments.count > 1 else {
            return PageLayoutArrangement(
                PageLayoutConfig(ratio: ratio, columns: columns, measuredHeights: measured)
            )
        }
        let rank = PageLayoutSegments.ordering(segments)
        var buckets = [[[PageLayoutModuleID]]](
            repeating: [[PageLayoutModuleID]](repeating: [], count: PageLayoutConfig.columnCount),
            count: segments.count
        )
        for (index, column) in columns.enumerated() where index < PageLayoutConfig.columnCount {
            for moduleID in column {
                let bucket = min(rank[moduleID] ?? segments.count - 1, segments.count - 1)
                buckets[bucket][index].append(moduleID)
            }
        }
        return PageLayoutArrangement(
            segments: buckets.map {
                PageLayoutConfig(ratio: ratio, columns: $0, measuredHeights: measured)
            }
        )
    }

    /// The shortest arrangement of this page's cards, segment by segment.
    ///
    /// The segments are packed as a relay — each one starts from the column
    /// heights the one before it finished at — so the page is as short as it can
    /// be *without* reordering the groups the user reads it in, and a segment
    /// that filled one column leaves the next one free to fill the other. A page
    /// with one segment is the plain shortest-page packing `compact` has always
    /// produced.
    ///
    /// Memoized, and deliberately sticky. `PageLayoutPacker` is cheap, but the
    /// answer it gives depends on heights that are still settling on the first
    /// few passes after a page opens, and a card that changes column changes
    /// width and therefore height. So a page is re-packed only once its cards
    /// have moved by more than `compactRepackThreshold` in total, and the new
    /// packing only replaces the visible one if it is shorter by more than
    /// `compactRepackHysteresis` — measured on the whole page, i.e. its taller
    /// column once every segment has flowed into it.
    func compactArrangement(
        for page: PageLayoutPageID,
        descriptors: [PageModuleDescriptor],
        spacing: Double
    ) -> PageLayoutArrangement {
        let ratio = ratio(for: page)
        let visible = visibleDescriptors(for: page, descriptors: descriptors)
        let moduleIDs = visible.map(\.id)
        let segments = resolvedSegments(for: page, descriptors: descriptors)
        let measured = measuredHeights(for: page)
        // A card the page has never drawn still has to be placed somewhere;
        // its family's stand-in is what the editor draws it at too.
        var heights: [PageLayoutModuleID: Double] = [:]
        for descriptor in visible {
            heights[descriptor.id] = measured[descriptor.id] ?? descriptor.fallbackHeight
        }

        var packing: CompactPacking
        if var cached = compactPackings[page],
           cached.moduleIDs == moduleIDs,
           cached.segments == segments,
           cached.ratio == ratio,
           cached.spacing == spacing {
            let drift = moduleIDs.reduce(0.0) { total, moduleID in
                total + abs((heights[moduleID] ?? 0) - (cached.heights[moduleID] ?? 0))
            }
            if drift <= Self.compactRepackThreshold {
                return arrangement(segmentColumns: cached.segmentColumns, ratio: ratio, measured: measured)
            }
            let candidate = Self.packedSegmentColumns(
                segments: segments,
                heights: heights,
                spacing: spacing,
                ratio: ratio
            )
            let candidateHeight = PageLayoutPacker.pageHeight(
                segments: candidate,
                heights: heights,
                spacing: spacing
            )
            let onScreen = PageLayoutPacker.pageHeight(
                segments: cached.segmentColumns,
                heights: heights,
                spacing: spacing
            )
            if candidateHeight < onScreen - Self.compactRepackHysteresis {
                cached.segmentColumns = candidate
            }
            // Either way the baseline moves forward, so a page that keeps its
            // arrangement is not re-evaluated on every single pass.
            cached.heights = heights
            packing = cached
        } else {
            packing = CompactPacking(
                moduleIDs: moduleIDs,
                segments: segments,
                ratio: ratio,
                spacing: spacing,
                heights: heights,
                segmentColumns: Self.packedSegmentColumns(
                    segments: segments,
                    heights: heights,
                    spacing: spacing,
                    ratio: ratio
                )
            )
        }
        compactPackings[page] = packing
        return arrangement(segmentColumns: packing.segmentColumns, ratio: ratio, measured: measured)
    }

    private static func packedSegmentColumns(
        segments: [[PageLayoutModuleID]],
        heights: [PageLayoutModuleID: Double],
        spacing: Double,
        ratio: PageColumnRatio
    ) -> [[[PageLayoutModuleID]]] {
        PageLayoutPacker.packedSegmentColumns(
            segments: segments.map { segment in
                segment.map { PageLayoutPacker.Item(id: $0, height: heights[$0] ?? 0) }
            },
            spacing: spacing,
            ratio: ratio
        )
    }

    private func arrangement(
        segmentColumns: [[[PageLayoutModuleID]]],
        ratio: PageColumnRatio,
        measured: [PageLayoutModuleID: Double]
    ) -> PageLayoutArrangement {
        PageLayoutArrangement(
            segments: segmentColumns.map { columns in
                PageLayoutConfig(ratio: ratio, columns: columns, measuredHeights: measured)
            }
        )
    }

    // MARK: - Writing

    /// Persist an arrangement. `SettingsStore` writes through on assignment, so
    /// a quit right after a drag cannot lose it.
    ///
    /// `config` is an edit of the *resolved* layout, so it names only what the
    /// page can draw right now. It is merged into the saved intent rather than
    /// replacing it — otherwise reordering one card would discard the saved
    /// position of every module that is temporarily unavailable (a quota group
    /// before the first refresh, cost cards before any session log is found).
    /// - Parameter mode: an arrangement written by hand is a `manual` one, and
    ///   the drag gesture is only offered in that mode, so this defaults to
    ///   `manual` rather than being spelled out at every call site.
    func apply(
        _ config: PageLayoutConfig,
        for page: PageLayoutPageID,
        available: [PageLayoutModuleID],
        mode: PageLayoutMode = .manual
    ) {
        let merged = PageLayoutResolver.mergingEdit(
            config,
            into: configuredConfig(for: page),
            available: available
        )
        let stored = storedLayouts[page]
        settingsStore.settings.pageLayouts[page] = StoredPageLayout(
            merged,
            mode: mode,
            // Columns and segments are separate intents. Dragging a card within
            // a segment says nothing about the grouping, so it rides through
            // untouched — as does the set of cards switched off.
            segments: stored?.segments ?? [],
            hidden: stored?.hidden ?? []
        )
    }

    /// Persist a segmentation the user just dragged in the editor, optionally
    /// together with the hand arrangement the same drag implies.
    ///
    /// The mode is deliberately left alone. Segments used to be a `compact`-only
    /// input, so writing one selected that mode; all three modes obey them now,
    /// and re-grouping an `auto` page into Compact behind the user's back would
    /// be a mode change they did not ask for.
    ///
    /// - Parameter columns: `nil` in the modes that compute their own columns.
    ///   In `manual` the drop decides column and position as well as membership,
    ///   and both halves have to land in one write — two writes would fan out
    ///   through every settings subscriber twice for one gesture.
    func applySegments(
        _ segments: [[PageLayoutModuleID]],
        columns: PageLayoutConfig? = nil,
        for page: PageLayoutPageID,
        available: [PageLayoutModuleID]
    ) {
        let stored = storedLayouts[page]
        let mergedColumns = columns.map {
            PageLayoutResolver.mergingEdit(
                $0,
                into: configuredConfig(for: page),
                available: available
            )
        }
        settingsStore.settings.pageLayouts[page] = StoredPageLayout(
            mode: mode(for: page),
            ratio: mergedColumns?.ratio ?? stored?.ratio ?? PageModuleCatalog.defaultRatio(for: page),
            // Same reason `apply` keeps the segments: a hand arrangement
            // survives being re-grouped.
            columns: mergedColumns?.columns ?? stored?.columns ?? [],
            segments: PageLayoutSegments.mergingEdit(
                segments,
                into: stored?.segments ?? [],
                available: available
            ),
            hidden: stored?.hidden ?? []
        )
        compactPackings.removeValue(forKey: page)
    }

    /// Switch a page between automatic, compact and hand-arranged.
    ///
    /// - Parameter displayed: the arrangement currently on screen. Switching
    ///   to `manual` materializes it *only* when the page has no hand
    ///   arrangement saved, so a first drag starts from what the user was
    ///   looking at rather than from the built-in split. A page that was
    ///   arranged before gets its own arrangement back instead.
    func setMode(
        _ mode: PageLayoutMode,
        for page: PageLayoutPageID,
        displayed: PageLayoutArrangement,
        available: [PageLayoutModuleID]
    ) {
        guard mode != self.mode(for: page) else { return }
        switch mode {
        case .manual:
            // A page that was arranged by hand before it was switched to a
            // computed mode gets that arrangement back, not the one Compact
            // or the balancer happened to be showing. Keeping the columns
            // through `auto`/`compact` would be pointless if returning to
            // Manual overwrote them. `restoredAsManual` is `nil` only when
            // there is nothing to restore, and then the arrangement on screen
            // is the right place for a first-time edit to start.
            if let restored = storedLayouts[page]?.restoredAsManual() {
                settingsStore.settings.pageLayouts[page] = restored
            } else {
                // A segmented page flattens into the two columns Manual works
                // in, band by band, so a first hand edit starts from the cards
                // in the order they were just on screen.
                apply(displayed.flattened, for: page, available: available, mode: .manual)
            }
        case .auto, .compact:
            let stored = storedLayouts[page]
            settingsStore.settings.pageLayouts[page] = StoredPageLayout(
                mode: mode,
                ratio: stored?.ratio ?? displayed.ratio,
                // A hand arrangement survives a trip through the computed
                // modes: switching away and back is not a reset, and only
                // `reset(for:)` forgets a page. The same holds for the segments
                // and for the cards switched off.
                columns: stored?.columns ?? [],
                segments: stored?.segments ?? [],
                hidden: stored?.hidden ?? []
            )
        }
        compactPackings.removeValue(forKey: page)
    }

    /// Replace only the column ratio.
    ///
    /// In `compact` the ratio is one of the packer's inputs, so it is stored on
    /// its own and the page re-packs. In the other two modes it materializes
    /// the currently resolved columns as well: picking a width split has always
    /// been a way to take a page over, and a page left on `auto` would ignore
    /// the ratio entirely.
    func setRatio(
        _ ratio: PageColumnRatio,
        for page: PageLayoutPageID,
        resolved: PageLayoutConfig,
        available: [PageLayoutModuleID]
    ) {
        guard mode(for: page) != .compact else {
            let stored = storedLayouts[page]
            settingsStore.settings.pageLayouts[page] = StoredPageLayout(
                mode: .compact,
                ratio: ratio,
                columns: stored?.columns ?? [],
                segments: stored?.segments ?? [],
                hidden: stored?.hidden ?? []
            )
            compactPackings.removeValue(forKey: page)
            return
        }
        var next = resolved
        next.ratio = ratio
        apply(next, for: page, available: available, mode: .manual)
    }

    /// Forget a page's arrangement, returning it to the built-in layout. The
    /// only path that discards saved intent, including the positions of modules
    /// that are not on screen. Saved presets are untouched — they exist so an
    /// arrangement survives exactly this.
    func reset(for page: PageLayoutPageID) {
        settingsStore.settings.pageLayouts.removeValue(forKey: page)
        measured.removeValue(forKey: page)
        compactPackings.removeValue(forKey: page)
        Task { [store] in
            await store.clearMeasuredHeights(for: page)
        }
    }

    // MARK: - Presets

    func presets(for page: PageLayoutPageID) -> [StoredPageLayoutPreset] {
        settingsStore.settings.pageLayoutPresets[page] ?? []
    }

    /// True when this page has room for a preset it does not already have.
    /// Replacing one by name stays possible either way — see
    /// `presetWouldReplace(named:for:)`.
    func canAddPreset(for page: PageLayoutPageID) -> Bool {
        presets(for: page).count < AppSettings.maximumPresetsPerPage
    }

    /// True when saving under this name would overwrite a preset the page
    /// already has, rather than adding one. A replacement leaves the count
    /// unchanged, so it is allowed even on a full page.
    func presetWouldReplace(named name: String, for page: PageLayoutPageID) -> Bool {
        StoredPageLayoutPreset.index(of: name, in: presets(for: page)) != nil
    }

    /// Whether `savePreset` would succeed, so the editor can say why not
    /// before the user commits to a name.
    func canSavePreset(named name: String, for page: PageLayoutPageID) -> Bool {
        guard !StoredPageLayoutPreset.normalizedName(name).isEmpty else { return false }
        return presetWouldReplace(named: name, for: page) || canAddPreset(for: page)
    }

    /// What "save the current arrangement" captures.
    ///
    /// A hand-arranged page's saved entry knows more than the screen does — it
    /// still remembers where modules the page cannot draw right now belong — so
    /// that is what gets stored. A computed page has no such entry, so the
    /// arrangement it is showing is captured instead.
    func presetSnapshot(
        for page: PageLayoutPageID,
        displayed: PageLayoutArrangement
    ) -> StoredPageLayout {
        let mode = mode(for: page)
        if mode == .manual, let stored = storedLayouts[page], !stored.isEmpty {
            return stored
        }
        return StoredPageLayout(
            mode: mode,
            ratio: displayed.ratio,
            columns: displayed.flattened.columns,
            // The grouping on screen *is* part of the arrangement in every mode
            // now, so the resolved segments are captured rather than the saved
            // ones: a preset taken before the user re-grouped anything still
            // restores the page they were looking at instead of an empty "use
            // the default" marker.
            segments: displayed.moduleSegments,
            hidden: storedLayouts[page]?.hidden ?? []
        )
    }

    /// Save an arrangement under a name, replacing a preset of the same name in
    /// place and keeping its position in the menu.
    ///
    /// Returns false only when the name is blank, or when it is a *new* name on
    /// a page already holding as many presets as it may. Replacing is never
    /// blocked by the cap: it does not add anything.
    @discardableResult
    func savePreset(
        named name: String,
        for page: PageLayoutPageID,
        layout: StoredPageLayout
    ) -> Bool {
        let preset = StoredPageLayoutPreset(name: name, layout: layout)
        guard preset.isValid else { return false }
        var entries = presets(for: page)
        if let index = StoredPageLayoutPreset.index(of: preset.name, in: entries) {
            entries[index] = preset
        } else {
            guard entries.count < AppSettings.maximumPresetsPerPage else { return false }
            entries.append(preset)
        }
        settingsStore.settings.pageLayoutPresets[page] = entries
        return true
    }

    /// Put a saved arrangement back, in the mode it was captured in.
    ///
    /// This used to force `manual` on the grounds that a preset is one specific
    /// arrangement. Bands made that wrong: what is worth keeping about a packed
    /// page is how it is grouped, not the particular packing those heights
    /// produced, and restoring a `compact` preset as a frozen manual layout
    /// threw the grouping away and froze the packing. So a `manual` preset
    /// restores its exact columns and a `compact` one restores its bands and
    /// lets the packer work inside them.
    ///
    /// Columns and bands are written verbatim; `PageLayoutResolver` and
    /// `PageLayoutSegments` reconcile them against the modules the page can
    /// actually draw at render time, so a preset saved when a provider was
    /// signed in still applies afterwards.
    ///
    /// `layoutToApply` rather than `layout`: a compact preset saved before
    /// bands existed restores as the manual arrangement it captured, not as a
    /// re-pack under default bands it never saw.
    func applyPreset(_ preset: StoredPageLayoutPreset, to page: PageLayoutPageID) {
        settingsStore.settings.pageLayouts[page] = preset.layoutToApply
        compactPackings.removeValue(forKey: page)
    }

    func deletePreset(named name: String, for page: PageLayoutPageID) {
        var remaining = presets(for: page)
        guard let index = StoredPageLayoutPreset.index(of: name, in: remaining) else { return }
        remaining.remove(at: index)
        if remaining.isEmpty {
            settingsStore.settings.pageLayoutPresets.removeValue(forKey: page)
        } else {
            settingsStore.settings.pageLayoutPresets[page] = remaining
        }
    }

    // MARK: - Measurement intake

    /// Record one card's rendered height. Called from `onGeometryChange`, i.e.
    /// once per card per layout pass, so the epsilon filter here matters: it is
    /// what keeps a resizing popover from queueing an actor hop per frame.
    func recordHeight(
        _ height: Double,
        for moduleID: PageLayoutModuleID,
        page: PageLayoutPageID
    ) {
        guard height.isFinite, height > 0 else { return }
        var pageHeights = measured[page] ?? [:]
        if let existing = pageHeights[moduleID], abs(existing - height) <= Self.heightEpsilon {
            return
        }
        pageHeights[moduleID] = height
        measured[page] = pageHeights
        Task { [store] in
            await store.updateMeasuredHeights([moduleID: height], for: page)
        }
    }

    func recordHeights(
        _ heights: [PageLayoutModuleID: Double],
        for page: PageLayoutPageID
    ) {
        for (moduleID, height) in heights {
            recordHeight(height, for: moduleID, page: page)
        }
    }
}

extension View {
    /// Report a card's rendered height back to the layout model, keyed by the
    /// module identity the editor arranges it under.
    ///
    /// Applied in both rendering modes — the auto-balanced Overview waterfall
    /// and fixed two-column pages — so the editor can draw proportional blocks
    /// for a page the user has never customized.
    func measuredPageModule(
        _ moduleID: PageLayoutModuleID,
        page: PageLayoutPageID,
        model: PageLayoutModel
    ) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            model.recordHeight(Double(height), for: moduleID, page: page)
        }
    }
}
