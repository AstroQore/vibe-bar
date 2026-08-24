import SwiftUI
import VibeBarCore

/// Providers already configured in CodexBar but not native to Vibe Bar yet.
/// The bridge is deliberately labelled and read-only: overlapping providers
/// stay on Vibe Bar's own adapters, and credentials never cross this boundary.
struct CodexBarProviderBridgeCard: View {
    let density: Theme.Density

    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var snapshot: CodexBarProviderBridge.Snapshot?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        MiscProviderCardShell(density: density) {
            header
            Divider().opacity(0.25)
            bodyContent
        }
        .task { await refresh() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))
                .overlay(Circle().stroke(Color.accentColor.opacity(0.35), lineWidth: 0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text("CodexBar Bridge")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Text(snapshot?.version.map { "CodexBar \($0) · read-only" } ?? "Additional providers · read-only")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            BorderlessIconButton(
                systemImage: "arrow.clockwise",
                help: "Refresh CodexBar providers",
                size: density.subtitleFontSize
            ) {
                Task { await refresh() }
            }
            .disabled(isLoading)
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if isLoading, snapshot == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else if let providers = snapshot?.providers, !providers.isEmpty {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(providers) { provider in
                        providerSection(provider)
                    }
                }
            }
            .frame(maxHeight: 300)
        } else if let error {
            Text(error)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
        } else {
            Text("No enabled CodexBar-only provider returned a quota window. Overlapping providers remain on Vibe Bar's native cards.")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
        }
    }

    private func providerSection(_ provider: CodexBarProviderBridge.Provider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(provider.name)
                    .font(.system(size: density.subtitleFontSize, weight: .semibold))
                Text(provider.id)
                    .font(.system(size: max(8, density.resetCountdownFontSize - 1), design: .rounded))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Text(provider.source)
                    .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                    .foregroundStyle(.tertiary)
            }
            ForEach(provider.windows) { window in
                windowRow(window)
            }
        }
    }

    private func windowRow(_ window: CodexBarProviderBridge.Window) -> some View {
        let mode = settingsStore.settings.displayMode
        let percent = mode == .used ? window.usedPercent : 100 - window.usedPercent
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: max(9, density.subtitleFontSize - 1)))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: density.subtitleFontSize, weight: .semibold,
                                  design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.barColor(percent: percent, mode: mode))
            }
            QuotaBarShape(
                percent: percent,
                mode: mode,
                height: max(3, density.bucketBarHeight - 1)
            )
            if let countdown = ResetCountdownFormatter.stringWithAbsoluteTime(from: window.resetAt) {
                Text("Resets \(countdown)")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @MainActor
    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            snapshot = try await CodexBarProviderBridge.shared.fetch()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
