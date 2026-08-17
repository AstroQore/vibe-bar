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

    static func cardFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.052) : Color.white.opacity(0.82)
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

    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
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
                        prominent ? tint.opacity(0.72) : WorkbenchPorcelain.hairline(for: colorScheme),
                        lineWidth: Theme.Card.hairlineWidth
                    )
            )
            .opacity(configuration.isPressed ? 0.74 : 1)
    }
}
