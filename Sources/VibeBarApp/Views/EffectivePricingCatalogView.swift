import SwiftUI
import VibeBarCore

/// Filterable projection of the exact merged price table used by cost scans.
/// The fixed viewport and LazyVStack keep large remote catalogs from inflating
/// the whole Settings page or eagerly creating every row.
struct EffectivePricingCatalogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var searchText = ""
    @State private var selectedProvider: PricingProviderFamily?
    @State private var localOverridesOnly = false

    var body: some View {
        let allRows = PricingResolver.active.effectiveModelPrices
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

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0) {
                    pricingHeader
                    ForEach(rows) { row in
                        EffectivePricingRowView(
                            row: row,
                            isLocalOverride: localOverrideKeys.contains(row.normalizedKey)
                        )
                        Divider().opacity(0.45)
                    }
                }
                .frame(minWidth: 780, alignment: .topLeading)
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

    private var pricingHeader: some View {
        HStack(spacing: 8) {
            headerCell("Provider / SubProvider", width: 154)
            headerCell("Model", width: 242)
            headerCell("Input / 1M", width: 84, alignment: .trailing)
            headerCell("Output / 1M", width: 84, alignment: .trailing)
            headerCell("Cache read", width: 84, alignment: .trailing)
            headerCell("Cache write", width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .background(Color.primary.opacity(0.035))
    }

    private func headerCell(
        _ text: String,
        width: CGFloat,
        alignment: Alignment = .leading
    ) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.45)
            .frame(width: width, alignment: alignment)
    }
}

private struct EffectivePricingRowView: View {
    let row: EffectiveModelPricingRow
    let isLocalOverride: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
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
                .frame(width: 154, alignment: .leading)

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
                .frame(width: 242, alignment: .leading)

                price(row.inputPerMillion)
                price(row.outputPerMillion)
                price(row.cacheReadPerMillion)
                price(row.cacheWritePerMillion)
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
                .padding(.leading, 168)
            } else if isLocalOverride {
                Text("LOCAL OVERRIDE")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.blue)
                    .padding(.leading, 168)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func price(_ value: Double?) -> some View {
        Text(value.map(Self.formatPrice) ?? "—")
            .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(value == nil ? Color.secondary : Color.primary)
            .opacity(value == nil ? 0.65 : 1)
            .frame(width: 84, alignment: .trailing)
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
