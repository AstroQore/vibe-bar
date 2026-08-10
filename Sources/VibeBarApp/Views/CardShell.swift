import SwiftUI

/// The popover's card surface, in one place.
///
/// Every card in the workspace — quota groups, cost modules, misc providers,
/// machines — is the same rounded rectangle: density padding, a tertiary
/// background fill, and a hairline separator stroke. Repeating that stack by
/// hand is how a page ends up with its own corner radius and its own opacity,
/// so callers compose `CardShell` instead.
///
/// Use `cardSurface(density:)` directly when the card already owns its
/// internal layout (a centered empty state, a pinned-height summary) and only
/// needs the background and stroke.
struct CardShell<Content: View>: View {
    let density: Theme.Density
    /// Defaults to `density.cardSpacing`.
    var spacing: CGFloat?
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: alignment, spacing: spacing ?? density.cardSpacing) {
            content()
        }
        .padding(cardPadding)
        .cardSurface(density: density)
    }

    @Environment(\.workbenchPorcelainEnabled) private var usesWorkbenchPorcelain

    private var cardPadding: CGFloat {
        usesWorkbenchPorcelain ? max(16, density.cardPadding) : density.cardPadding
    }
}

extension View {
    func cardSurface(density: Theme.Density) -> some View {
        modifier(CardSurfaceModifier(density: density))
    }
}

private struct CardSurfaceModifier: ViewModifier {
    let density: Theme.Density

    @Environment(\.workbenchPorcelainEnabled) private var usesWorkbenchPorcelain
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesWorkbenchPorcelain {
            content
                .background(
                    RoundedRectangle(cornerRadius: max(16, density.cardCornerRadius), style: .continuous)
                        .fill(WorkbenchPorcelain.cardFill(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: max(16, density.cardCornerRadius), style: .continuous)
                        .stroke(WorkbenchPorcelain.hairline(for: colorScheme), lineWidth: 0.7)
                )
                .shadow(color: WorkbenchPorcelain.cardShadow(for: colorScheme), radius: 15, y: 7)
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                        .fill(.background.tertiary.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                        .stroke(.separator.opacity(0.4), lineWidth: 0.5)
                )
        }
    }
}
