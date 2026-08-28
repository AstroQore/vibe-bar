import SwiftUI

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
            "Full-window usage and cost analytics are on their way."
        case .resets:
            "Cycle, refill and forecast views are on their way."
        case .sessionManager:
            "Browsing and searching local Codex and Claude Code sessions is on its way."
        case .skillsManager:
            "Reviewing and organizing installed agent skills is on its way."
        case .settings:
            "Configure Vibe Bar and its connected providers."
        }
    }
}
