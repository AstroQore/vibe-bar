import SwiftUI
import VibeBarCore

struct QuotaBarShape: View {
    let percent: Double          // 0...100, value to render
    let mode: DisplayMode
    var height: CGFloat = 11

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let pct = max(0, min(100, percent)) / 100
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.barTrack)
                Capsule(style: .continuous)
                    .fill(Theme.barColor(percent: percent, mode: mode))
                    .frame(width: max(height, width * pct))
            }
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
