import SwiftUI
import VibeBarCore

/// Hardware arrangement is spatial: drag a panel, see the preview move, and
/// snap its edges to its neighbours. Settings are written only on release.
///
/// The same view, with `isEditable` off, is the group's page preview: every
/// screen drawing its part of the page, where it hangs. One drawing, so the
/// arrangement and the preview can never disagree about the shape of the
/// display.
struct EInkScreenArrangementView: View {
    let group: EInkScreenGroup
    let devices: [EInkDeviceConfig]
    let plans: [String: EInkPreviewPlan]
    @Binding var selection: String?
    var onChange: (EInkScreenGroup) -> Void
    var isEditable = true
    var height: CGFloat = 350

    @State private var draggingID: String?
    @State private var move: EInkScreenArrangement.Move?

    var body: some View {
        GeometryReader { geometry in
            let bounds = group.bounds(for: group.screens.map(\.id), devices: devices)
                ?? EInkRect(x: 0, y: 0, width: 296, height: 152)
            let scale = min(1.25, min((geometry.size.width - 120) / CGFloat(max(1, bounds.width)),
                                       (height - 100) / CGFloat(max(1, bounds.height))))
            let origin = CGPoint(x: (geometry.size.width - CGFloat(bounds.width) * scale) / 2,
                                 y: (height - CGFloat(bounds.height) * scale) / 2)
            ZStack(alignment: .topLeading) {
                grid
                if group.screens.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text(L10n.Settings.Eink.ScreenGroups.emptyBoard).font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                guides(origin: origin, bounds: bounds, scale: scale, width: geometry.size.width)
                ForEach(Array(group.screens.enumerated()), id: \.element.id) { index, screen in
                    if let rect = group.rect(for: screen.id, devices: devices) {
                        let x = draggingID == screen.id ? (move?.x ?? rect.x) : rect.x
                        let y = draggingID == screen.id ? (move?.y ?? rect.y) : rect.y
                        panel(screen.id, index: index, rect: rect, scale: scale)
                            .offset(x: origin.x + CGFloat(x - bounds.x) * scale, y: origin.y + CGFloat(y - bounds.y) * scale)
                            .zIndex(draggingID == screen.id ? 2 : 1)
                            .gesture(DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    guard isEditable else { return }
                                    draggingID = screen.id; selection = screen.id
                                    move = EInkScreenArrangement.move(screen.id,
                                        to: EInkPoint(x: rect.x + Int((value.translation.width / scale).rounded()),
                                                      y: rect.y + Int((value.translation.height / scale).rounded())),
                                        group: group, devices: devices, threshold: Int(10 / scale))
                                }
                                .onEnded { _ in
                                    guard isEditable else { return }
                                    if let move {
                                        onChange(EInkScreenArrangement.dropping(screen.id, move: move, group: group, devices: devices))
                                    }
                                    draggingID = nil; move = nil
                                },
                                including: isEditable ? .all : .subviews)
                    }
                }
                if isEditable {
                    VStack {
                        Spacer()
                        Text(L10n.Settings.Eink.ScreenGroups.dragHint)
                            .font(.caption2).foregroundStyle(.secondary).padding(10)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: height)
            .clipped()
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        }
        .frame(height: height)
        .onChange(of: group.screens) { _, screens in
            if !screens.contains(where: { $0.id == selection }) { selection = screens.first?.id }
        }
    }

    private var grid: some View {
        Canvas { context, size in
            var dots = Path()
            for x in stride(from: CGFloat(12), through: size.width, by: 18) {
                for y in stride(from: CGFloat(12), through: size.height, by: 18) {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            context.fill(dots, with: .color(.secondary.opacity(0.25)))
        }.allowsHitTesting(false)
    }

    private func panel(_ id: String, index: Int, rect: EInkRect, scale: CGFloat) -> some View {
        let name = devices.first { $0.id == id }.map { $0.alias.isEmpty ? $0.id : $0.alias } ?? id
        return ZStack {
            if let plan = plans[id] { EInkPreviewView(plan: plan, scale: scale) }
            else { Rectangle().fill(.white) }
        }
        .frame(width: CGFloat(rect.width) * scale, height: CGFloat(rect.height) * scale)
        .overlay(Rectangle().strokeBorder(selection == id ? Color.accentColor : Color.secondary, lineWidth: selection == id ? 2 : 0.8))
        .overlay(alignment: .topLeading) {
            Text("\(index + 1) · \(name)")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.background, in: RoundedRectangle(cornerRadius: 4))
                .offset(y: -24)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = id }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
        .help(isEditable ? L10n.Settings.Eink.ScreenGroups.dragHint : "")
    }

    private func guides(origin: CGPoint, bounds: EInkRect, scale: CGFloat, width: CGFloat) -> some View {
        Path { path in
            if let guide = move?.verticalGuide {
                let x = origin.x + CGFloat(guide - bounds.x) * scale
                path.move(to: CGPoint(x: x, y: 12)); path.addLine(to: CGPoint(x: x, y: height - 32))
            }
            if let guide = move?.horizontalGuide {
                let y = origin.y + CGFloat(guide - bounds.y) * scale
                path.move(to: CGPoint(x: 12, y: y)); path.addLine(to: CGPoint(x: width - 12, y: y))
            }
        }.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).allowsHitTesting(false)
    }
}
