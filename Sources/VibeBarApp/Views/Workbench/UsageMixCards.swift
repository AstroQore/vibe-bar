import Charts
import SwiftUI
import VibeBarCore

/// The share donuts kept from the previous Usage page: where the tokens went
/// (fresh input, cache read, cache write, output), which harness spent them,
/// and which company that harness bills. Projects and models moved to the
/// ranking cards, which carry the same numbers with cost and sessions.
///
/// Each donut is one `SectorMark` chart of at most six slices, drawn once per
/// snapshot (`Equatable`); there is no hover state, the legend carries every
/// figure.
struct UsageMixRow: View, Equatable {
    let density: Theme.Density
    let tokens: UsageTokenSplit
    let mix: UsageDashboardSnapshot.Mix

    var body: some View {
        HStack(alignment: .top, spacing: density.interSectionSpacing) {
            UsageDonutCard(
                density: density,
                title: L10n.Usage.Mix.TokenFlow.title,
                subtitle: L10n.Usage.Mix.TokenFlow.subtitle,
                emptyMessage: L10n.Usage.Mix.TokenFlow.empty,
                slices: flowSlices
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            UsageDonutCard(
                density: density,
                title: L10n.Usage.Mix.Harness.title,
                subtitle: L10n.Usage.Mix.Harness.subtitle,
                emptyMessage: L10n.Usage.HarnessMix.empty,
                slices: UsageDonutCard.collapsed(mix.harnesses.map { slice in
                    UsageDonutCard.Slice(
                        id: slice.id,
                        label: slice.harness?.displayName ?? slice.id,
                        detail: slice.harness?.companyName,
                        tokens: slice.tokens,
                        costMicros: slice.costMicros,
                        color: slice.harness?.usageTint ?? .gray
                    )
                })
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            UsageDonutCard(
                density: density,
                title: L10n.Usage.Mix.Provider.title,
                subtitle: L10n.Usage.Mix.Provider.subtitle,
                emptyMessage: L10n.Usage.Mix.Provider.empty,
                slices: UsageDonutCard.collapsed(mix.companies.map { slice in
                    UsageDonutCard.Slice(
                        id: slice.id,
                        label: slice.company?.vendorName ?? slice.id,
                        detail: nil,
                        tokens: slice.tokens,
                        costMicros: slice.costMicros,
                        color: slice.company.map(Theme.providerAccent(for:)) ?? .gray
                    )
                })
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var flowSlices: [UsageDonutCard.Slice] {
        [
            UsageDonutCard.Slice(id: "fresh", label: L10n.Usage.Tokens.input, detail: nil, tokens: tokens.input, costMicros: nil, color: UsageTokenPalette.input),
            UsageDonutCard.Slice(id: "cache-read", label: L10n.Usage.Tokens.cacheRead, detail: nil, tokens: tokens.cacheRead, costMicros: nil, color: UsageTokenPalette.cacheRead),
            UsageDonutCard.Slice(id: "cache-write", label: L10n.Usage.Tokens.cacheWrite, detail: nil, tokens: tokens.cacheWrite, costMicros: nil, color: UsageTokenPalette.cacheWrite),
            UsageDonutCard.Slice(id: "output", label: L10n.Usage.Tokens.output, detail: nil, tokens: tokens.output, costMicros: nil, color: UsageTokenPalette.output),
        ].filter { $0.tokens > 0 }
    }
}

/// The four token buckets' colours, shared by the hero strip and the donut.
enum UsageTokenPalette {
    static let input = Color.blue
    static let output = Color.green
    static let cacheWrite = Color.orange
    static let cacheRead = Color.purple
}

struct UsageDonutCard: View, Equatable {
    struct Slice: Identifiable, Equatable {
        let id: String
        let label: String
        let detail: String?
        let tokens: Int64
        let costMicros: Int64?
        let color: Color
    }

    let density: Theme.Density
    let title: String
    let subtitle: String
    let emptyMessage: String
    let slices: [Slice]

    /// The top five and one "Other" slice.
    static func collapsed(_ rows: [Slice], visible: Int = 5) -> [Slice] {
        let sorted = rows.filter { $0.tokens > 0 }.sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }
        guard sorted.count > visible else { return sorted }
        let tail = sorted.dropFirst(visible)
        return Array(sorted.prefix(visible)) + [
            Slice(
                id: "other",
                label: L10n.Usage.Mix.other,
                detail: L10n.Usage.Mix.otherCount(count: tail.count),
                tokens: tail.reduce(0) { $0 + $1.tokens },
                costMicros: tail.compactMap(\.costMicros).reduce(0, +),
                color: Color.secondary.opacity(0.55)
            ),
        ]
    }

    private var total: Int64 { max(1, slices.reduce(0) { $0 + $1.tokens }) }

    var body: some View {
        CardShell(density: density, spacing: 10) {
            UsageCardHeader(density: density, title: title, subtitle: subtitle)
            if slices.isEmpty {
                UsageEmptyMessage(density: density, text: emptyMessage, systemImage: "chart.pie")
            } else {
                HStack(spacing: 12) {
                    donut
                        .frame(width: 104, height: 112)
                    legend
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var donut: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Tokens", Double(slice.tokens)),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(2)
            .foregroundStyle(slice.color)
        }
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame {
                    let rect = geometry[frame]
                    VStack(spacing: 0) {
                        Text(UsageFormatting.compactTokens(total))
                            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        Text(L10n.Usage.Mix.donutUnit)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(slices) { slice in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(slice.color).frame(width: 7, height: 7)
                    Text(slice.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(slice.detail ?? slice.label)
                    Spacer(minLength: 4)
                    Text(UsageDashboardFormat.percent(Double(slice.tokens) / Double(total)))
                        .font(.system(size: 10, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(UsageFormatting.compactTokens(slice.tokens))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .frame(minWidth: 46, alignment: .trailing)
                }
                .lineLimit(1)
            }
        }
    }
}
