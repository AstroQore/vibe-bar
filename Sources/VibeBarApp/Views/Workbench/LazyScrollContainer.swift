import SwiftUI

/// A container that answers every size question with the space it is
/// offered and never asks its content.
///
/// A stack, a safe-area inset or a flexible frame sizes a child by asking
/// what it would like to be. A scroll view answers by measuring its whole
/// content, and for a lazy list that is every row — profiled on a long
/// conversation, those questions were the entire cost of scrolling it: one
/// layout pass measured every turn in the window. Wrapping each of the
/// page's scroll views in this keeps the question from reaching the rows,
/// so a lazy list stays lazy.
struct LazyScrollContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { _ in
            content()
        }
    }
}
