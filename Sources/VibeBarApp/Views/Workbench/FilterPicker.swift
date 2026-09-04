import AppKit
import SwiftUI
import VibeBarCore

/// One entry a filter picker offers.
struct FilterPickerRow<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    /// A measure beside the name — how many sessions, how many tokens.
    var detail: String?
    let accent: Color
    let icon: AnyView
    /// What typing matches against: the title, the company, the identifier.
    let searchKeys: [String]
}

/// A group of rows under a head that toggles them together.
struct FilterPickerSection<ID: Hashable>: Identifiable {
    let id: String
    var title: String?
    var icon: AnyView?
    let rows: [FilterPickerRow<ID>]
}

/// The picker every Workbench filter opens: a type-to-filter field, All and
/// None, then sections whose head toggles the group and rows that toggle one
/// entry (⌥-click keeps only that one).
///
/// A popover rather than a menu on purpose. A menu closes on every click, so
/// choosing three harnesses meant opening it three times; here the list
/// stays open until the user is done, and the field at the top finds an
/// entry by any name it goes by — "anthropic" finds Claude Code through its
/// company. See AGENTS.md § 7.1 for why the unit is the harness.
struct FilterPickerList<ID: Hashable>: View {
    let density: Theme.Density
    let sections: [FilterPickerSection<ID>]
    let searchPlaceholder: String
    /// Shown when there is nothing to list at all — the range recorded no
    /// model, say — as opposed to nothing matching what was typed.
    var emptyMessage: String?
    /// A picker whose empty selection means "everything" has no None.
    var showsNone = true
    let isSelected: (ID) -> Bool
    let toggle: (ID) -> Void
    let solo: (ID) -> Void
    let toggleGroup: ([ID]) -> Void
    let selectAll: () -> Void
    let selectNone: () -> Void

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var visibleSections: [FilterPickerSection<ID>] {
        sections.compactMap { section in
            let rows = section.rows.filter { FilterQuery.matches($0.searchKeys, query: query) }
            guard !rows.isEmpty else { return nil }
            return FilterPickerSection(id: section.id, title: section.title, icon: section.icon, rows: rows)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if visibleSections.isEmpty {
                        Text(sections.allSatisfy(\.rows.isEmpty) ? (emptyMessage ?? L10n.Workbench.Filter.noMatches) : L10n.Workbench.Filter.noMatches)
                            .font(.system(size: density.subtitleFontSize))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    ForEach(visibleSections) { section in
                        if section.title != nil {
                            sectionHead(section)
                        }
                        ForEach(section.rows) { row in
                            rowButton(row, indented: section.title != nil)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)
            Divider().opacity(0.5)
            Text(L10n.Workbench.Filter.soloHint)
                .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .frame(width: 300)
        // The picker exists to be typed into, so it is the one presentation
        // that opens with its search field live — after the house policy has
        // cleared whatever AppKit picked first.
        .vibeBarNoInitialFocus(thenFocus: { isSearchFocused = true })
        // A native field and buttons: the system focus ring is what says
        // where typing goes.
        .vibeBarSystemControlFocus()
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: density.segmentedFontSize - 1))
                    .foregroundStyle(.secondary)
                TextField(searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: max(12, density.segmentedFontSize)))
                    .focused($isSearchFocused)
                if !query.isEmpty {
                    BorderlessIconButton(systemImage: "xmark.circle.fill", help: L10n.Common.clear) {
                        query = ""
                    }
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 26)
            .workbenchFieldSurface(cornerRadius: 13)
            Button(L10n.Common.all) { selectAll() }
                .buttonStyle(WorkbenchPillButtonStyle())
                .fixedSize()
            if showsNone {
                Button(L10n.Workbench.Filter.none) { selectNone() }
                    .buttonStyle(WorkbenchPillButtonStyle())
                    .fixedSize()
            }
        }
        .padding(10)
    }

    /// The company head: a tri-state mark, and one click toggles every row
    /// under it. Quieter than its rows — context, not another level to
    /// filter by.
    private func sectionHead(_ section: FilterPickerSection<ID>) -> some View {
        let ids = section.rows.map(\.id)
        let selectedCount = ids.count(where: isSelected)
        let state: TriState = selectedCount == 0 ? .none : (selectedCount == ids.count ? .all : .some)
        return Button {
            toggleGroup(ids)
        } label: {
            HStack(spacing: 7) {
                checkbox(state)
                if let icon = section.icon { icon }
                Text(section.title ?? "")
                    .font(.system(size: max(9, density.segmentedFontSize - 2), weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func rowButton(_ row: FilterPickerRow<ID>, indented: Bool) -> some View {
        let selected = isSelected(row.id)
        return Button {
            if NSEvent.modifierFlags.contains(.option) {
                solo(row.id)
            } else {
                toggle(row.id)
            }
        } label: {
            HStack(spacing: 8) {
                checkbox(selected ? .all : .none)
                row.icon
                Text(row.title)
                    .font(.system(size: density.segmentedFontSize, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: max(9, density.resetCountdownFontSize), design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, indented ? 16 : 8)
            .padding(.trailing, 10)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(row.accent.opacity(selected ? 0.12 : 0))
            )
            .contentShape(Rectangle())
            .opacity(selected ? 1 : 0.7)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private enum TriState { case none, some, all }

    private func checkbox(_ state: TriState) -> some View {
        Group {
            switch state {
            case .all: Image(systemName: "checkmark.circle.fill")
            case .some: Image(systemName: "minus.circle.fill")
            case .none: Image(systemName: "circle")
            }
        }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(state == .none ? Color.secondary.opacity(0.6) : Color.accentColor)
            .frame(width: 16)
    }
}

/// The pill in a Workbench filter bar that opens a picker below it.
struct FilterPickerButton<Content: View>: View {
    let density: Theme.Density
    let systemImage: String
    let title: String
    let detail: String
    var prominent = false
    var accessibilityLabel: String?
    @ViewBuilder let content: () -> Content

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: max(8, density.segmentedFontSize - 2), weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title.uppercased())
                    .font(.system(size: max(8, density.segmentedFontSize - 3), weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.4)
                Text(detail)
                    .font(.system(size: density.segmentedFontSize - 1, weight: .semibold, design: .rounded)
                        .monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 28)
        }
        .buttonStyle(WorkbenchPillButtonStyle(prominent: prominent))
        .fixedSize()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content()
        }
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}

/// Harness rows the way both the Sessions and Usage Stats pickers spell them:
/// grouped under their L1 company, each with its own mark, findable by any of
/// its names.
enum HarnessPickerRows {
    static func sections(
        groups: [Harness.ChipGroup],
        density: Theme.Density,
        detail: (Harness) -> String?
    ) -> [FilterPickerSection<Harness>] {
        groups.map { group in
            FilterPickerSection(
                id: group.company.rawValue,
                title: group.company.vendorName,
                icon: AnyView(CompanyBrandIconView(tool: group.company, size: 11)),
                rows: group.harnesses.map { harness in
                    FilterPickerRow(
                        id: harness,
                        title: harness.displayName,
                        detail: detail(harness),
                        accent: Theme.providerAccent(for: group.company),
                        icon: AnyView(
                            HarnessBrandIconView(harness: harness, size: density.segmentedFontSize + 2, brandColored: true)
                        ),
                        searchKeys: [
                            harness.displayName,
                            harness.companyName,
                            harness.quotaTool.menuTitle,
                            harness.rawValue,
                        ]
                    )
                }
            )
        }
    }
}
