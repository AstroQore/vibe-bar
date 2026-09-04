import SwiftUI
import VibeBarCore

/// The immersive half of the layout editors: the surface at full size, on a
/// stage, with the controls that shape it alongside.
///
/// The proportions carry the meaning. In Settings the controls own the room
/// and the preview is a skeleton; here it inverts, because the question is
/// different — "is this the arrangement I want" rather than "which cards are
/// where". So the surface gets the light, the chrome gets out of the way, and
/// everything that changes does so by moving rather than by cutting.
struct LayoutStudioView: View {
    @ObservedObject var model: LayoutStudioModel

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.colorScheme) private var scheme

    @State private var zoom: Zoom = .fit
    @State private var isInspectorShown = true

    /// How much room the stage has. Measured, not assumed: "fit" has to mean
    /// the width actually available, or the surface is drawn wider than the
    /// stage and cut off at its edge.
    @State private var stageWidth: CGFloat = 520
    private static let stagePadding: CGFloat = 28

    enum Zoom: Hashable, CaseIterable {
        case fit, actual

        var label: String {
            switch self {
            case .fit:    return L10n.Settings.layoutStudioZoomFit
            case .actual: return L10n.Settings.layoutStudioZoomActual
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            HStack(spacing: 0) {
                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        stageWidth = max(200, $0 - Self.stagePadding * 2)
                    }
                if isInspectorShown {
                    inspector
                        // Wide enough for the layout editor's card names: at
                        // 420 they truncated to "Ope…", which is exactly the
                        // information the pane exists to show.
                        .frame(width: 520)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { toolbar }
        }
        .animation(.smooth(duration: 0.28), value: isInspectorShown)
        .animation(.smooth(duration: 0.28), value: model.subject)
        .animation(.smooth(duration: 0.22), value: zoom)
    }

    // MARK: - Ground

    /// A soft wash rather than a flat fill: the stage reads as a lit surface
    /// with the window's material showing through at the edges, which is what
    /// keeps the eye on the thing being arranged.
    private var backdrop: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color.black.opacity(0.34), Color.black.opacity(0.08)]
                : [Color.white.opacity(0.55), Color.white.opacity(0.16)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            subjectPicker
            Spacer(minLength: 12)
            Picker("", selection: $zoom) {
                ForEach(Zoom.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            Button {
                isInspectorShown.toggle()
            } label: {
                Image(systemName: isInspectorShown
                    ? "sidebar.trailing"
                    : "sidebar.leading")
            }
            .buttonStyle(.plain)
            .help(L10n.Settings.layoutStudioToggleInspector)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    /// Every surface the studio can arrange, in one row. Switching is what a
    /// studio is for — the alternative is closing the window and opening it
    /// again from another settings pane.
    private var subjectPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(subjects, id: \.self) { subject in
                    subjectChip(subject)
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var subjects: [LayoutStudioWindowController.Subject] {
        let pages = OverviewPage.allCases
            .compactMap(\.layoutPageID)
            .map(LayoutStudioWindowController.Subject.popoverPage)
        let windows = settingsStore.settings.miniWindow.windows
            .map { LayoutStudioWindowController.Subject.miniWindow($0.id) }
        return pages + windows
    }

    private func subjectChip(_ subject: LayoutStudioWindowController.Subject) -> some View {
        let isCurrent = subject == model.subject
        return Button {
            model.subject = subject
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon(for: subject))
                    .font(.system(size: 10, weight: .semibold))
                Text(title(for: subject))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                if isCurrent {
                    // One shape that slides between chips rather than seven
                    // that fade — the selection reads as a thing that moved.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 0.5)
                        )
                        .matchedGeometryEffect(id: "studio.subject", in: chipNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
    }

    @Namespace private var chipNamespace

    // MARK: - Stage

    private var stage: some View {
        ScrollView([.vertical, .horizontal]) {
            surface
                .padding(Self.stagePadding)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var surface: some View {
        Group {
            switch model.subject {
            case let .popoverPage(page):
                if let tab = OverviewPage.allCases.first(where: { $0.layoutPageID == page }) {
                    lit {
                        ScaledPreview(width: stageContentWidth, maxHeight: 4000) {
                            PopoverRoot(
                                width: 420,
                                onContentHeightChange: { _ in },
                                onToggleMiniWindow: {},
                                initialPage: tab
                            )
                        }
                    }
                    // `PopoverRoot` applies `initialPage` to state it owns,
                    // once, so the page only follows the picker with a new
                    // identity behind it.
                    .id(tab)
                } else {
                    Text(L10n.Settings.layoutPreviewUnavailable)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            case let .miniWindow(id):
                lit {
                    ScaledPreview(width: stageContentWidth, maxHeight: 4000) {
                        MiniQuotaWindowView(configID: id, onClose: {}, onToggleDisplayMode: {})
                    }
                }
                .id(id)
            }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)),
            removal: .opacity
        ))
    }

    private var stageContentWidth: CGFloat {
        switch zoom {
        case .fit:    return stageWidth
        case .actual: return 10_000   // never shrinks: `ScaledPreview` caps at 1×
        }
    }

    /// The surface, lifted off the ground.
    ///
    /// A shadow and a hairline, not a frame: the point is that the thing on
    /// the stage is the real surface, so it keeps its own corners and gets
    /// only the light around it.
    private func lit<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.background.secondary)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.18), radius: 24, y: 12)
    }

    // MARK: - Inspector

    private var inspector: some View {
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
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
        }
    }

    // MARK: - Naming

    private func title(for subject: LayoutStudioWindowController.Subject) -> String {
        switch subject {
        case let .popoverPage(page):
            return OverviewPage.allCases.first { $0.layoutPageID == page }?.label
                ?? L10n.Popover.tabOverview
        case let .miniWindow(id):
            return settingsStore.settings.miniWindow.config(id: id)?.name ?? "Mini"
        }
    }

    private func icon(for subject: LayoutStudioWindowController.Subject) -> String {
        switch subject {
        case .popoverPage: return "rectangle.portrait.on.rectangle.portrait"
        case .miniWindow:  return "macwindow"
        }
    }
}
