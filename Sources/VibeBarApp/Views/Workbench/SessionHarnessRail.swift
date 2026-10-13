import SwiftUI
import VibeBarCore

/// The Sessions page's navigation column: one row per harness that has
/// sessions, with its count, and "All" on top.
///
/// The unit is the harness, never the company (AGENTS.md § 7.1): the list
/// beside it is labelled by harness, and two harnesses can share an adapter.
/// Counts are the index's listed rows — Auto Reviews already excluded — and
/// the line under a count says how many of them are threads folded under
/// another session, so a number the list does not seem to add up to
/// explains itself.
///
/// It is a `WorkbenchSecondaryColumn`, the same column Settings' sections
/// use, so the two pages' navigation looks like one thing. Narrow windows
/// fold it to its marks, which then sit exactly where the window sidebar's
/// icon blocks sit.
struct SessionHarnessRail: View {
    let controller: SessionsPageController
    let navigation: SessionNavigationModel
    let isCollapsed: Bool

    var body: some View {
        WorkbenchSecondaryColumn(isCollapsed: isCollapsed) {
            header
        } content: {
            allRow
            ForEach(navigation.entries) { entry in
                harnessRow(entry)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if !isCollapsed {
                WorkbenchSecondaryColumnTitle(title: L10n.Usage.Mix.Dimension.harnesses)
                Spacer(minLength: 0)
            }
            BorderlessIconButton(
                systemImage: isCollapsed ? "sidebar.left" : "sidebar.leading",
                help: isCollapsed
                    ? L10n.Workbench.Sessions.Rail.expand
                    : L10n.Workbench.Sessions.Rail.collapse
            ) {
                controller.railCollapsedChoice = !isCollapsed
            }
            // Its glyph's centre on the marks' centre line when folded.
            .padding(.trailing, isCollapsed ? 0 : 4)
        }
    }

    private var allRow: some View {
        SessionRailRow(
            isCollapsed: isCollapsed,
            isSelected: navigation.isAllSelected,
            title: L10n.Common.all,
            count: navigation.total,
            threads: navigation.threadTotal,
            help: L10n.Workbench.Sessions.Rail.allHelp
        ) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(navigation.isAllSelected ? WorkbenchPorcelain.accent : Color.secondary)
        } action: {
            controller.selectAllHarnesses()
        }
    }

    private func harnessRow(_ entry: SessionNavigationModel.Entry) -> some View {
        SessionRailRow(
            isCollapsed: isCollapsed,
            isSelected: navigation.isSelected(entry.harness),
            title: entry.harness.displayName,
            count: entry.count,
            threads: entry.threads,
            help: L10n.Workbench.Sessions.Rail.selectHelp(harness: entry.harness.displayName)
        ) {
            HarnessBrandBadge(harness: entry.harness, iconSize: 16, containerSize: 20, brandColored: true)
        } action: {
            // ⌘-click adds the harness to the selection instead of
            // replacing it.
            controller.selectHarness(entry.harness, extending: NSEvent.modifierFlags.contains(.command))
        }
    }
}

/// A harness row: the shared navigation row with the count as its accessory
/// and the folded-threads line as its subtitle.
private struct SessionRailRow<Mark: View>: View {
    let isCollapsed: Bool
    let isSelected: Bool
    let title: String
    let count: Int
    let threads: Int
    let help: String
    @ViewBuilder let mark: () -> Mark
    let action: () -> Void

    var body: some View {
        WorkbenchNavigationRow(
            title: title,
            subtitle: threads > 0 ? L10n.Workbench.Sessions.Rail.threadsIncluded(count: threads) : nil,
            isSelected: isSelected,
            isCollapsed: isCollapsed,
            action: action,
            mark: mark
        ) {
            Text(AppLocale.number(count))
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(isCollapsed ? collapsedHelp : help)
        .accessibilityLabel(collapsedHelp)
    }

    /// The name and count, for the folded column's tooltip and for
    /// VoiceOver. A `String`, so neither goes through a localization lookup.
    private var collapsedHelp: String {
        title + " · " + AppLocale.number(count)
    }
}
