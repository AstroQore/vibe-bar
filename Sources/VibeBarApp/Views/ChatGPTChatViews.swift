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
            Text(ToolType.chatGPTQuotaTitle).font(.headline)
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

/// Resolves the product heading and plan without changing which account any
/// quota row is read from. The Web feature source can use a separate login.
@MainActor
struct ChatGPTQuotaPresentation {
    let environment: AppEnvironment
    let settings: AppSettings

    var refreshTools: [ToolType] {
        ToolType.chatGPTQuotaSources(includeChat: settings.chatGPTChat.enabled)
    }

    var connectedTools: [ToolType] {
        refreshTools.filter { tool in
            guard let account = environment.account(for: tool) else { return false }
            return account.source != .notConfigured
        }
    }

    func planBadge(for tool: ToolType) -> String? {
        settings.planBadgeLabel(for: tool, quotaPlan: environment.quota(for: tool)?.plan,
                                accountPlan: environment.account(for: tool)?.plan)
    }

    var commonPlanBadge: String? {
        ProviderPlanDisplay.chatGPTQuotaBadge(sources: connectedTools.map { tool in
            (plan: environment.quota(for: tool)?.plan ?? environment.account(for: tool)?.plan,
             label: planBadge(for: tool))
        })
    }

    static func sourceLabel(for tool: ToolType) -> String {
        tool == .chatgptChat ? "chatgpt.com" : ToolType.codex.toolName
    }
}

extension ToolType {
    /// Native quota labels group both OpenAI sources under the product name.
    /// The source name and ID used by caches and clients remain unchanged.
    func nativeQuotaProductName(bucketID: String? = nil) -> String {
        isChatGPTQuotaSource ? Self.chatGPTQuotaTitle : quotaSubProviderName(bucketID: bucketID)
    }
}

/// OpenAI's settings offer both the web sign-in and the Codex connection.
struct ChatGPTQuotaSetupRow: View {
    let density: Theme.Density
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
            Text(L10n.Error.noAccountFound)
                .foregroundStyle(.secondary)
            Button(L10n.Common.openSettings) {
                environment.showSettings(.coreProvider(.codex))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.system(size: density.subtitleFontSize))
    }
}

struct OpenAICombinedQuotaCard: View {
    let density: Theme.Density
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var quotaService: QuotaService

    var body: some View {
        let presentation = ChatGPTQuotaPresentation(environment: environment, settings: settingsStore.settings)
        let tools = presentation.connectedTools
        let commonBadge = presentation.commonPlanBadge
        let isRefreshing = presentation.refreshTools.contains { tool in
            environment.account(for: tool).map { quotaService.inFlightAccountIds.contains($0.id) } ?? false
        }
        CardShell(density: density) {
            HStack(spacing: 8) {
                ProviderSectionTitle(tool: .codex, title: ToolType.codex.vendorName, subtitle: nil,
                                     titleFontSize: density.titleFontSize, subtitleFontSize: density.subtitleFontSize,
                                     iconSize: 16, badgeSize: 24)
                Spacer(minLength: 4)
                SectionRefreshButton(isRefreshing: isRefreshing) {
                    environment.refresh(tools: presentation.refreshTools)
                }
            }
            HStack(spacing: 6) {
                ToolBrandIconView(tool: .codex, size: 13)
                Text(ToolType.chatGPTQuotaTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let commonBadge {
                    PlanBadgeView(text: commonBadge, fontSize: max(9, density.subtitleFontSize - 1))
                }
            }
            if tools.isEmpty {
                if settingsStore.settings.chatGPTChat.enabled {
                    ChatGPTQuotaSetupRow(density: density)
                } else {
                    ProviderQuotaCard(tool: .codex, density: density, embedded: true)
                }
            }
            VStack(alignment: .leading, spacing: density.bucketGroupSpacing) {
                ForEach(tools, id: \.self) { tool in
                    if tool != tools.first {
                        Divider()
                            .opacity(0.18)
                            .padding(.vertical, 1)
                    }
                    let sourceLabel = ChatGPTQuotaPresentation.sourceLabel(for: tool)
                    if tools.count > 1, commonBadge == nil, let plan = presentation.planBadge(for: tool) {
                        HStack(spacing: 6) {
                            Text(sourceLabel)
                                .font(.system(size: density.subtitleFontSize, weight: .semibold))
                                .foregroundStyle(.secondary)
                            PlanBadgeView(text: plan, fontSize: max(9, density.subtitleFontSize - 1))
                        }
                    }
                    ProviderQuotaCard(tool: tool, density: density, embedded: true,
                                      statusSource: tools.count > 1 ? sourceLabel : nil)
                }
            }
        }
    }
}
