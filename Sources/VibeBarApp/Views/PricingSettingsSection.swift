import SwiftUI
import VibeBarCore

struct PricingSettingsSection: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("Model Pricing") {
                Text("Catalogs refresh in the background. Higher entries win when the same provider and model name appears more than once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(
                    "Refresh every",
                    selection: $settingsStore.settings.pricingRefreshIntervalSeconds
                ) {
                    ForEach(AppSettings.pricingRefreshIntervalOptions, id: \.self) { seconds in
                        Text(intervalLabel(seconds)).tag(seconds)
                    }
                }

                HStack {
                    Button(action: environment.refreshPricingNow) {
                        Label(
                            environment.isRefreshingPricing ? "Refreshing…" : "Refresh now",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(environment.isRefreshingPricing)

                    if let date = environment.pricingRefreshStatus.mergedAt {
                        Text("Merged \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(environment.pricingRefreshStatus.mergedModelCount) models")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            settingsSection("Priority and source health") {
                priorityRow(number: 1, name: "Local overrides", detail: "Always wins")
                ForEach(Array(PricingSourceID.allCases.enumerated()), id: \.element) { index, source in
                    sourceRow(number: index + 2, source: source)
                }
                priorityRow(
                    number: PricingSourceID.allCases.count + 2,
                    name: "Bundled fallback",
                    detail: "Offline floor"
                )
            }

            settingsSection("Local overrides") {
                Text("Prices are USD per one million tokens. Leave cache fields empty when the provider does not publish them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settingsStore.settings.modelPricingOverrides.isEmpty {
                    Text("No local overrides.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                ForEach($settingsStore.settings.modelPricingOverrides) { $override in
                    PricingOverrideEditor(override: $override) {
                        settingsStore.settings.modelPricingOverrides.removeAll {
                            $0.id == override.id
                        }
                    }
                    Divider()
                }

                Button {
                    settingsStore.settings.modelPricingOverrides.append(ModelPricingOverride())
                } label: {
                    Label("Add model override", systemImage: "plus")
                }
            }
        }
    }

    private func sourceRow(number: Int, source: PricingSourceID) -> some View {
        let status = environment.pricingRefreshStatus.sources.first { $0.source == source }
        return HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)
            Circle()
                .fill(statusColor(status?.result ?? .never))
                .frame(width: 7, height: 7)
            Text(source.label)
            Spacer()
            Text(sourceDetail(status))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func priorityRow(number: Int, name: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)
            Circle().fill(.secondary).frame(width: 7, height: 7)
            Text(name)
            Spacer()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func sourceDetail(_ status: PricingSourceStatus?) -> String {
        guard let status else { return "Not refreshed" }
        switch status.result {
        case .ready: return "\(status.modelCount) models"
        case .unchanged: return "\(status.modelCount) models · unchanged"
        case .failed: return "Cached \(status.modelCount) · refresh failed"
        case .never: return "Not refreshed"
        }
    }

    private func statusColor(_ result: PricingSourceRefreshResult) -> Color {
        switch result {
        case .ready, .unchanged: .green
        case .failed: .orange
        case .never: .secondary
        }
    }

    private func intervalLabel(_ seconds: Int) -> String {
        let hours = seconds / 3600
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }
}

private struct PricingOverrideEditor: View {
    @Binding var override: ModelPricingOverride
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Provider", selection: $override.provider) {
                    ForEach(PricingProviderFamily.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                TextField("Exact model name", text: $override.model)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete override")
            }

            HStack {
                rateField("Input", value: $override.inputPerMillion)
                rateField("Output", value: $override.outputPerMillion)
                optionalRateField("Cache read", keyPath: \.cacheReadPerMillion)
                optionalRateField("Cache write", keyPath: \.cacheWritePerMillion)
            }

            DisclosureGroup("Advanced tiers") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        optionalIntegerField("Threshold tokens", keyPath: \.thresholdTokens)
                        optionalRateField("Input above", keyPath: \.inputAboveThresholdPerMillion)
                        optionalRateField("Output above", keyPath: \.outputAboveThresholdPerMillion)
                    }
                    HStack {
                        optionalRateField("Cache read above", keyPath: \.cacheReadAboveThresholdPerMillion)
                        optionalRateField("Cache write above", keyPath: \.cacheWriteAboveThresholdPerMillion)
                        optionalRateField("Fast multiplier", keyPath: \.fastMultiplier)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
    }

    private func rateField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("0", value: value, format: .number.precision(.fractionLength(0...6)))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func optionalRateField(
        _ title: String,
        keyPath: WritableKeyPath<ModelPricingOverride, Double?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("—", text: optionalDoubleBinding(keyPath))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func optionalIntegerField(
        _ title: String,
        keyPath: WritableKeyPath<ModelPricingOverride, Int?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("—", text: optionalIntBinding(keyPath))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func optionalDoubleBinding(
        _ keyPath: WritableKeyPath<ModelPricingOverride, Double?>
    ) -> Binding<String> {
        Binding(
            get: {
                guard let value = override[keyPath: keyPath] else { return "" }
                return String(value)
            },
            set: { raw in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                override[keyPath: keyPath] = trimmed.isEmpty ? nil : Double(trimmed)
            }
        )
    }

    private func optionalIntBinding(
        _ keyPath: WritableKeyPath<ModelPricingOverride, Int?>
    ) -> Binding<String> {
        Binding(
            get: { override[keyPath: keyPath].map(String.init) ?? "" },
            set: { raw in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                override[keyPath: keyPath] = trimmed.isEmpty ? nil : Int(trimmed)
            }
        )
    }
}
