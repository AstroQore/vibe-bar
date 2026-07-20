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
    /// Each menu bar item kind picks its own density via Settings.
    struct Density {
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
    }

    /// Standard popover density for single-provider popovers and detail views.
    static func density(for popover: PopoverDensity) -> Density {
        switch popover {
        case .compact:
            return Density(
                popoverPaddingH: 12, popoverPaddingV: 10,
                interSectionSpacing: 10, cardPadding: 10, cardSpacing: 8,
                bucketRowSpacing: 5, bucketGroupSpacing: 8,
                popoverWidth: 360, cardCornerRadius: 12,
                titleFontSize: 14, subtitleFontSize: 11,
                bucketTitleFontSize: 12, bucketPercentFontSize: 12,
                resetCountdownFontSize: 10, bucketBarHeight: 12,
                segmentedFontSize: 11
            )
        case .regular:
            return Density(
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
                popoverPaddingH: 20, popoverPaddingV: 18,
                interSectionSpacing: 18, cardPadding: 16, cardSpacing: 12,
                bucketRowSpacing: 8, bucketGroupSpacing: 14,
                popoverWidth: 500, cardCornerRadius: 16,
                titleFontSize: 18, subtitleFontSize: 13,
                bucketTitleFontSize: 14, bucketPercentFontSize: 14,
                resetCountdownFontSize: 12, bucketBarHeight: 12,
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
        let extraWidth: CGFloat
        switch popover {
        case .compact:  extraWidth = 500
        case .regular:  extraWidth = 520
        case .spacious: extraWidth = 560
        }
        return Density(
            popoverPaddingH: base.popoverPaddingH,
            popoverPaddingV: base.popoverPaddingV,
            interSectionSpacing: base.interSectionSpacing,
            cardPadding: base.cardPadding,
            cardSpacing: base.cardSpacing,
            bucketRowSpacing: base.bucketRowSpacing,
            bucketGroupSpacing: base.bucketGroupSpacing,
            popoverWidth: base.popoverWidth + extraWidth,
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
        let extraWidth: CGFloat
        switch popover {
        case .compact:  extraWidth = 500
        case .regular:  extraWidth = 540
        case .spacious: extraWidth = 580
        }
        return Density(
            popoverPaddingH: base.popoverPaddingH,
            popoverPaddingV: base.popoverPaddingV,
            interSectionSpacing: base.interSectionSpacing,
            cardPadding: base.cardPadding,
            cardSpacing: base.cardSpacing,
            bucketRowSpacing: base.bucketRowSpacing,
            bucketGroupSpacing: base.bucketGroupSpacing,
            popoverWidth: base.popoverWidth + extraWidth,
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
