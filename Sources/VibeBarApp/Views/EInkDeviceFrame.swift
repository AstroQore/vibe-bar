import SwiftUI
import VibeBarCore

/// A panel drawn the way it is read, inside the outline of the device holding
/// it, with a notch on the hardware's own top edge.
///
/// The notch is the whole point. Once the preview is upright
/// (`EInkPreviewView`), all four orientations look like a page — so nothing on
/// screen says which way the device is actually turned any more. The outline
/// says it: at 0° the notch is at the top; at 90° the canvas was turned
/// clockwise into the panel, so reading it upright means turning the device
/// counter-clockwise and the notch ends up on the left.
struct EInkDeviceFrame<Content: View>: View {
    let orientation: EInkOrientation
    let paperWidth: CGFloat
    let paperHeight: CGFloat
    var isSelected: Bool = false
    @ViewBuilder var content: () -> Content

    private static var bezel: CGFloat { 6 }

    var body: some View {
        content()
            .frame(width: paperWidth, height: paperHeight)
            .padding(Self.bezel)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(alignment: notchAlignment) { notch }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.18),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .accessibilityHidden(true)
    }

    private var isVerticalEdge: Bool {
        orientation.uprightDeviceEdge == .left || orientation.uprightDeviceEdge == .right
    }

    private var notch: some View {
        Capsule(style: .continuous)
            .fill(Color.primary.opacity(0.45))
            .frame(
                width: isVerticalEdge ? 2.5 : 22,
                height: isVerticalEdge ? 22 : 2.5
            )
            .padding(1.5)
    }

    private var notchAlignment: Alignment {
        switch orientation.uprightDeviceEdge {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}

/// The four orientations as four upright panels.
///
/// Round 1 offered four abstract glyphs and, underneath, a grid of the same
/// slide drawn sideways twice. This is one control: the slide as it will be
/// read in each rotation, at half device scale, with the chosen one outlined.
struct EInkOrientationPicker: View {
    let orientation: EInkOrientation
    let plans: [Int: EInkPreviewPlan]
    let profile: EInkDeviceProfile
    var onSelect: (EInkOrientation) -> Void

    /// Half device pixels. A quarter of the ink is unreadable and full size is
    /// three times wider than the pane; at half, the *shape* of the layout —
    /// which is what an orientation choice is about — still reads.
    private static let scale: CGFloat = 0.5

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(EInkOrientation.allCases, id: \.rawValue) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    option(candidate)
                }
                .buttonStyle(.plain)
                .help(EInkNaming.orientation(candidate))
            }
            Spacer(minLength: 0)
        }
    }

    private func option(_ candidate: EInkOrientation) -> some View {
        let size = candidate.physicalFrame(profile)
        // No caption under the panels: the four say what they are by their
        // shape and their notch, and the only words that fit under a 76 pt
        // portrait frame would be a truncated sentence. The full one is the
        // tooltip, and the note under the row explains the notch once.
        return EInkDeviceFrame(
            orientation: candidate,
            paperWidth: CGFloat(size.width) * Self.scale,
            paperHeight: CGFloat(size.height) * Self.scale,
            isSelected: candidate == orientation
        ) {
            if let plan = plans[candidate.rawValue] {
                EInkPreviewView(plan: plan, scale: Self.scale)
            } else {
                Rectangle().fill(Color.white)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The panel outline, small, with the device's own top edge marked — the
/// toolbar's version of `EInkDeviceFrame`, where there is no room for paper.
struct EInkOrientationGlyph: View {
    let orientation: EInkOrientation

    var body: some View {
        let portrait = orientation.isPortrait
        let width: CGFloat = portrait ? 13 : 22
        let height: CGFloat = portrait ? 22 : 13
        ZStack(alignment: notchAlignment) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
            Rectangle()
                .fill(Color.accentColor)
                .frame(
                    width: isVerticalEdge ? 2.5 : width - 6,
                    height: isVerticalEdge ? height - 6 : 2.5
                )
                .padding(2)
        }
        .frame(width: width, height: height)
        .padding(3)
    }

    private var isVerticalEdge: Bool {
        orientation.uprightDeviceEdge == .left || orientation.uprightDeviceEdge == .right
    }

    /// The device's top edge, not the drawing's: `uprightDeviceEdge` is the
    /// one answer both this and the settings picker read.
    private var notchAlignment: Alignment {
        switch orientation.uprightDeviceEdge {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}
