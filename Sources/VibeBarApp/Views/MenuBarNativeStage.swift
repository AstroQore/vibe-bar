import AppKit
import SwiftUI
import VibeBarCore

/// The status item's actual drawing, with editing affordances outside its
/// pixels. Hit regions come from the drawing's measurements, not estimates.
struct MenuBarNativeStage<TokenMenu: View, SegmentMenu: View>: View {
    let composition: MenuBarComposition
    let plan: MenuBarRenderPlan
    let template: MenuBarComposition.Template
    let quotas: [MenuBarQuotaSnapshot]
    let displayMode: DisplayMode
    let availability: MenuBarComposition.Availability
    let bound: Set<UUID>
    let selection: Set<UUID>
    let lifted: Set<UUID>
    let scheme: ColorScheme
    let zoom: CGFloat
    let frames: MenuBarStageFrames
    let naming: MenuBarTokenNaming
    @ViewBuilder var tokenMenu: (MenuBarToken) -> TokenMenu
    @ViewBuilder var segmentMenu: (MenuBarSegment, Int) -> SegmentMenu

    var body: some View {
        let drawing = MenuBarNativeRenderer.render(
            plan: plan, quotas: quotas, template: template, displayMode: displayMode,
            appearance: NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!, magnification: zoom
        )
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: drawing.image)
                    .frame(width: drawing.size.width * zoom, height: drawing.size.height * zoom)
                    .accessibilityLabel(plan.spokenDescription)
                ForEach(Array(composition.segments.enumerated()), id: \.element.id) { index, segment in
                    if let rect = union(segment.tokens.map(\.id), drawing: drawing) {
                        HStack(spacing: 2) {
                            if rect.width * zoom > 60 {
                                Text(L10n.MenuBar.Composer.Segment.title(index: index + 1))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            segmentMenu(segment, index)
                        }
                        .frame(width: rect.width * zoom, height: 14)
                        .offset(x: rect.minX * zoom, y: -18)
                    }
                    ForEach(segment.tokens) { token in
                        if let rect = drawing.tokens[token.id] {
                            tokenRegion(token, rect: rect)
                        }
                    }
                    ForEach(MenuBarSegment.Row.allCases, id: \.self) { row in
                        if let rect = union(segment[row].map(\.id), drawing: drawing) {
                            rowRegion(.init(segment: segment.id, row: row), rect: rect)
                        }
                    }
                }
                ForEach(Array(bound), id: \.self) { group in
                    let members = composition.segments.flatMap(\.tokens).filter { $0.groupID == group }
                    if let anchor = members.first?.id, let rect = union(members.map(\.id), drawing: drawing) {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor.opacity(members.contains { selection.contains($0.id) } ? 0.9 : 0.25), lineWidth: 1)
                            .background(Color.accentColor.opacity(members.contains { selection.contains($0.id) } ? 0.10 : 0.025))
                            .frame(width: rect.width * zoom + 4, height: rect.height * zoom + 4)
                            .offset(x: rect.minX * zoom - 2, y: rect.minY * zoom - 2)
                            .allowsHitTesting(false)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MenuBarStageSpace.name)) } action: {
                                frames.groups[anchor] = $0
                            }
                            .onDisappear { frames.groups.removeValue(forKey: anchor) }
                    }
                }
            }
            .padding(.top, 18)
            if !emptyRows.isEmpty {
                HStack(spacing: 8) {
                    ForEach(emptyRows, id: \.self) { address in
                        Text(L10n.MenuBar.Composer.Row.empty)
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(6)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])))
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MenuBarStageSpace.name)) } action: {
                                frames.report($0, row: address)
                            }
                            .onDisappear { frames.forget(row: address) }
                    }
                }
            }
        }
        .fixedSize()
        .environment(\.colorScheme, scheme)
    }

    private var emptyRows: [MenuBarComposition.RowAddress] {
        composition.segments.flatMap { segment in
            (segment.isStacked ? MenuBarSegment.Row.allCases : [.top]).compactMap { row in
                segment[row].isEmpty ? .init(segment: segment.id, row: row) : nil
            }
        }
    }

    private func union(_ ids: [UUID], drawing: MenuBarNativeRenderer.Drawing) -> CGRect? {
        let rect = ids.compactMap { drawing.tokens[$0] }.reduce(CGRect.null) { $0.union($1) }
        return rect.isNull ? nil : rect
    }

    private func tokenRegion(_ token: MenuBarToken, rect: CGRect) -> some View {
        let grouped = token.groupID.map(bound.contains) ?? false
        return Rectangle()
            .fill(Color.accentColor.opacity(!grouped && selection.contains(token.id) ? 0.14 : 0))
            .overlay {
                if !grouped && selection.contains(token.id) { Rectangle().strokeBorder(Color.accentColor, lineWidth: 1) }
            }
            .frame(width: rect.width * zoom, height: rect.height * zoom)
            .offset(x: rect.minX * zoom, y: rect.minY * zoom)
            .contentShape(Rectangle())
            .contextMenu { tokenMenu(token) }
            .help(naming.title(token))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MenuBarStageSpace.name)) } action: {
                frames.report($0, token: token.id)
            }
            .onDisappear { frames.forget(token: token.id) }
    }

    private func rowRegion(_ address: MenuBarComposition.RowAddress, rect: CGRect) -> some View {
        Color.clear
            .frame(width: rect.width * zoom, height: rect.height * zoom)
            .offset(x: rect.minX * zoom, y: rect.minY * zoom)
            .allowsHitTesting(false)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MenuBarStageSpace.name)) } action: {
                frames.report($0, row: address)
            }
            .onDisappear { frames.forget(row: address) }
    }
}
