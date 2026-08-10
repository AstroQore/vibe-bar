import SwiftUI

/// Visual tokens for the Porcelain Workbench direction.
///
/// These stay scoped to the standalone Workbench so the compact menu-bar
/// popover keeps its denser, material-led appearance.  All colours are
/// semantic across Aqua and Dark Aqua; provider colours continue to come
/// from `Theme.providerAccent(for:)` so charts and rows cannot drift apart.
enum WorkbenchPorcelain {
    static let accent = Color(red: 78 / 255, green: 95 / 255, blue: 224 / 255)

    static func desktopBackground(for scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 21 / 255, green: 22 / 255, blue: 27 / 255),
                    Color(red: 11 / 255, green: 12 / 255, blue: 16 / 255),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 234 / 255, green: 237 / 255, blue: 243 / 255),
                Color(red: 214 / 255, green: 218 / 255, blue: 228 / 255),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

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

    static func cardShadow(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.34) : Color(red: 30 / 255, green: 40 / 255, blue: 70 / 255).opacity(0.09)
    }

    static func navigationShadow(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.30) : Color(red: 30 / 255, green: 40 / 255, blue: 70 / 255).opacity(0.13)
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
    /// Opt a subtree into the Workbench-only Porcelain card vocabulary.
    func workbenchPorcelain() -> some View {
        environment(\.workbenchPorcelainEnabled, true)
    }

    func workbenchToolbarSurface(cornerRadius: CGFloat = 14) -> some View {
        modifier(WorkbenchToolbarSurfaceModifier(cornerRadius: cornerRadius))
    }

    func workbenchFieldSurface(cornerRadius: CGFloat = 10) -> some View {
        modifier(WorkbenchFieldSurfaceModifier(cornerRadius: cornerRadius))
    }
}

private struct WorkbenchToolbarSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(WorkbenchPorcelain.toolbarFill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(WorkbenchPorcelain.hairline(for: colorScheme), lineWidth: 0.7)
            )
            .shadow(color: WorkbenchPorcelain.cardShadow(for: colorScheme), radius: 9, y: 4)
    }
}

private struct WorkbenchFieldSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(WorkbenchPorcelain.fieldFill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(WorkbenchPorcelain.hairline(for: colorScheme), lineWidth: 0.7)
            )
    }
}

/// Neutral porcelain pill used by Workbench menus and secondary actions.
/// The prominent form is reserved for the page's single primary action.
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
                        lineWidth: 0.7
                    )
            )
            .shadow(
                color: prominent ? tint.opacity(0.24) : WorkbenchPorcelain.navigationShadow(for: colorScheme),
                radius: prominent ? 6 : 2,
                y: prominent ? 3 : 1
            )
            .opacity(configuration.isPressed ? 0.74 : 1)
    }
}
