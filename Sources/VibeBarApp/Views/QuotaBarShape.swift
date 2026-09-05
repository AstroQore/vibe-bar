import SwiftUI
import VibeBarCore

struct QuotaBarShape: View {
    let percent: Double          // 0...100, value to render
    let mode: DisplayMode
    var height: CGFloat = 11
    var indeterminate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let pct = max(0, min(100, percent)) / 100
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.barTrack)
                if indeterminate {
                    if reduceMotion {
                        Capsule(style: .continuous)
                            .strokeBorder(.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    } else {
                        Capsule(style: .continuous)
                            .fill(.secondary.opacity(0.45))
                            .frame(width: max(height, width * 0.3))
                            .offset(x: sweeping ? width : -width * 0.3)
                            .animation(.linear(duration: 1.6).repeatForever(autoreverses: false), value: sweeping)
                    }
                } else {
                    Capsule(style: .continuous)
                        .fill(Theme.barColor(percent: percent, mode: mode))
                        .frame(width: max(height, width * pct))
                }
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
        .onAppear { sweeping = indeterminate }
        .onDisappear { sweeping = false }
    }
}

struct MiniQuotaBar: View {
    let percent: Double
    let mode: DisplayMode

    var body: some View {
        QuotaBarShape(percent: percent, mode: mode, height: 6)
    }
}
