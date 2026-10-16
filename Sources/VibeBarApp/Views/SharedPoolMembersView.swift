import SwiftUI
import VibeBarCore

/// Who drew from The X Subscription's one pool: one row per member — Grok,
/// Grok Bot, Cursor — with its mark, its share of the pool and a thin bar
/// scaled to the pool's used percent. Shares, not allowances: no reset, no
/// pace, no forecast, and the bars read against what the pool has used.
struct SharedPoolMembersView: View {
    let summary: SharedPoolSummary
    let density: Theme.Density

    var body: some View {
        let poolUsed = max(summary.bucket.usedPercent, summary.members.map(\.usedPercent).reduce(0, +))
        VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
            ForEach(summary.members, id: \.member) { share in
                HStack(alignment: .center, spacing: 8) {
                    memberMark(share.member)
                        .frame(width: 14, height: 14)
                    Text(memberName(share.member))
                        .font(.system(size: density.subtitleFontSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 72, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(.secondary)
                                .frame(width: poolUsed > 0
                                       ? proxy.size.width * CGFloat(min(1, share.usedPercent / poolUsed))
                                       : 0)
                        }
                    }
                    .frame(height: 5)
                    Text(share.usedPercent / 100, format: .percent.precision(.fractionLength(1)))
                        .font(.system(size: density.subtitleFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func memberMark(_ member: SharedPoolSummary.Member) -> some View {
        switch member {
        case .grok: ToolBrandIconView(tool: .grok, size: 13)
        case .grokBot: BrandMarkIconView(mark: .grokBot, size: 13)
        case .cursor: ToolBrandIconView(tool: .cursor, size: 13)
        case .other: Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func memberName(_ member: SharedPoolSummary.Member) -> String {
        switch member {
        case .grok: return ToolType.grok.toolName
        case .grokBot: return ToolType.cursor.quotaSubProviderName(bucketID: "grok_bot_weekly")
        case .cursor: return ToolType.cursor.toolName
        case .other: return L10n.Quota.Group.other
        }
    }
}
