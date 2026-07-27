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

    /// Sub-pixel wobble is not a layout change. Matches
    /// `PageLayoutStore.heightChangeEpsilon` so a measurement the store would
    /// discard never even reaches it.
    private static let heightEpsilon: Double = 0.5

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

    /// True when the user has arranged this page by hand. Pages answer this to
    /// decide between their built-in layout path and fixed-order rendering.
    func isCustomized(_ page: PageLayoutPageID) -> Bool {
        guard let stored = storedLayouts[page] else { return false }
        return !stored.isEmpty
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

    // MARK: - Writing

    /// Persist an arrangement. `SettingsStore` writes through on assignment, so
    /// a quit right after a drag cannot lose it.
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
        let merged = PageLayoutResolver.mergingEdit(
            config,
            into: configuredConfig(for: page),
            available: available
        )
        settingsStore.settings.pageLayouts[page] = StoredPageLayout(merged)
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

    /// Forget a page's arrangement, returning it to the built-in layout. The
    /// only path that discards saved intent, including the positions of modules
    /// that are not on screen.
    func reset(for page: PageLayoutPageID) {
        settingsStore.settings.pageLayouts.removeValue(forKey: page)
        measured.removeValue(forKey: page)
        Task { [store] in
            await store.clearMeasuredHeights(for: page)
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
