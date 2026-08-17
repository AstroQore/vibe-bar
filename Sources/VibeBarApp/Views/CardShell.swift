import SwiftUI

/// The app's card surface, in one place.
///
/// Every card on every surface — quota groups, cost modules, misc providers,
/// machines, Workbench pages, Settings blocks — is the same rounded
/// rectangle: density padding, a tertiary background fill, and a hairline
/// separator stroke. No drop shadow: cards are flat everywhere, and the
/// mini window's Liquid Glass panel is the only surface in the app allowed
/// to look like it is floating. Repeating that stack by hand is how a page
/// ends up with its own corner radius and its own opacity, so callers
/// compose `CardShell` instead. See `docs/DESIGN.md`.
///
/// The Workbench window opts in to larger metrics via
/// `workbenchPorcelain()` — same fill, same hairline, floored padding and
/// radius, because the same card has a whole window to sit in rather than a
/// 420pt popover.
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

    @Environment(\.workbenchPorcelainEnabled) private var usesWorkbenchMetrics

    private var cardPadding: CGFloat {
        usesWorkbenchMetrics
            ? max(Theme.Card.workbenchMinPadding, density.cardPadding)
            : density.cardPadding
    }
}

extension View {
    func cardSurface(density: Theme.Density) -> some View {
        modifier(CardSurfaceModifier(density: density))
    }
}

/// One recipe, two densities. The Workbench branch differs only in how big
/// the corner is — the fill and the hairline are literally the same tokens,
/// which is what keeps a quota card in the popover and a quota card in the
/// Workbench reading as the same object.
private struct CardSurfaceModifier: ViewModifier {
    let density: Theme.Density

    @Environment(\.workbenchPorcelainEnabled) private var usesWorkbenchMetrics

    private var cornerRadius: CGFloat {
        usesWorkbenchMetrics
            ? max(Theme.Card.workbenchMinCornerRadius, density.cardCornerRadius)
            : density.cardCornerRadius
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(Theme.Card.fill))
            .overlay(shape.stroke(Theme.Card.stroke, lineWidth: Theme.Card.hairlineWidth))
    }
}
