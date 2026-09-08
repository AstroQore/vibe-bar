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
    let hovered: Set<UUID>
    let lifted: Set<UUID>
    let scheme: ColorScheme
    let zoom: CGFloat
    let frames: MenuBarStageFrames
    let naming: MenuBarTokenNaming
    @State private var nativeOrigin = CGPoint.zero
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
                    .mask {
                        Canvas { context, size in
                            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                            context.blendMode = .copy
                            for rect in drawing.tokens.values {
                                context.fill(Path(CGRect(x: rect.minX * zoom, y: rect.minY * zoom,
                                    width: rect.width * zoom, height: rect.height * zoom)), with: .color(.clear))
                            }
                        }
                    }
                    .accessibilityLabel(plan.spokenDescription)
                // Stable token identities let native pixels move smoothly;
                // replacing one full-strip bitmap cannot animate a reflow.
                ForEach(composition.segments.flatMap(\.tokens)) { token in
                    if let rect = drawing.tokens[token.id] {
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: drawing.image)
                                .offset(x: -rect.minX * zoom, y: -rect.minY * zoom)
                        }
                        .frame(width: rect.width * zoom, height: rect.height * zoom, alignment: .topLeading)
                        .clipped()
                        .transaction { $0.animation = nil }
                        .opacity(lifted.contains(token.id) ? 0.22 : 1)
                        .offset(x: rect.minX * zoom, y: rect.minY * zoom)
                        .allowsHitTesting(false)
                    }
                }
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
                    if let rect = union(members.map(\.id), drawing: drawing) {
                        StudioSelectionOutline(isSelected: members.contains { selection.contains($0.id) })
                            .opacity(members.contains { selection.contains($0.id) || hovered.contains($0.id) } ? 1 : 0.3)
                            .frame(width: rect.width * zoom + 4, height: rect.height * zoom + 4)
                            .offset(x: rect.minX * zoom - 2, y: rect.minY * zoom - 2)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(MenuBarStageSpace.name)).origin } action: { origin in
                nativeOrigin = origin
                reportGeometry(drawing, origin: origin)
            }
            .onChange(of: drawing.tokens) { _, _ in reportGeometry(drawing, origin: nativeOrigin) }
            .onAppear { reportGeometry(drawing, origin: nativeOrigin) }
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

    private func reportGeometry(_ drawing: MenuBarNativeRenderer.Drawing, origin: CGPoint) {
        let tokenFrames = drawing.tokens.mapValues { rect in
            CGRect(x: origin.x + rect.minX * zoom, y: origin.y + rect.minY * zoom,
                   width: rect.width * zoom, height: rect.height * zoom)
        }
        func bounds(_ ids: [UUID]) -> CGRect? {
            let rect = ids.compactMap { tokenFrames[$0] }.reduce(CGRect.null) { $0.union($1) }
            return rect.isNull ? nil : rect
        }
        var rowFrames: [MenuBarComposition.RowAddress: CGRect] = [:]
        for segment in composition.segments {
            for row in MenuBarSegment.Row.allCases {
                if let rect = bounds(segment[row].map(\.id)) { rowFrames[.init(segment: segment.id, row: row)] = rect }
            }
        }
        var groupFrames: [UUID: CGRect] = [:]
        for group in bound {
            let members = composition.segments.flatMap(\.tokens).filter { $0.groupID == group }.map(\.id)
            if let anchor = members.first, let rect = bounds(members) { groupFrames[anchor] = rect.insetBy(dx: -2, dy: -2) }
        }
        frames.replaceNativeGeometry(tokens: tokenFrames, rows: rowFrames, groups: groupFrames, emptyRows: Set(emptyRows))
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
        return Color.clear
            .overlay {
                if !grouped && (selection.contains(token.id) || hovered.contains(token.id)) {
                    StudioSelectionOutline(isSelected: selection.contains(token.id))
                }
            }
            .frame(width: rect.width * zoom, height: rect.height * zoom)
            .offset(x: rect.minX * zoom, y: rect.minY * zoom)
            .contentShape(Rectangle())
            .contextMenu { tokenMenu(token) }
            .help(naming.title(token))
    }

    private func rowRegion(_ address: MenuBarComposition.RowAddress, rect: CGRect) -> some View {
        Color.clear
            .frame(width: rect.width * zoom, height: rect.height * zoom)
            .offset(x: rect.minX * zoom, y: rect.minY * zoom)
            .allowsHitTesting(false)
    }
}
