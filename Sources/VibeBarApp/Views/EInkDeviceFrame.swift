import SwiftUI
import VibeBarCore

/// The proportions of a Quote/0, measured off the hardware.
///
/// The device is a long white bar, not a screen-sized tile: the 296 × 152
/// panel sits behind a thin bezel at one end and fills a little over half the
/// bar's length, the rest is blank plastic, and the USB-C port is centred in
/// the short edge at the screen end. Every number here is a ratio of the
/// panel's own short side, so the chrome scales with the preview while the
/// preview itself stays pixel-true.
enum EInkChassis {
    /// The bezel between the panel and the plastic around it. 8 px of 152.
    static let bezelRatio: CGFloat = 0.055
    /// Plastic outside the bezel, on the three edges the body is not on.
    /// 14 px of 152 — what makes the bar thicker than the screen area.
    static let rimRatio: CGFloat = 0.092
    /// The share of the bar's length the screen area takes. 313 of 602.
    static let screenShare: CGFloat = 0.52
    /// Corner radius as a share of the bar's short side.
    static let cornerRatio: CGFloat = 0.12
}

/// A panel drawn the way it is read, inside a line-art schematic of the
/// device holding it.
///
/// Round 2 drew a rounded rectangle the size of the panel with a notch on the
/// device's top edge. The owner's photograph of the real thing is a bar twice
/// as long as its screen, and nothing about a notch said so. This draws the
/// bar: the panel at one end, the blank body at the other, the port on the
/// screen's own short edge — and because the body can only be in one place
/// per rotation (`EInkOrientation.uprightBodyEdge`), the shape alone says
/// which way the device is turned. No notch, and no sentence explaining one.
struct EInkDeviceFrame<Content: View>: View {
    let orientation: EInkOrientation
    let paperWidth: CGFloat
    let paperHeight: CGFloat
    var isSelected: Bool = false
    @ViewBuilder var content: () -> Content

    /// The bar runs along the panel's long side, always: the body extends off
    /// a short edge of the screen, whichever way the device is hung.
    private var isHorizontal: Bool {
        orientation.uprightBodyEdge == .left || orientation.uprightBodyEdge == .right
    }

    private var paperShort: CGFloat { min(paperWidth, paperHeight) }
    private var bezel: CGFloat { max(1, (paperShort * EInkChassis.bezelRatio).rounded()) }
    private var rim: CGFloat { max(1, (paperShort * EInkChassis.rimRatio).rounded()) }

    /// How far the blank half extends past the screen area.
    private var bodyLength: CGFloat {
        let screenArea = max(paperWidth, paperHeight) + 2 * bezel
        return max(4, (screenArea / EInkChassis.screenShare - screenArea).rounded())
    }

    private var barShort: CGFloat { paperShort + 2 * bezel + 2 * rim }
    private var corner: CGFloat { barShort * EInkChassis.cornerRatio }

    var body: some View {
        chassis
            .overlay(alignment: portAlignment) { port }
            .accessibilityHidden(true)
    }

    private var chassis: some View {
        halves
            .padding(rim)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.3),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
    }

    /// The screen end and the blank end, in the order the body edge asks for.
    @ViewBuilder
    private var halves: some View {
        let bodyFirst = orientation.uprightBodyEdge == .left || orientation.uprightBodyEdge == .top
        if isHorizontal {
            HStack(spacing: 0) {
                if bodyFirst { blankBody }
                screen
                if !bodyFirst { blankBody }
            }
        } else {
            VStack(spacing: 0) {
                if bodyFirst { blankBody }
                screen
                if !bodyFirst { blankBody }
            }
        }
    }

    private var screen: some View {
        content()
            .frame(width: paperWidth, height: paperHeight)
            .padding(bezel)
            .background(Color.primary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: max(2, bezel * 0.6), style: .continuous))
    }

    /// White plastic. Drawn as space rather than as a fill, so the schematic
    /// reads as one bar with a screen in it and not as two blocks.
    ///
    /// Both dimensions are stated: `Color.clear` is infinitely flexible, and
    /// left to itself it takes every point the enclosing row can spare — which
    /// is a device the size of the pane.
    private var blankBody: some View {
        let across = paperShort + 2 * bezel
        return Color.clear
            .frame(
                width: isHorizontal ? bodyLength : across,
                height: isHorizontal ? across : bodyLength
            )
    }

    /// The USB-C port, centred in the short edge at the screen end.
    private var port: some View {
        let portIsVertical = orientation.uprightPortEdge == .left
            || orientation.uprightPortEdge == .right
        return Capsule(style: .continuous)
            .fill(Color.primary.opacity(0.35))
            .frame(
                width: portIsVertical ? 2 : barShort * 0.22,
                height: portIsVertical ? barShort * 0.22 : 2
            )
            .padding(1.5)
    }

    private var portAlignment: Alignment {
        switch orientation.uprightPortEdge {
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
                // The panel inside is hidden from accessibility — it is a
                // picture of the slide, not a control — so the button would
                // otherwise have no name at all to read out.
                .accessibilityLabel(EInkNaming.orientation(candidate))
                .accessibilityAddTraits(candidate == orientation ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
    }

    private func option(_ candidate: EInkOrientation) -> some View {
        let size = candidate.physicalFrame(profile)
        // No caption under the panels: the four say what they are by their
        // shape — where the blank half of the bar sits — and the only words
        // that fit under a 76 pt portrait frame would be a truncated
        // sentence. The full one is the tooltip.
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

/// The device, small: the toolbar's version of `EInkDeviceFrame`, where
/// there is no room for paper.
///
/// The same bar, the same proportions, the screen end filled in — so the
/// Studio's toolbar and the settings picker say the orientation the same way.
struct EInkOrientationGlyph: View {
    let orientation: EInkOrientation

    /// The panel's short side at glyph scale; everything else follows the
    /// chassis ratios, exactly as the big frame does.
    private static let paperShort: CGFloat = 9

    private var isHorizontal: Bool {
        orientation.uprightBodyEdge == .left || orientation.uprightBodyEdge == .right
    }

    var body: some View {
        let short = Self.paperShort * (1 + 2 * EInkChassis.bezelRatio + 2 * EInkChassis.rimRatio)
        let long = (Self.paperShort * 296 / 152 + 2) / EInkChassis.screenShare
        let screenLong = long * EInkChassis.screenShare - 2
        return ZStack(alignment: screenAlignment) {
            RoundedRectangle(cornerRadius: short * EInkChassis.cornerRatio, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.accentColor)
                .frame(
                    width: isHorizontal ? screenLong - 3 : Self.paperShort - 1,
                    height: isHorizontal ? Self.paperShort - 1 : screenLong - 3
                )
                .padding(2)
        }
        .frame(
            width: isHorizontal ? long : short,
            height: isHorizontal ? short : long
        )
        .padding(3)
    }

    /// The screen sits at the end opposite the body — the port end.
    private var screenAlignment: Alignment {
        switch orientation.uprightPortEdge {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}
