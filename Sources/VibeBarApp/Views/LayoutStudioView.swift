import SwiftUI
import VibeBarCore

/// The immersive half of the layout editors: the surface at full size, with
/// the controls that shape it alongside.
///
/// The proportions are the whole point. In Settings the controls have the room
/// and the preview is a thumbnail; here it is the other way round, because the
/// question being asked is different — "is this the arrangement I want" rather
/// than "which cards are where".
struct LayoutStudioView: View {
    @ObservedObject var model: LayoutStudioModel

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    /// Wide enough that neither surface is scaled down at a usual window size:
    /// the popover opens at 420 and a mini window at rather less, so the panel
    /// only shrinks them when the user makes the window small.
    private static let stageWidth: CGFloat = 520

    var body: some View {
        HSplitView {
            stage
                .frame(minWidth: 380, idealWidth: 560)
            controls
                .frame(minWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkbenchPorcelain.windowFill(for: colorSchemeKey))
    }

    @Environment(\.colorScheme) private var scheme
    private var colorSchemeKey: ColorScheme { scheme }

    // MARK: - Stage

    private var stage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(subjectTitle)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(L10n.Settings.layoutStudioLive)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ScrollView([.vertical]) {
                surface
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
    }

    @ViewBuilder
    private var surface: some View {
        switch model.subject {
        case let .popoverPage(page):
            if let tab = OverviewPage.allCases.first(where: { $0.layoutPageID == page }) {
                ScaledPreview(width: Self.stageWidth, maxHeight: 3000) {
                    PopoverRoot(
                        width: 420,
                        onContentHeightChange: { _ in },
                        onToggleMiniWindow: {},
                        initialPage: tab
                    )
                }
                // `PopoverRoot` applies `initialPage` to state it owns, once.
                .id(tab)
            } else {
                Text(L10n.Settings.layoutPreviewUnavailable)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case let .miniWindow(id):
            ScaledPreview(width: Self.stageWidth, maxHeight: 3000) {
                MiniQuotaWindowView(configID: id, onClose: {}, onToggleDisplayMode: {})
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background.secondary)
            )
        }
    }

    private var subjectTitle: String {
        switch model.subject {
        case let .popoverPage(page):
            return OverviewPage.allCases.first { $0.layoutPageID == page }?.label
                ?? L10n.Popover.tabOverview
        case let .miniWindow(id):
            return settingsStore.settings.miniWindow.config(id: id)?.name ?? "Mini"
        }
    }

    // MARK: - Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // The same editors Settings shows. One place decides what a
                // control does; this decides how much room it gets.
                switch model.subject {
                case .popoverPage:
                    LayoutEditorView()
                case .miniWindow:
                    MiniWindowsSettingsSection()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.isInLayoutStudio, true)
    }
}
