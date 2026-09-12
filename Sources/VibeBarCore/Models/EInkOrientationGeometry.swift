import Foundation

/// How a rotated panel reads to somebody holding the device.
///
/// Round 1 drew every orientation inside the same 296 × 152 rectangle with the
/// content turned on its side, which is what the *encoder* does and exactly
/// what a person does not: a panel set to 90° is hung portrait, and the reader
/// sees a 152 × 296 page with upright words on it. Previewing the encoder's
/// intermediate picture made the two portrait rotations look broken in
/// Settings while the device itself was fine.
///
/// The three answers below are the whole of the difference, and they are here
/// rather than in the view so the Studio, the settings preview and the
/// read-back thumbnail cannot each invent their own.
public extension EInkOrientation {
    /// Which physical edge of the panel — the edge the device's own top is on
    /// — points up once the content reads upright.
    ///
    /// The encoder turns the authored canvas *clockwise* by `rawValue`, so a
    /// 90° slide has its content's top along the panel's right edge; turning
    /// the device counter-clockwise to read it puts the device's top edge on
    /// the reader's left.
    enum DeviceEdge: String, CaseIterable, Sendable {
        case top, right, bottom, left
    }

    var uprightDeviceEdge: DeviceEdge {
        switch self {
        case .degrees0: .top
        case .degrees90: .left
        case .degrees180: .bottom
        case .degrees270: .right
        }
    }

    /// The frame the reader sees: 296 × 152 landscape, 152 × 296 portrait.
    ///
    /// The same numbers a layout is authored in — which is the point. Upright
    /// content and the authored canvas are the same picture, so a preview that
    /// draws the authored boxes in this frame with no rotation is showing the
    /// panel as it will be read.
    func physicalFrame(_ profile: EInkDeviceProfile = .quote0) -> (width: Int, height: Int) {
        profile.frameSize(for: self)
    }

    /// Clockwise degrees the device's own read-back raster (always the panel's
    /// native 296 × 152) has to be turned by before it reads upright.
    var uprightImageDegrees: Int { (360 - rawValue) % 360 }
}
