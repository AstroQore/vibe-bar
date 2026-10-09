import SwiftUI
import VibeBarCore

/// The Sessions page's left column: one row per harness that has sessions,
/// with its count, and "All" on top.
///
/// The unit is the harness, never the company (AGENTS.md § 7.1): the list
/// beside it is labelled by harness, and two harnesses can share an adapter.
/// Counts are the index's listed rows — Auto Reviews already excluded — and
/// the line under a count says how many of them are threads folded under
/// another session, so a number the list does not seem to add up to
/// explains itself. Narrow windows fold the column to its marks.
struct SessionHarnessRail: View {
    let density: Theme.Density
    let controller: SessionsPageController
    let navigation: SessionNavigationModel
    let isCollapsed: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            LazyScrollContainer { railScrollView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkbenchPorcelain.sidebarFill(for: colorScheme))
    }

    private var railScrollView: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    allRow
                    ForEach(navigation.entries) { entry in
                        harnessRow(entry)
                    }
                }
                .padding(.horizontal, isCollapsed ? 4 : 8)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if !isCollapsed {
                Text(L10n.Usage.Mix.Dimension.harnesses)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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
        }
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
        .padding(.horizontal, isCollapsed ? 0 : 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var allRow: some View {
        SessionRailRow(
            density: density,
            isCollapsed: isCollapsed,
            isSelected: navigation.isAllSelected,
            title: L10n.Common.all,
            count: navigation.total,
            threads: navigation.threadTotal,
            help: L10n.Workbench.Sessions.Rail.allHelp
        ) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        } action: { _ in
            controller.selectAllHarnesses()
        }
    }

    private func harnessRow(_ entry: SessionNavigationModel.Entry) -> some View {
        SessionRailRow(
            density: density,
            isCollapsed: isCollapsed,
            isSelected: navigation.isSelected(entry.harness),
            title: entry.harness.displayName,
            count: entry.count,
            threads: entry.threads,
            help: L10n.Workbench.Sessions.Rail.selectHelp(harness: entry.harness.displayName)
        ) {
            HarnessBrandBadge(harness: entry.harness, iconSize: 15, containerSize: 20, brandColored: true)
        } action: { extending in
            controller.selectHarness(entry.harness, extending: extending)
        }
    }
}

/// One row of the harness column. Its own view so hover state stays local
/// to the row the pointer is over.
private struct SessionRailRow<Mark: View>: View {
    let density: Theme.Density
    let isCollapsed: Bool
    let isSelected: Bool
    let title: String
    let count: Int
    let threads: Int
    let help: String
    @ViewBuilder let mark: () -> Mark
    let action: (_ extending: Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button {
            action(NSEvent.modifierFlags.contains(.command))
        } label: {
            Group {
                if isCollapsed {
                    mark()
                        .frame(maxWidth: .infinity, minHeight: 34)
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        mark()
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(isSelected ? WorkbenchPorcelain.accent : Color.primary.opacity(0.82))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(AppLocale.number(count))
                                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if threads > 0 {
                                Text(L10n.Workbench.Sessions.Rail.threadsIncluded(count: threads))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.vibeBar)
        .onHover { isHovering = $0 }
        .help(isCollapsed ? collapsedHelp : help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(collapsedHelp)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action(false) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The name and count, for the folded column's tooltip and for
    /// VoiceOver. A `String`, so neither goes through a localization lookup.
    private var collapsedHelp: String {
        title + " · " + AppLocale.number(count)
    }

    private var fill: Color {
        if isSelected { return WorkbenchPorcelain.selectedNavigationFill(for: colorScheme) }
        return isHovering ? WorkbenchPorcelain.hoverFill(for: colorScheme) : .clear
    }
}
