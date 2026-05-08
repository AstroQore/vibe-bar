import SwiftUI

/// Small refresh affordance dropped into each provider-detail card's
/// header so the user can refresh just that section instead of the
/// whole popover. Mirrors the existing button on `ProviderQuotaCard`.
///
/// Pass `isRefreshing: true` to swap the icon for a spinner — keeps
/// the card's header layout stable while the underlying data is in
/// flight.
struct SectionRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void
    var help: String = "Refresh this section"

    var body: some View {
        ZStack {
            BorderlessIconButton(systemImage: "arrow.clockwise", help: help, action: action)
                .opacity(isRefreshing ? 0 : 1)
                .disabled(isRefreshing)
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 18, height: 18)
    }
}
