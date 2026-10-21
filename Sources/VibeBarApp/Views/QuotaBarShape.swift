import SwiftUI
import VibeBarCore

struct QuotaBarShape: View {
    let percent: Double          // 0...100, value to render
    let mode: DisplayMode
    var height: CGFloat = 11
    /// A bar with no percentage to show. It stays still: a track that keeps
    /// moving asks for the eye and, over the popover's blur, for a frame
    /// every tick.
    var indeterminate = false
    /// Remaining mode's product split, drawn in the empty part of the bar.
    var productLayer: QuotaProductTrackLayer? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let pct = max(0, min(100, percent)) / 100
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.barTrack)
                if indeterminate {
                    Capsule(style: .continuous)
                        .strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                } else {
                    Capsule(style: .continuous)
                        .fill(Theme.barColor(percent: percent, mode: mode))
                        .frame(width: max(height, width * pct))
                    if let productLayer {
                        productLayer.body(width: width, height: height, fillWidth: max(height, width * pct), scheme: colorScheme)
                    }
                }
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
    }
}

struct MiniQuotaBar: View {
    let percent: Double
    let mode: DisplayMode

    var body: some View {
        QuotaBarShape(percent: percent, mode: mode, height: 6)
    }
}
