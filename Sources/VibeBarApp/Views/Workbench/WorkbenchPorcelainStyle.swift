import SwiftUI

/// Chrome tokens for the Workbench window.
///
/// These describe the window *around* the content — its ground, its sidebar,
/// its toolbars, fields and selection states. Cards inside it are not here:
/// they come from `Theme.Card` through `CardShell`, identical to the popover's,
/// because the Workbench is a bigger version of the same design language and
/// not a second one. Everything is flat — fill plus hairline, never a drop
/// shadow. See `docs/DESIGN.md`.
///
/// All colours are semantic across Aqua and Dark Aqua; provider colours
/// continue to come from `Theme.providerAccent(for:)` so charts and rows
/// cannot drift apart.
enum WorkbenchPorcelain {
    static let accent = Color(red: 78 / 255, green: 95 / 255, blue: 224 / 255)

    static func windowFill(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 23 / 255, green: 24 / 255, blue: 30 / 255).opacity(0.96)
            : Color(red: 249 / 255, green: 250 / 255, blue: 252 / 255).opacity(0.96)
    }

    static func sidebarFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.58)
    }

    /// Ground for a page's own navigation column — Sessions' harnesses,
    /// Settings' sections, Sessions' contents. Half a step between the
    /// window's sidebar and the page, so the three read as levels: the
    /// window's navigation, the page's, then the content.
    static func secondaryColumnFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.018) : Color.white.opacity(0.3)
    }

    /// Opaque ground for content that floats over other content — a chart
    /// tooltip, a toast. Flat surfaces cast no shadow, so the only honest way
    /// for one to sit above another is to be opaque.
    static func overlayFill(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 36 / 255, green: 37 / 255, blue: 44 / 255)
            : Color(red: 252 / 255, green: 252 / 255, blue: 254 / 255)
    }

    static func toolbarFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.046) : Color.white.opacity(0.74)
    }

    static func fieldFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.27) : Color.primary.opacity(0.045)
    }

    static func selectedNavigationFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.94)
    }

    static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.085)
    }

    static func hoverFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.065) : Color.black.opacity(0.045)
    }

    /// Geometry every navigation column in the window shares — the window's
    /// sidebar and a page's secondary column — so a row, a group label, a
    /// selection and a hover are the same object wherever they appear. See
    /// `WorkbenchSecondaryColumn.swift` and `docs/DESIGN.md` § 2.1.
    enum Navigation {
        static let sidebarWidth: CGFloat = 206
        static let secondaryWidth: CGFloat = 232
        /// Rows sit this far in from either edge of their column.
        static let columnInset: CGFloat = 10
        /// The first row (or a secondary column's header) starts this far
        /// down, so both columns begin on one line.
        static let topInset: CGFloat = 12
        static let rowHeight: CGFloat = 32
        static let rowCornerRadius: CGFloat = 8
        static let rowPadding: CGFloat = 8
        static let rowSpacing: CGFloat = 2
        static let markSize: CGFloat = 20
        static let markSpacing: CGFloat = 8
        static let titleSize: CGFloat = 13
        /// Folded to its marks, a column puts each mark exactly where the
        /// sidebar puts its icon blocks — `rowPadding` inside a row that is
        /// `columnInset` inside the column — so the two line up rather than
        /// the folded one reading as a strip of its own.
        static let secondaryCollapsedWidth: CGFloat = 2 * columnInset + 2 * rowPadding + markSize
    }
}

private struct WorkbenchPorcelainEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var workbenchPorcelainEnabled: Bool {
        get { self[WorkbenchPorcelainEnabledKey.self] }
        set { self[WorkbenchPorcelainEnabledKey.self] = newValue }
    }
}

extension View {
    /// Opt a subtree into the Workbench's window metrics — same card recipe,
    /// floored padding and corner radius. See `CardShell`.
    func workbenchPorcelain() -> some View {
        environment(\.workbenchPorcelainEnabled, true)
    }

    func workbenchToolbarSurface(cornerRadius: CGFloat = 14) -> some View {
        modifier(WorkbenchToolbarSurfaceModifier(cornerRadius: cornerRadius))
    }

    func workbenchFieldSurface(cornerRadius: CGFloat = 10) -> some View {
        modifier(WorkbenchFieldSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// Surface for content that floats over other content — a chart tooltip,
    /// a toast, a progress pill. Opaque rather than shadowed or glassy, which
    /// is the flat language's answer to "this is on top".
    func workbenchOverlaySurface<S: Shape>(in shape: S) -> some View {
        modifier(WorkbenchOverlaySurfaceModifier(shape: shape))
    }
}

private struct WorkbenchToolbarSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(WorkbenchPorcelain.toolbarFill(for: colorScheme)))
            .overlay(
                shape.stroke(
                    WorkbenchPorcelain.hairline(for: colorScheme),
                    lineWidth: Theme.Card.hairlineWidth
                )
            )
    }
}

private struct WorkbenchFieldSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(WorkbenchPorcelain.fieldFill(for: colorScheme)))
            .overlay(
                shape.stroke(
                    WorkbenchPorcelain.hairline(for: colorScheme),
                    lineWidth: Theme.Card.hairlineWidth
                )
            )
    }
}

private struct WorkbenchOverlaySurfaceModifier<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(shape.fill(WorkbenchPorcelain.overlayFill(for: colorScheme)))
            .overlay(
                shape.stroke(
                    WorkbenchPorcelain.hairline(for: colorScheme),
                    lineWidth: Theme.Card.hairlineWidth
                )
            )
    }
}

/// Neutral pill used by Workbench menus and secondary actions. The prominent
/// form is reserved for the page's single primary action, and says so with
/// the accent fill rather than with elevation.
struct WorkbenchPillButtonStyle: ButtonStyle {
    var prominent = false
    var tint = WorkbenchPorcelain.accent

    func makeBody(configuration: Configuration) -> some View {
        Pill(
            prominent: prominent,
            tint: tint,
            pressed: configuration.isPressed,
            label: configuration.label
        )
    }

    /// A view of its own for the same reason `VibeBarButtonStyle` has one:
    /// `isFocused` is an environment value, and only a nested view can read
    /// it about this button rather than about its container. The Workbench
    /// root switches the system focus ring off, so the pill draws its own.
    private struct Pill<Label: View>: View {
        let prominent: Bool
        let tint: Color
        let pressed: Bool
        let label: Label

        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            label
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(prominent ? tint : WorkbenchPorcelain.toolbarFill(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(
                            isFocused
                                ? Color.accentColor
                                : prominent ? tint.opacity(0.72) : WorkbenchPorcelain.hairline(for: colorScheme),
                            lineWidth: isFocused ? 1 : Theme.Card.hairlineWidth
                        )
                )
                // The neutral fill is nearly transparent in dark mode; an
                // explicit shape keeps the whole pill clickable regardless.
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .opacity(pressed ? 0.74 : 1)
        }
    }
}
