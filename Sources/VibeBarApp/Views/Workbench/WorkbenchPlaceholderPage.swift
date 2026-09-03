import SwiftUI
import VibeBarCore

/// Stand-in detail page for Workbench sections that have no content yet.
struct WorkbenchPlaceholderPage: View {
    let page: WorkbenchPage
    let density: Theme.Density

    var body: some View {
        CardShell(density: density, alignment: .center) {
            Image(systemName: page.systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(page.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: 520)
        .padding(density.popoverPaddingH)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detail: String {
        switch page {
        case .usageStats:
            L10n.Workbench.placeholderUsageStats
        case .resets:
            L10n.Workbench.placeholderResets
        case .sessionManager:
            L10n.Workbench.placeholderSessionManager
        case .skillsManager:
            L10n.Workbench.placeholderSkillsManager
        case .settings:
            L10n.Workbench.placeholderSettings
        }
    }
}
