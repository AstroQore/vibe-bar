import SwiftUI
import VibeBarCore

/// Learning is a state of the regular quota row, not a separate provider UI.
struct QuotaLearningStatus: View {
    let bucket: QuotaBucket
    let fontSize: CGFloat
    var body: some View {
        Text(label).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(.secondary)
    }
    private var label: String {
        // A counted allowance whose history was not fully read is a partial
        // count, not a total still being learned; say which.
        if let quantity = bucket.quantity, !quantity.coverageComplete {
            guard let used = quantity.used else { return L10n.Quota.Chat.partial }
            return [L10n.Quota.Chat.used(count: used), L10n.Quota.Chat.partial].joined(separator: " · ")
        }
        return bucket.quantity?.remaining.map { L10n.Quota.Chat.learningRemaining(count: $0) }
            ?? L10n.Quota.Forecast.Confidence.learning
    }
}

struct LearningQuotaMiniCell: View {
    let bucket: QuotaBucket
    let title: String
    let now: Date
    var compact = false
    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: compact ? 8 : 10, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(bucket.quantity?.remaining.map { "≈" + AppLocale.number($0) } ?? "—")
                .font(.system(size: compact ? 13 : 16, weight: .semibold).monospacedDigit())
            QuotaBarShape(percent: 0, mode: .remaining, height: 6, indeterminate: true)
            Text(L10n.Quota.Forecast.Confidence.learning)
                .font(.system(size: compact ? 7 : 9)).foregroundStyle(.secondary)
            if let reset = ResetCountdownFormatter.string(from: bucket.resetAt, now: now) {
                Text(reset).font(.system(size: compact ? 7 : 9)).foregroundStyle(.tertiary)
            }
        }.padding(.vertical, compact ? 2 : 5)
    }
}

struct ChatGPTChatSettingsSection: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var environment: AppEnvironment
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ChatGPT Chat").font(.headline)
            Toggle(L10n.Quota.Chat.enable, isOn: $settingsStore.settings.chatGPTChat.enabled)
            Text(L10n.Quota.Chat.featuresHelp).font(.caption).foregroundStyle(.secondary)
            if settingsStore.settings.chatGPTChat.enabled {
                Text(L10n.Quota.Chat.allowanceLearningHelp).font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.Quota.Chat.historyToggle, isOn: $settingsStore.settings.chatGPTChat.trackProModels)
                Text(L10n.Quota.Chat.privacy).font(.caption).foregroundStyle(.secondary)
                if settingsStore.settings.chatGPTChat.trackProModels {
                    Text(L10n.Quota.Chat.rolling).font(.caption).foregroundStyle(.secondary)
                    if let history = environment.quota(for: .chatgptChat)?.chatGPTChat?.history {
                        Text(history.complete ? L10n.Quota.Chat.complete : L10n.Quota.Chat.partial)
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.Quota.Chat.excluded(work: history.excludedWorkConversations, unknown: history.unclassifiedTurns))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Button(L10n.Quota.Chat.refresh) { environment.refresh(.chatgptChat) }
            }
        }
    }
}

struct OpenAICombinedQuotaCard: View {
    let density: Theme.Density
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var environment: AppEnvironment

    var body: some View {
        CardShell(density: density) {
            HStack {
                ProviderSectionTitle(tool: .codex, title: "OpenAI", subtitle: nil,
                                     titleFontSize: density.titleFontSize, subtitleFontSize: density.subtitleFontSize,
                                     iconSize: 16, badgeSize: 24)
                Spacer()
                Button { for tool in ToolType.codex.coreProviderMembers { environment.refresh(tool) } }
                    label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L10n.Common.refresh)
            }
            if settingsStore.settings.chatGPTChat.enabled {
                subProviderHeader(.chatgptChat)
                ProviderQuotaCard(tool: .chatgptChat, density: density, embedded: true, suppressGroupTitles: true)
                Divider()
            }
            subProviderHeader(.codex)
            ProviderQuotaCard(tool: .codex, density: density, embedded: true)
        }
    }
    private func subProviderHeader(_ tool: ToolType) -> some View {
        HStack(spacing: 6) {
            ToolBrandIconView(tool: tool, size: 13)
            Text(tool.productName).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let label = settingsStore.settings.planBadgeLabel(for: tool,
                quotaPlan: environment.quota(for: tool)?.plan,
                accountPlan: environment.account(for: tool)?.plan) {
                PlanBadgeView(text: label, fontSize: max(9, density.subtitleFontSize - 1))
            }
        }
    }

}
