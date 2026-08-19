import SwiftUI
import VibeBarCore

/// Filterable projection of the exact merged price table used by cost scans.
/// The fixed viewport and LazyVStack keep large remote catalogs from inflating
/// the whole Settings page or eagerly creating every row.
struct EffectivePricingCatalogView: View {
    /// Passed in rather than read here: `effectiveModelPrices` rebuilds and
    /// sorts five provider tables on every access, and the enclosing section
    /// needs the same rows for its model count.
    let allRows: [EffectiveModelPricingRow]

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var searchText = ""
    @State private var selectedProvider: PricingProviderFamily?
    @State private var localOverridesOnly = false

    var body: some View {
        let rows = filteredRows(allRows)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Effective price table")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(rows.count) of \(allRows.count) models")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text("The resolved catalog currently used for cost calculations. Prices are USD per one million tokens; local overrides are already applied.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Filter model name", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button("All SubProviders") { selectedProvider = nil }
                    Divider()
                    ForEach(PricingProviderFamily.allCases) { provider in
                        Button(provider.label) { selectedProvider = provider }
                    }
                } label: {
                    Label(selectedProvider?.label ?? "All SubProviders", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.button)
                Toggle("Local overrides only", isOn: $localOverridesOnly)
                    .toggleStyle(.switch)
                    .fixedSize()
            }

            GeometryReader { proxy in
                let columns = PricingColumns(tableWidth: proxy.size.width)
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0) {
                        pricingHeader(columns: columns)
                        ForEach(rows) { row in
                            EffectivePricingRowView(
                                row: row,
                                isLocalOverride: localOverrideKeys.contains(row.normalizedKey),
                                columns: columns
                            )
                            Divider().opacity(0.45)
                        }
                    }
                    .frame(width: columns.tableWidth, alignment: .topLeading)
                }
            }
            .frame(height: 420)
            .background(Color.primary.opacity(0.018))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
            )
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "No matching models",
                        systemImage: "magnifyingglass",
                        description: Text("Change the SubProvider, model-name, or override filter.")
                    )
                }
            }

            if let mergedAt = environment.pricingRefreshStatus.mergedAt {
                Text("Active catalog merged \(mergedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private var localOverrideKeys: Set<String> {
        Set(settingsStore.settings.modelPricingOverrides.compactMap { entry in
            guard entry.isUsable else { return nil }
            return "\(entry.provider.rawValue):\(entry.normalizedModel)"
        })
    }

    private func filteredRows(
        _ rows: [EffectiveModelPricingRow]
    ) -> [EffectiveModelPricingRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let overrideKeys = localOverrideKeys
        return rows.filter { row in
            if let selectedProvider, row.provider != selectedProvider { return false }
            if localOverridesOnly, !overrideKeys.contains(row.normalizedKey) { return false }
            guard !query.isEmpty else { return true }
            return row.model.lowercased().contains(query)
                || row.displayLabel?.lowercased().contains(query) == true
                || row.companyName.lowercased().contains(query)
                || row.subProviderName.lowercased().contains(query)
        }
    }

    /// Rendered straight from the column spec the rows use, so a width or an
    /// alignment cannot drift between the header and the table under it.
    private func pricingHeader(columns: PricingColumns) -> some View {
        HStack(spacing: PricingColumns.spacing) {
            ForEach(columns.all) { column in
                Text(column.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.55)
                    .lineLimit(1)
                    .frame(width: column.width, alignment: column.frameAlignment)
            }
        }
        .padding(.horizontal, PricingColumns.horizontalInset)
        .frame(minHeight: 30)
        .background(Color.primary.opacity(0.05))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.11))
                .frame(height: 0.7)
        }
    }
}

// MARK: - Column spec

/// One column of the effective-price table. The header cell and every row
/// cell beneath it read their width and horizontal alignment from the same
/// value, which is the only thing that keeps the two in step — the header and
/// the rows are separate views with no layout relationship at all.
private struct PricingColumn: Identifiable {
    let title: String
    let width: CGFloat
    let alignment: HorizontalAlignment

    init(_ title: String, _ width: CGFloat, _ alignment: HorizontalAlignment = .leading) {
        self.title = title
        self.width = width
        self.alignment = alignment
    }

    var id: String { title }

    /// Vertical placement belongs to the row (`.firstTextBaseline`), so a
    /// cell's own frame only carries the horizontal axis.
    var frameAlignment: Alignment {
        Alignment(horizontal: alignment, vertical: .center)
    }
}

private struct PricingColumns {
    static let spacing: CGFloat = 8
    static let horizontalInset: CGFloat = 10

    static let minimumProviderWidth: CGFloat = 210
    static let minimumModelWidth: CGFloat = 300
    static let priceWidth: CGFloat = 96

    let provider: PricingColumn
    let model: PricingColumn
    let input = PricingColumn("Input / 1M", Self.priceWidth, .trailing)
    let output = PricingColumn("Output / 1M", Self.priceWidth, .trailing)
    let cacheRead = PricingColumn("Cache read", Self.priceWidth, .trailing)
    let cacheWrite = PricingColumn("Cache write", Self.priceWidth, .trailing)

    init(tableWidth: CGFloat) {
        let contentWidth = max(
            Self.minimumContentWidth,
            tableWidth - Self.horizontalInset * 2 - Self.spacing * 5
        )
        let extra = contentWidth - Self.minimumContentWidth
        provider = PricingColumn(
            "Provider / SubProvider",
            Self.minimumProviderWidth + extra * 0.42
        )
        model = PricingColumn("Model", Self.minimumModelWidth + extra * 0.58)
    }

    var all: [PricingColumn] { [provider, model, input, output, cacheRead, cacheWrite] }

    /// Where the MODEL column starts. The threshold / override footnote under
    /// a row hangs off this rather than a hand-tuned inset, so it stays on the
    /// grid when a column width changes.
    var detailInset: CGFloat { provider.width + Self.spacing }

    /// Narrower than this and the trailing price column clips, so the scroll
    /// surface never proposes less.
    static let minimumContentWidth = minimumProviderWidth + minimumModelWidth + priceWidth * 4

    var tableWidth: CGFloat {
        all.reduce(Self.horizontalInset * 2 + Self.spacing * 5) { $0 + $1.width }
    }
}

private struct EffectivePricingRowView: View {
    let row: EffectiveModelPricingRow
    let isLocalOverride: Bool
    let columns: PricingColumns

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // `.firstTextBaseline`, not the default centre: PROVIDER and
            // MODEL are two-line cells, and centring made each single-line
            // price float to their midpoint instead of sitting on the line
            // the header labels.
            HStack(alignment: .firstTextBaseline, spacing: PricingColumns.spacing) {
                HStack(spacing: 6) {
                    ToolBrandIconView(tool: row.tool, size: 13)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.companyName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(row.subProviderName)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(
                    width: columns.provider.width,
                    alignment: columns.provider.frameAlignment
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(row.displayLabel ?? row.model)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                    if row.displayLabel != nil {
                        Text(row.model)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(
                    width: columns.model.width,
                    alignment: columns.model.frameAlignment
                )

                price(row.inputPerMillion, columns.input)
                price(row.outputPerMillion, columns.output)
                price(row.cacheReadPerMillion, columns.cacheRead)
                price(row.cacheWritePerMillion, columns.cacheWrite)
            }

            if let detail = advancedDetail {
                HStack(spacing: 6) {
                    if isLocalOverride {
                        Text("LOCAL OVERRIDE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.blue)
                    }
                    Text(detail)
                        .font(.system(size: 8.5, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.leading, columns.detailInset)
            } else if isLocalOverride {
                Text("LOCAL OVERRIDE")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.blue)
                    .padding(.leading, columns.detailInset)
            }
        }
        .padding(.horizontal, PricingColumns.horizontalInset)
        .padding(.vertical, 7)
    }

    private func price(_ value: Double?, _ column: PricingColumn) -> some View {
        Text(value.map(Self.formatPrice) ?? "—")
            .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(value == nil ? Color.secondary : Color.primary)
            .opacity(value == nil ? 0.65 : 1)
            .frame(width: column.width, alignment: column.frameAlignment)
    }

    private var advancedDetail: String? {
        var parts: [String] = []
        if let threshold = row.thresholdTokens {
            var rates: [String] = []
            if let value = row.inputAboveThresholdPerMillion {
                rates.append("input \(Self.formatPrice(value))")
            }
            if let value = row.outputAboveThresholdPerMillion {
                rates.append("output \(Self.formatPrice(value))")
            }
            if let value = row.cacheReadAboveThresholdPerMillion {
                rates.append("cache read \(Self.formatPrice(value))")
            }
            if let value = row.cacheWriteAboveThresholdPerMillion {
                rates.append("cache write \(Self.formatPrice(value))")
            }
            let suffix = rates.isEmpty ? "" : ": " + rates.joined(separator: " · ")
            parts.append("Above \(threshold.formatted(.number.notation(.compactName))) tokens\(suffix)")
        }
        if let multiplier = row.fastMultiplier, multiplier != 1 {
            parts.append("Fast tier ×\(multiplier.formatted(.number.precision(.fractionLength(0...2))))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatPrice(_ value: Double) -> String {
        value.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(0...6))
                .presentation(.narrow)
        )
    }
}
