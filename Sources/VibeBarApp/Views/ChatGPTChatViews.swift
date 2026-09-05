import SwiftUI
import VibeBarCore

struct QuantityQuotaRow: View {
    let bucket: QuotaBucket
    let density: Theme.Density
    let now: Date

    var body: some View {
        if let quantity = bucket.quantity {
            VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text(bucket.title).font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(value(quantity))
                        .font(.system(size: density.bucketPercentFontSize, weight: .semibold).monospacedDigit())
                }
                if let percent = quantity.usedPercent {
                    QuotaBarShape(percent: 100 - percent, mode: .remaining, height: 8)
                }
                HStack {
                    Text(quantity.isEstimated ? L10n.Quota.Chat.estimated : L10n.Quota.Chat.reported)
                    Spacer(minLength: 4)
                    if let reset = ResetCountdownFormatter.stringWithAbsoluteTime(from: bucket.resetAt, now: now) {
                        Text(L10n.Quota.Reset.in(when: reset))
                    } else if let seconds = bucket.rawWindowSeconds, quantity.isEstimated {
                        Text(L10n.Quota.Chat.period(days: max(1, seconds / 86_400)))
                    }
                }
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                if quantity.isEstimated && !quantity.coverageComplete {
                    Text(L10n.Quota.Chat.partial).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func value(_ quantity: QuotaQuantity) -> String {
        if let remaining = quantity.remaining { return L10n.Quota.Chat.remaining(count: remaining) }
        if let used = quantity.used { return L10n.Quota.Chat.observed(count: used) }
        return L10n.Quota.Chat.unknown
    }
}

struct QuantityMiniCell: View {
    let bucket: QuotaBucket
    let title: String
    let now: Date
    var compact = false
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: compact ? 8 : 10, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.6)
            if let quantity = bucket.quantity {
                Text(quantity.value(settingsStore.displayMode).map { (quantity.isEstimated ? "≈" : "") + AppLocale.number($0) } ?? "—")
                    .font(.system(size: compact ? 13 : 16, weight: .semibold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(settingsStore.displayMode == .remaining ? L10n.Quota.Mode.remaining : L10n.Quota.Mode.used)
                    .font(.system(size: compact ? 7 : 9)).foregroundStyle(.secondary)
            }
            Text(ResetCountdownFormatter.string(from: bucket.resetAt, now: now) ?? "—")
                .font(.system(size: compact ? 7 : 9)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, compact ? 2 : 5)
    }
}

struct ChatGPTChatSettingsSection: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var environment: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ChatGPT Chat").font(.headline)
            Toggle(L10n.Quota.Chat.enable, isOn: $settingsStore.settings.chatGPTChat.enabled)
            Text(L10n.Quota.Chat.connectionHelp).font(.caption).foregroundStyle(.secondary)
            if settingsStore.settings.chatGPTChat.enabled {
                Toggle(L10n.Quota.Chat.historyToggle, isOn: $settingsStore.settings.chatGPTChat.includeHistory)
                Text(L10n.Quota.Chat.privacy).font(.caption).foregroundStyle(.secondary)
                if settingsStore.settings.chatGPTChat.includeHistory {
                    Text(L10n.Quota.Chat.manualLimits).font(.subheadline.weight(.semibold))
                    Text(L10n.Quota.Chat.limitsHelp).font(.caption).foregroundStyle(.secondary)
                    limit(L10n.Quota.Chat.astraLimit, value: $settingsStore.settings.chatGPTChat.astraWeeklyLimit)
                    limit(L10n.Quota.Chat.solLimit, value: $settingsStore.settings.chatGPTChat.solDailyLimit)
                    limit(L10n.Quota.Chat.sharedLimit, value: $settingsStore.settings.chatGPTChat.sharedDailyLimit)
                    reset(L10n.Quota.Chat.astraReset, value: $settingsStore.settings.chatGPTChat.astraResetsAt, seconds: 604_800)
                    reset(L10n.Quota.Chat.dailyReset, value: $settingsStore.settings.chatGPTChat.dailyResetsAt, seconds: 86_400)
                    Text(L10n.Quota.Chat.rolling).font(.caption).foregroundStyle(.secondary)
                }
                Button(L10n.Quota.Chat.refresh) { environment.refresh(.chatgptChat) }
                if let summary = environment.quota(for: .chatgptChat)?.chatGPTChat,
                   summary.historyQueriedAt != nil {
                    Text(summary.historyComplete ? L10n.Quota.Chat.complete : L10n.Quota.Chat.partial)
                        .font(.caption).foregroundStyle(summary.historyComplete ? Color.secondary : Color.orange)
                    Text(L10n.Quota.Chat.excluded(work: summary.excludedWorkConversations, unknown: summary.unclassifiedTurns))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func limit(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.grouping(.never))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 90)
        }
    }

    private func reset(_ title: String, value: Binding<Date?>, seconds: TimeInterval) -> some View {
        VStack(alignment: .leading) {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: {
                value.wrappedValue = $0 ? Date().addingTimeInterval(seconds) : nil
            }))
            if value.wrappedValue != nil {
                DatePicker(title, selection: Binding(get: { value.wrappedValue ?? Date() }, set: { value.wrappedValue = $0 }))
                    .labelsHidden()
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
            subProviderHeader(.codex)
            ProviderQuotaCard(tool: .codex, density: density, embedded: true)
            if settingsStore.settings.chatGPTChat.enabled {
                Divider()
                subProviderHeader(.chatgptChat)
                ProviderQuotaCard(tool: .chatgptChat, density: density, embedded: true, suppressGroupTitles: true)
            }
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
