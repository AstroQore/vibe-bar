import SwiftUI
import VibeBarCore

enum Theme {
    static let sectionCornerRadius: CGFloat = 18
    static let sectionPadding: CGFloat = 16
    static let popoverPadding: CGFloat = 18
    static let interSectionSpacing: CGFloat = 14

    static let miniWindowWidth: CGFloat = 288
    static let miniCornerRadius: CGFloat = 22
    static let glassPillCornerRadius: CGFloat = 12

    /// Per-density spacing/sizing for the popover. Returned by `Theme.density(for:)`.
    /// One profile drives the full tabbed workspace. The semantic tokens below
    /// deliberately change layout, chart presence, and information rhythm —
    /// not just every number by the same scale factor.
    /// `Equatable` so views that are expensive to rebuild can be wrapped in
    /// `.equatable()` and skip a parent-driven update that changed nothing —
    /// notably the quota history chart, which lives inside a `TimelineView`
    /// that re-proposes it every 30 seconds.
    struct Density: Equatable {
        let profile: PopoverDensity
        let popoverPaddingH: CGFloat
        let popoverPaddingV: CGFloat
        let interSectionSpacing: CGFloat
        let cardPadding: CGFloat
        let cardSpacing: CGFloat
        let bucketRowSpacing: CGFloat
        let bucketGroupSpacing: CGFloat
        let popoverWidth: CGFloat
        let cardCornerRadius: CGFloat
        let titleFontSize: CGFloat
        let subtitleFontSize: CGFloat
        let bucketTitleFontSize: CGFloat
        let bucketPercentFontSize: CGFloat
        let resetCountdownFontSize: CGFloat
        let bucketBarHeight: CGFloat
        let segmentedFontSize: CGFloat

        var headerHeight: CGFloat {
            switch profile {
            case .compact: 34
            case .regular: 40
            case .spacious: 48
            }
        }

        var overviewSummaryHeight: CGFloat {
            switch profile {
            case .compact: 148
            case .regular: 178
            case .spacious: 210
            }
        }

        var overviewCostChartHeight: CGFloat {
            switch profile {
            case .compact: 154
            case .regular: 190
            case .spacious: 230
            }
        }

        var detailCostChartHeight: CGFloat {
            switch profile {
            case .compact: 136
            case .regular: 168
            case .spacious: 208
            }
        }

        /// Main plot height for the quota history line chart. Slightly shorter
        /// than the cost chart at the same density: it lives in the narrow
        /// quota column and carries a brush strip underneath.
        var quotaHistoryChartHeight: CGFloat {
            switch profile {
            case .compact: 140
            case .regular: 172
            case .spacious: 210
            }
        }

        /// Main plot height for the all-providers quota history chart on the
        /// Overview. Taller than the per-group chart: it carries every
        /// provider's curves at once and sits in a wider Overview column.
        var overviewQuotaHistoryChartHeight: CGFloat {
            switch profile {
            case .compact: 172
            case .regular: 206
            case .spacious: 248
            }
        }

        /// Height of the scrubber strip below a navigable chart.
        var chartBrushHeight: CGFloat {
            switch profile {
            case .compact: 40
            case .regular: 44
            case .spacious: 50
            }
        }

        var utilizationBarHeight: CGFloat {
            switch profile {
            case .compact: 28
            case .regular: 36
            case .spacious: 46
            }
        }

        var activityBarHeight: CGFloat {
            switch profile {
            case .compact: 48
            case .regular: 64
            case .spacious: 82
            }
        }

        var detailLeftColumnFraction: CGFloat {
            switch profile {
            case .compact: 0.38
            case .regular: 0.37
            case .spacious: 0.35
            }
        }

        var detailLeftColumnRange: ClosedRange<CGFloat> {
            switch profile {
            case .compact: 300...350
            case .regular: 350...410
            case .spacious: 390...455
            }
        }

        var detailRightColumnMinimum: CGFloat {
            switch profile {
            case .compact: 460
            case .regular: 520
            case .spacious: 620
            }
        }

        var miscColumnCount: Int {
            switch profile {
            case .compact: 3
            case .regular: 3
            case .spacious: 3
            }
        }

        var statusGroupSpacing: CGFloat {
            switch profile {
            case .compact: 8
            case .regular: 12
            case .spacious: 16
            }
        }

        var statusComponentSpacing: CGFloat {
            switch profile {
            case .compact: 5
            case .regular: 8
            case .spacious: 11
            }
        }

        var statusStripHeight: CGFloat {
            switch profile {
            case .compact: 9
            case .regular: 12
            case .spacious: 14
            }
        }
    }

    /// Standard popover density for single-provider popovers and detail views.
    static func density(for popover: PopoverDensity) -> Density {
        switch popover {
        case .compact:
            return Density(
                profile: .compact,
                popoverPaddingH: 12, popoverPaddingV: 10,
                interSectionSpacing: 10, cardPadding: 10, cardSpacing: 8,
                bucketRowSpacing: 5, bucketGroupSpacing: 8,
                popoverWidth: 360, cardCornerRadius: 12,
                titleFontSize: 14, subtitleFontSize: 11,
                bucketTitleFontSize: 12, bucketPercentFontSize: 12,
                resetCountdownFontSize: 10, bucketBarHeight: 10,
                segmentedFontSize: 11
            )
        case .regular:
            return Density(
                profile: .regular,
                popoverPaddingH: 16, popoverPaddingV: 14,
                interSectionSpacing: 14, cardPadding: 14, cardSpacing: 10,
                bucketRowSpacing: 6, bucketGroupSpacing: 12,
                popoverWidth: 420, cardCornerRadius: 14,
                titleFontSize: 16, subtitleFontSize: 12,
                bucketTitleFontSize: 13, bucketPercentFontSize: 13,
                resetCountdownFontSize: 11, bucketBarHeight: 12,
                segmentedFontSize: 12
            )
        case .spacious:
            return Density(
                profile: .spacious,
                popoverPaddingH: 20, popoverPaddingV: 18,
                interSectionSpacing: 18, cardPadding: 16, cardSpacing: 12,
                bucketRowSpacing: 8, bucketGroupSpacing: 14,
                popoverWidth: 500, cardCornerRadius: 16,
                titleFontSize: 18, subtitleFontSize: 13,
                bucketTitleFontSize: 14, bucketPercentFontSize: 14,
                resetCountdownFontSize: 12, bucketBarHeight: 14,
                segmentedFontSize: 13
            )
        }
    }

    /// Overview popover density. The Overview lays out *all* providers as a
    /// two-column waterfall (Quotas left, Cost right), so it needs more width
    /// than a single-provider popover. Spacing scales similarly to the
    /// per-density preset but the popoverWidth is roughly doubled.
    static func overviewDensity(for popover: PopoverDensity) -> Density {
        let base = density(for: popover)
        let workspaceWidth: CGFloat
        switch popover {
        case .compact:  workspaceWidth = 860
        case .regular:  workspaceWidth = 960
        case .spacious: workspaceWidth = 1120
        }
        return Density(
            profile: base.profile,
            popoverPaddingH: base.popoverPaddingH,
            popoverPaddingV: base.popoverPaddingV,
            interSectionSpacing: base.interSectionSpacing,
            cardPadding: base.cardPadding,
            cardSpacing: base.cardSpacing,
            bucketRowSpacing: base.bucketRowSpacing,
            bucketGroupSpacing: base.bucketGroupSpacing,
            popoverWidth: workspaceWidth,
            cardCornerRadius: base.cardCornerRadius,
            titleFontSize: base.titleFontSize,
            subtitleFontSize: base.subtitleFontSize,
            bucketTitleFontSize: base.bucketTitleFontSize,
            bucketPercentFontSize: base.bucketPercentFontSize,
            resetCountdownFontSize: base.resetCountdownFontSize,
            bucketBarHeight: base.bucketBarHeight,
            segmentedFontSize: base.segmentedFontSize
        )
    }

    /// Provider detail popovers need a little more horizontal room than the
    /// Overview: the quota/utilization column should keep a useful minimum
    /// width while the chart column still has enough space for both heatmaps.
    static func detailDensity(for popover: PopoverDensity) -> Density {
        let base = density(for: popover)
        let workspaceWidth: CGFloat
        switch popover {
        case .compact:  workspaceWidth = 860
        case .regular:  workspaceWidth = 960
        case .spacious: workspaceWidth = 1120
        }
        return Density(
            profile: base.profile,
            popoverPaddingH: base.popoverPaddingH,
            popoverPaddingV: base.popoverPaddingV,
            interSectionSpacing: base.interSectionSpacing,
            cardPadding: base.cardPadding,
            cardSpacing: base.cardSpacing,
            bucketRowSpacing: base.bucketRowSpacing,
            bucketGroupSpacing: base.bucketGroupSpacing,
            popoverWidth: workspaceWidth,
            cardCornerRadius: base.cardCornerRadius,
            titleFontSize: base.titleFontSize,
            subtitleFontSize: base.subtitleFontSize,
            bucketTitleFontSize: base.bucketTitleFontSize,
            bucketPercentFontSize: base.bucketPercentFontSize,
            resetCountdownFontSize: base.resetCountdownFontSize,
            bucketBarHeight: base.bucketBarHeight,
            segmentedFontSize: base.segmentedFontSize
        )
    }

    /// Brand accent per provider — the hue that identifies a tool wherever a
    /// surface has to tell providers apart by colour rather than by name.
    ///
    /// One table, because a provider that is teal in the mini window and green
    /// in a chart is two providers as far as the reader is concerned.
    static func providerAccent(for tool: ToolType) -> Color {
        switch tool {
        case .codex:       return Color(red: 0.30, green: 0.78, blue: 0.74)  // teal
        case .claude:      return Color(red: 0.93, green: 0.40, blue: 0.40)  // coral
        case .alibaba:     return Color(red: 1.00, green: 0.62, blue: 0.20)  // amber
        case .alibabaTokenPlan: return Color(red: 1.00, green: 0.48, blue: 0.18)  // deeper amber
        case .gemini:      return Color(red: 0.34, green: 0.62, blue: 0.96)  // google blue
        case .antigravity: return Color(red: 0.55, green: 0.40, blue: 0.92)  // violet
        case .grok:        return Color(red: 0.18, green: 0.18, blue: 0.18)  // xAI near-black
        case .copilot:     return Color(red: 0.46, green: 0.46, blue: 0.46)  // graphite
        case .zai:         return Color(red: 0.26, green: 0.74, blue: 0.55)  // emerald
        case .minimax:     return Color(red: 0.97, green: 0.30, blue: 0.45)  // pink
        case .kimi:        return Color(red: 0.20, green: 0.20, blue: 0.20)  // ink
        case .cursor:      return Color(red: 0.55, green: 0.55, blue: 0.96)  // periwinkle
        case .mimo:        return Color(red: 0.97, green: 0.50, blue: 0.20)  // xiaomi orange
        case .iflytek:     return Color(red: 0.10, green: 0.37, blue: 0.75)  // iflytek blue
        case .tencentHunyuan:   return Color(red: 0.00, green: 0.49, blue: 0.91)  // tencent blue
        case .tencentTokenPlan: return Color(red: 0.18, green: 0.62, blue: 0.96)  // tencent token blue
        case .volcengine:  return Color(red: 0.92, green: 0.30, blue: 0.30)  // doubao red
        case .volcengineAgentPlan: return Color(red: 0.96, green: 0.45, blue: 0.22)  // doubao agent amber
        case .baiduQianfan: return Color(red: 0.16, green: 0.40, blue: 0.93)  // baidu blue
        case .openCodeGo:  return Color(red: 0.22, green: 0.66, blue: 0.50)  // green
        case .kilo:        return Color(red: 0.47, green: 0.37, blue: 0.93)  // purple
        case .kiro:        return Color(red: 0.24, green: 0.48, blue: 0.94)  // blue
        case .ollama:      return Color(red: 0.18, green: 0.18, blue: 0.18)  // graphite
        case .openRouter:  return Color(red: 0.98, green: 0.62, blue: 0.16)  // orange
        case .warp:        return Color(red: 0.58, green: 0.55, blue: 0.71)  // warp violet-grey
        }
    }

    static func barColor(percent: Double, mode: DisplayMode) -> Color {
        switch mode {
        case .remaining:
            if percent < 10 { return Color(red: 0.96, green: 0.30, blue: 0.30) }
            if percent < 30 { return Color(red: 0.97, green: 0.62, blue: 0.20) }
            return Color(red: 0.18, green: 0.74, blue: 0.55)
        case .used:
            if percent >= 90 { return Color(red: 0.96, green: 0.30, blue: 0.30) }
            if percent >= 70 { return Color(red: 0.97, green: 0.62, blue: 0.20) }
            return Color(red: 0.20, green: 0.66, blue: 0.78)
        }
    }

    static let barTrack = Color.primary.opacity(0.08)
}
