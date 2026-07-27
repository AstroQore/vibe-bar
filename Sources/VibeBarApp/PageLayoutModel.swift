import Foundation
import SwiftUI
import VibeBarCore

/// App-side owner of the saved page layouts.
///
/// `PageLayoutStore` is an actor and the popover renders synchronously, so the
/// views cannot await it mid-body. This model loads every page's entry once at
/// startup, keeps it in memory, and writes through on every edit.
///
/// Two pieces of state with deliberately different publication rules:
///
/// - `configs` — the user's layout *intent* (column order + ratio). Published,
///   because changing it must repaint the popover.
/// - `measuredHeights` — render-time measurement fed back from every card.
///   **Not** published: it is written from inside a layout pass, and
///   republishing it there would invalidate the very views being measured and
///   spin. The layout editor reads it on demand instead, which is enough — it
///   opens long after the popover has drawn at least once.
@MainActor
final class PageLayoutModel: ObservableObject {
    /// User layout intent, one entry per customized page. A page with no entry
    /// (or an entry whose columns are empty) has never been customized and
    /// keeps its built-in arrangement.
    @Published private(set) var configs: [PageLayoutPageID: PageLayoutConfig] = [:]

    /// Last-known rendered height per module, per page. Deliberately not
    /// `@Published` — see the type comment.
    private var measured: [PageLayoutPageID: [PageLayoutModuleID: Double]] = [:]

    /// Sub-pixel wobble is not a layout change. Matches
    /// `PageLayoutStore.heightChangeEpsilon` so a measurement the store would
    /// discard never even reaches it.
    private static let heightEpsilon: Double = 0.5

    private let store: PageLayoutStore

    init(store: PageLayoutStore = .shared) {
        self.store = store
        Task { [weak self] in
            let loaded = await store.allConfigs()
            guard let self else { return }
            self.adopt(loaded)
        }
    }

    private func adopt(_ loaded: [PageLayoutPageID: PageLayoutConfig]) {
        for (page, config) in loaded {
            measured[page] = config.measuredHeights
        }
        // Heights-only entries carry no layout intent; keeping them out of
        // `configs` means `isCustomized` stays honest for a page the user has
        // only ever looked at.
        configs = loaded.filter { !$0.value.isEmpty }
    }

    // MARK: - Reading

    /// The saved arrangement for a page, or `nil` when it has never been
    /// customized.
    func configuredConfig(for page: PageLayoutPageID) -> PageLayoutConfig? {
        configs[page]
    }

    /// True when the user has arranged this page by hand. Pages answer this to
    /// decide between their built-in layout path and fixed-order rendering.
    func isCustomized(_ page: PageLayoutPageID) -> Bool {
        guard let config = configs[page] else { return false }
        return !config.isEmpty
    }

    func measuredHeights(for page: PageLayoutPageID) -> [PageLayoutModuleID: Double] {
        measured[page] ?? [:]
    }

    /// The arrangement to render right now: the saved one reconciled against
    /// the modules the page can actually draw this pass.
    func resolvedConfig(
        for page: PageLayoutPageID,
        available: [PageLayoutModuleID],
        default defaultConfig: PageLayoutConfig
    ) -> PageLayoutConfig {
        var resolved = PageLayoutResolver.resolve(
            configured: configs[page],
            available: available,
            defaultConfig: defaultConfig
        )
        // Measurement lives outside `configs`, so merge it back in for the
        // editor, which sizes its blocks from these values.
        for (moduleID, height) in measuredHeights(for: page) {
            resolved.measuredHeights[moduleID] = height
        }
        return resolved
    }

    // MARK: - Writing

    /// Persist an arrangement. Immediately written to disk by the store, so a
    /// quit right after a drag cannot lose it.
    ///
    /// `config` is an edit of the *resolved* layout, so it names only what the
    /// page can draw right now. It is merged into the saved intent rather than
    /// replacing it — otherwise reordering one card would discard the saved
    /// position of every module that is temporarily unavailable (a quota group
    /// before the first refresh, cost cards before any session log is found).
    func apply(
        _ config: PageLayoutConfig,
        for page: PageLayoutPageID,
        available: [PageLayoutModuleID]
    ) {
        var next = PageLayoutResolver.mergingEdit(
            config,
            into: configs[page],
            available: available
        )
        next.measuredHeights = measuredHeights(for: page)
        configs[page] = next
        Task { [store] in
            await store.setConfig(next, for: page)
        }
    }

    /// Replace only the column ratio. Materializes the currently resolved
    /// columns too — a ratio on its own is still a customization, and a page
    /// left "uncustomized" would ignore it.
    func setRatio(
        _ ratio: PageColumnRatio,
        for page: PageLayoutPageID,
        resolved: PageLayoutConfig,
        available: [PageLayoutModuleID]
    ) {
        var next = resolved
        next.ratio = ratio
        apply(next, for: page, available: available)
    }

    /// Forget a page's arrangement, returning it to the built-in layout.
    func reset(for page: PageLayoutPageID) {
        configs.removeValue(forKey: page)
        measured.removeValue(forKey: page)
        Task { [store] in
            await store.resetConfig(for: page)
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
        var page_ = measured[page] ?? [:]
        if let existing = page_[moduleID], abs(existing - height) <= Self.heightEpsilon {
            return
        }
        page_[moduleID] = height
        measured[page] = page_
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
