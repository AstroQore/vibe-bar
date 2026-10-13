import SwiftUI

/// The Workbench's navigation pieces, shared by the window's own sidebar and
/// by every page that has a navigator of its own (Sessions' harnesses,
/// Settings' sections).
///
/// The window reads as three levels — the window's navigation, the page's,
/// the content — and the two navigation levels are one design at two
/// weights: the same row, the same group label, the same selection and
/// hover, the same hairline between columns. What tells them apart is the
/// mark (the sidebar's rows wear a tinted icon block, a page's rows a bare
/// symbol or brand mark), the title weight, and the fill one step closer to
/// the page. See `docs/DESIGN.md` § 2.1.
///
/// Every piece here is a leaf: a row owns only its hover state, and nothing
/// reads a list or derives data in `body`.

private typealias Metrics = WorkbenchPorcelain.Navigation

/// A page's own navigation column: a header slot over a scrolling stack of
/// rows, on the secondary fill, with a hairline on its trailing edge.
///
/// It runs the full height of the window, beside the page header rather than
/// under it, so the page's navigation reads as a column of the window and
/// not as a panel inside the page. The header slot is one row tall — a title
/// with a fold button on Sessions, the search field on Settings — so the
/// first row lands on the same line on every page. Folded, the column keeps
/// only its marks, each exactly where the sidebar draws its icon blocks.
struct WorkbenchSecondaryColumn<Header: View, Content: View>: View {
    let isCollapsed: Bool
    let header: Header
    let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        isCollapsed: Bool = false,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.isCollapsed = isCollapsed
        self.header = header()
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            // The header slot is one row, spaced like one: the column's rows
            // then fall on the sidebar's row lines.
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                header
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Metrics.rowHeight,
                        maxHeight: Metrics.rowHeight,
                        alignment: isCollapsed ? .center : .leading
                    )
                    .padding(.horizontal, Metrics.columnInset)
                    .padding(.top, Metrics.topInset)
                LazyScrollContainer {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                            content
                        }
                        .padding(.horizontal, Metrics.columnInset)
                        .padding(.bottom, Metrics.topInset)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(width: isCollapsed ? Metrics.secondaryCollapsedWidth : Metrics.secondaryWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(WorkbenchPorcelain.secondaryColumnFill(for: colorScheme))
            WorkbenchColumnDivider()
        }
        // Hand-drawn rows: the system focus ring stays off and each row's
        // `VibeBarButtonStyle` hairline marks keyboard focus. A native field
        // in the header slot puts the system ring back for itself.
        .vibeBarControlFocus()
    }
}

/// A secondary column's name, for a header slot that has no control of its
/// own to show. Starts where the rows' marks start.
struct WorkbenchSecondaryColumnTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, Metrics.rowPadding)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One row of any Workbench navigation column.
///
/// `level` is the only difference between the sidebar's rows and a page's:
/// the sidebar's titles are semibold, a page's medium. Everything else —
/// height, corner, padding, the selected fill and hairline, the hover fill,
/// the accent title on the selected row — is the same token on both.
///
/// The accessory slot carries what a page puts after the title: a count on
/// Sessions, a status dot and drag handle on Settings' providers. Context
/// menus, drag and drop, tooltips and accessibility labels are the caller's
/// modifiers on the row, as they would be on any button.
struct WorkbenchNavigationRow<Mark: View, Accessory: View>: View {
    enum Level {
        /// The window's sidebar.
        case window
        /// A page's own column.
        case page
    }

    let title: String
    let subtitle: String?
    let level: Level
    let isSelected: Bool
    let isCollapsed: Bool
    /// A row for something switched off: quieter, still selectable.
    let isDimmed: Bool
    let action: () -> Void
    let mark: Mark
    let accessory: Accessory

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    init(
        title: String,
        subtitle: String? = nil,
        level: Level = .page,
        isSelected: Bool,
        isCollapsed: Bool = false,
        isDimmed: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder mark: () -> Mark,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.level = level
        self.isSelected = isSelected
        self.isCollapsed = isCollapsed
        self.isDimmed = isDimmed
        self.action = action
        self.mark = mark()
        self.accessory = accessory()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous)
        Button(action: action) {
            label
                .padding(.horizontal, isCollapsed ? 0 : Metrics.rowPadding)
                .frame(
                    maxWidth: .infinity,
                    minHeight: Metrics.rowHeight,
                    alignment: isCollapsed ? .center : .leading
                )
                .background(shape.fill(fill))
                .overlay(
                    shape.strokeBorder(
                        isSelected ? WorkbenchPorcelain.hairline(for: colorScheme) : Color.clear,
                        lineWidth: Theme.Card.hairlineWidth
                    )
                )
                .contentShape(shape)
        }
        .buttonStyle(.vibeBar(cornerRadius: Metrics.rowCornerRadius))
        .onHover { isHovering = $0 }
        .opacity(quiet ? 0.62 : 1)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var label: some View {
        if isCollapsed {
            mark
                .frame(width: Metrics.markSize, height: Metrics.markSize)
        } else {
            HStack(spacing: Metrics.markSpacing) {
                mark
                    .frame(width: Metrics.markSize, height: Metrics.markSize)
                    .opacity(quiet ? 0.48 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: Metrics.titleSize, weight: level == .window ? .semibold : .medium))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                accessory
            }
            .foregroundStyle(titleColor)
        }
    }

    private var quiet: Bool { isDimmed && !isSelected }

    private var titleColor: Color {
        if isSelected { return WorkbenchPorcelain.accent }
        return isDimmed ? Color.secondary : Color.primary.opacity(0.82)
    }

    private var fill: Color {
        if isSelected { return WorkbenchPorcelain.selectedNavigationFill(for: colorScheme) }
        return isHovering ? WorkbenchPorcelain.hoverFill(for: colorScheme) : Color.clear
    }
}

extension WorkbenchNavigationRow where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        level: Level = .page,
        isSelected: Bool,
        isCollapsed: Bool = false,
        isDimmed: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder mark: () -> Mark
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            level: level,
            isSelected: isSelected,
            isCollapsed: isCollapsed,
            isDimmed: isDimmed,
            action: action,
            mark: mark,
            accessory: { EmptyView() }
        )
    }
}

/// An SF Symbol as a page row's mark: quiet until its row is selected, then
/// in the accent like the title beside it.
struct WorkbenchNavigationSymbol: View {
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isSelected ? WorkbenchPorcelain.accent : Color.secondary)
    }
}

/// A group label inside a navigation column — the sidebar's "Library",
/// Settings' "Core providers". One style for both levels, starting where the
/// rows' marks start.
struct WorkbenchNavigationSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.horizontal, Metrics.rowPadding)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The hairline between two columns of the window. It runs up through the
/// title bar with the columns' fills, so the window reads as one sheet cut
/// into columns rather than panels stacked under a strip.
struct WorkbenchColumnDivider: View {
    var axis: Axis = .vertical

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(WorkbenchPorcelain.hairline(for: colorScheme))
            .frame(
                width: axis == .vertical ? Theme.Card.hairlineWidth : nil,
                height: axis == .horizontal ? Theme.Card.hairlineWidth : nil
            )
            .ignoresSafeArea(.container, edges: axis == .vertical ? .vertical : [])
            .accessibilityHidden(true)
    }
}
