import SwiftUI
import VibeBarCore

// MARK: - Welcome

struct OnboardingWelcomeStep: View {
    let density: Theme.Density

    var body: some View {
        // The language picker leads, before any prose the reader may not be
        // able to read yet. It is the same control the System settings
        // section mounts (`LanguageSettingsSection`), so a choice made here
        // is the choice that persists.
        LanguageSettingsSection(density: density)
        CardShell(density: density) {
            Text(L10n.Onboarding.welcomeIntro)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            OnboardingFeatureRow(
                systemImage: "gauge.with.dots.needle.33percent",
                title: L10n.Onboarding.welcomeQuotasTitle,
                detail: L10n.Onboarding.welcomeQuotasDetail
            )
            OnboardingFeatureRow(
                systemImage: "dollarsign.circle",
                title: L10n.Onboarding.welcomeCostTitle,
                detail: L10n.Onboarding.welcomeCostDetail
            )
            OnboardingFeatureRow(
                systemImage: "rectangle.stack",
                title: L10n.Onboarding.welcomeSessionsTitle,
                detail: L10n.Onboarding.welcomeSessionsDetail
            )
            OnboardingFeatureRow(
                systemImage: "point.3.connected.trianglepath.dotted",
                title: L10n.Onboarding.welcomeMcpTitle,
                detail: L10n.Onboarding.welcomeMcpDetail
            )
        }
        Text(L10n.Onboarding.welcomeFooter)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OnboardingFeatureRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WorkbenchPorcelain.accent)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Subscriptions

struct OnboardingSubscriptionsStep: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        Text(L10n.Onboarding.subscriptionsIntro)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(ToolType.coreProviderRepresentatives, id: \.self) { tool in
            OnboardingCoreProviderCard(tool: tool, density: density)
        }
    }
}

/// One core provider: the Overview switch, what credential is already on
/// this Mac, and the same import / login actions the provider's Settings
/// page offers.
private struct OnboardingCoreProviderCard: View {
    let tool: ToolType
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        CardShell(density: density) {
            HStack(spacing: 10) {
                ToolBrandBadge(tool: tool, iconSize: 20, containerSize: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.vendorName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(productLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle(L10n.Onboarding.subscriptionsShowInOverview, isOn: visibilityBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
            }
            credentialHint
            actions
            statusLines
        }
    }

    private var productLine: String {
        switch tool {
        case .codex: L10n.Onboarding.subscriptionsProductLineCodex
        case .claude: L10n.Onboarding.subscriptionsProductLineClaude
        case .gemini: L10n.Onboarding.subscriptionsProductLineGemini
        case .grok: L10n.Onboarding.subscriptionsProductLineGrok
        default: tool.subtitle
        }
    }

    private var visibilityBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.isCoreProviderVisible(tool) },
            set: { settingsStore.settings.setCoreProviderVisible($0, for: tool) }
        )
    }

    @ViewBuilder
    private var credentialHint: some View {
        switch tool {
        case .codex:
            cliHint(
                account: environment.account(for: .codex),
                detected: L10n.Onboarding.subscriptionsCodexDetected,
                web: L10n.Onboarding.subscriptionsCodexWeb,
                missing: L10n.Onboarding.subscriptionsCodexMissing
            )
        case .claude:
            cliHint(
                account: environment.account(for: .claude),
                detected: L10n.Onboarding.subscriptionsClaudeDetected,
                web: L10n.Onboarding.subscriptionsClaudeWeb,
                missing: L10n.Onboarding.subscriptionsClaudeMissing
            )
        case .gemini:
            hintLabel(
                L10n.Onboarding.subscriptionsGeminiHint,
                systemImage: "info.circle",
                tint: .secondary
            )
        case .grok:
            if GrokCredentialsStore.hasCredentials() {
                hintLabel(L10n.Onboarding.subscriptionsGrokDetected, systemImage: "checkmark.circle", tint: .green)
            } else {
                hintLabel(
                    L10n.Onboarding.subscriptionsGrokMissing,
                    systemImage: "exclamationmark.circle",
                    tint: .secondary
                )
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func cliHint(account: AccountIdentity?, detected: String, web: String, missing: String) -> some View {
        switch account?.source {
        case .cliDetected, .oauthCLI:
            hintLabel(detected, systemImage: "checkmark.circle", tint: .green)
        case .webCookie:
            hintLabel(web, systemImage: "checkmark.circle", tint: .green)
        case .some:
            hintLabel(detected, systemImage: "checkmark.circle", tint: .green)
        case .none:
            hintLabel(missing, systemImage: "exclamationmark.circle", tint: .secondary)
        }
    }

    private func hintLabel(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            switch tool {
            case .codex:
                Button {
                    environment.importOpenAIBrowserCookies()
                } label: {
                    Label(L10n.Onboarding.cookiesImportFromBrowser, systemImage: "safari")
                }
                .disabled(environment.isImportingOpenAIBrowserCookies)
                Button {
                    environment.openOpenAIWebLogin()
                } label: {
                    Label(L10n.Onboarding.cookiesOpenWebViewLogin, systemImage: "person.crop.circle.badge.key")
                }
            case .claude:
                Button {
                    environment.importClaudeBrowserCookies()
                } label: {
                    Label(L10n.Onboarding.cookiesImportFromBrowser, systemImage: "safari")
                }
                .disabled(environment.isImportingClaudeBrowserCookies)
                Button {
                    environment.openClaudeWebLogin()
                } label: {
                    Label(L10n.Onboarding.cookiesOpenWebViewLogin, systemImage: "person.crop.circle.badge.key")
                }
            case .gemini:
                Button {
                    environment.importGeminiBrowserCookies()
                } label: {
                    Label(L10n.Onboarding.cookiesImportGemini, systemImage: "safari")
                }
                .disabled(environment.isImportingGeminiBrowserCookies)
            case .grok:
                Button {
                    environment.importGrokBrowserCookies()
                } label: {
                    Label(L10n.Onboarding.cookiesImportGrok, systemImage: "safari")
                }
                .disabled(environment.isImportingGrokBrowserCookies)
            default:
                EmptyView()
            }
        }
    }

    /// Whether this provider's web cookies are in the Keychain, and the
    /// last import's status line, if any.
    private var cookieState: (saved: Bool, status: String?) {
        switch tool {
        case .codex:
            (environment.hasOpenAIWebCookies, environment.openAIBrowserCookieImportStatus)
        case .claude:
            (environment.hasClaudeWebCookies, environment.claudeBrowserCookieImportStatus)
        case .gemini:
            (environment.hasGeminiWebCookies, environment.geminiBrowserCookieImportStatus)
        case .grok:
            (environment.hasGrokWebCookies, environment.grokBrowserCookieImportStatus)
        default:
            (false, nil)
        }
    }

    @ViewBuilder
    private var statusLines: some View {
        let (saved, status) = cookieState
        if saved {
            Text(L10n.Onboarding.cookiesSaved)
                .font(.caption2)
                .foregroundStyle(.green)
        }
        if let status {
            Text(status)
                .font(.caption2)
                .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
        }
    }
}

// MARK: - Browser cookies

struct OnboardingBrowserCookiesStep: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment

    private var isImportingAny: Bool {
        environment.isImportingOpenAIBrowserCookies
            || environment.isImportingClaudeBrowserCookies
            || environment.isImportingGeminiBrowserCookies
            || environment.isImportingGrokBrowserCookies
    }

    var body: some View {
        CardShell(density: density) {
            Text(L10n.Onboarding.cookiesIntro)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                environment.importOpenAIBrowserCookies()
                environment.importClaudeBrowserCookies()
                environment.importGeminiBrowserCookies()
                environment.importGrokBrowserCookies()
            } label: {
                Label(isImportingAny ? "Importing…" : "Import from all browsers now", systemImage: "safari")
            }
            .disabled(isImportingAny)
            Divider()
            providerRow(
                .codex,
                importing: environment.isImportingOpenAIBrowserCookies,
                saved: environment.hasOpenAIWebCookies,
                status: environment.openAIBrowserCookieImportStatus
            )
            providerRow(
                .claude,
                importing: environment.isImportingClaudeBrowserCookies,
                saved: environment.hasClaudeWebCookies,
                status: environment.claudeBrowserCookieImportStatus
            )
            providerRow(
                .gemini,
                importing: environment.isImportingGeminiBrowserCookies,
                saved: environment.hasGeminiWebCookies,
                status: environment.geminiBrowserCookieImportStatus
            )
            providerRow(
                .grok,
                importing: environment.isImportingGrokBrowserCookies,
                saved: environment.hasGrokWebCookies,
                status: environment.grokBrowserCookieImportStatus
            )
        }
        Text(L10n.Onboarding.cookiesSignInFirst)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(L10n.Onboarding.cookiesBatchScope)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func providerRow(_ tool: ToolType, importing: Bool, saved: Bool, status: String?) -> some View {
        HStack(spacing: 10) {
            ToolBrandBadge(tool: tool, iconSize: 17, containerSize: 24)
            Text(tool.vendorName)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            statusText(importing: importing, saved: saved, status: status)
                .font(.caption2)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func statusText(importing: Bool, saved: Bool, status: String?) -> some View {
        if importing {
            Text(L10n.Onboarding.cookiesImporting)
                .foregroundStyle(.secondary)
        } else if let status {
            Text(status)
                .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
        } else if saved {
            Text(L10n.Onboarding.cookiesSaved)
                .foregroundStyle(.green)
        } else {
            Text(L10n.Onboarding.cookiesNotImported)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - API-key providers

struct OnboardingAPIKeyProvidersStep: View {
    let density: Theme.Density

    @EnvironmentObject private var settingsStore: SettingsStore
    /// Rows whose credential controls are unfolded. Kept apart from
    /// visibility so a page with every provider on (the default) does not
    /// open twenty credential forms at once.
    @State private var expanded: Set<String> = []

    var body: some View {
        Text(L10n.Onboarding.apiKeysIntro)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        CardShell(density: density, spacing: 0) {
            let instances = settingsStore.settings.miscProviderInstances
                .filter { $0.tool.isMiscPageProvider }
            ForEach(Array(instances.enumerated()), id: \.element.id) { index, instance in
                if index > 0 {
                    Divider()
                        .padding(.vertical, 6)
                }
                providerRow(instance)
            }
        }
    }

    private func providerRow(_ instance: MiscProviderInstance) -> some View {
        let visible = instance.isVisible
        let unfolded = visible && expanded.contains(instance.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: visibilityBinding(instance.id)) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(L10n.Onboarding.apiKeysShowOnMiscPage(provider: instance.tool.menuTitle))
                ToolBrandBadge(tool: instance.tool, iconSize: 17, containerSize: 24)
                    .opacity(visible ? 1 : 0.55)
                // `menuTitle` alone renders both Volcengine plans as
                // "Volcengine"; the subtitle beside it is what separates
                // Coding Plan from Agent Plan.
                Text(instance.displayTitle(fallback: instance.tool.menuTitle))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(visible ? Color.primary : Color.secondary)
                Text(instance.tool.subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Button {
                    if unfolded {
                        expanded.remove(instance.id)
                    } else {
                        expanded.insert(instance.id)
                    }
                } label: {
                    Label(unfolded ? "Hide" : "Set up", systemImage: unfolded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(WorkbenchPillButtonStyle())
                .controlSize(.small)
                .disabled(!visible)
                // The pill draws no disabled state of its own.
                .opacity(visible ? 1 : 0.4)
            }
            if unfolded {
                MiscProviderCredentialRows(instance: instance)
                    .padding(.leading, 32)
            }
        }
    }

    private func visibilityBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.miscProviderInstance(id: id)?.isVisible ?? false },
            set: { settingsStore.settings.setMiscProviderInstanceVisible($0, forID: id) }
        )
    }
}

// MARK: - Model pricing

struct OnboardingPricingStep: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        CardShell(density: density) {
            Text(L10n.Onboarding.pricingIntro(
                interval: intervalLabel(settingsStore.settings.pricingRefreshIntervalSeconds)
            ))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(action: environment.refreshPricingNow) {
                    Label(
                        environment.isRefreshingPricing
                            ? L10n.Onboarding.pricingFetching
                            : L10n.Onboarding.pricingFetchNow,
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(environment.isRefreshingPricing)
                if let date = environment.pricingRefreshStatus.mergedAt {
                    Text(L10n.Onboarding.pricingMerged(
                        when: date.formatted(date: .abbreviated, time: .shortened),
                        count: environment.pricingRefreshStatus.mergedModelCount
                    ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.Onboarding.pricingNotFetched)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(PricingSourceID.allCases, id: \.self) { source in
                sourceRow(source)
            }
        }
        Text(L10n.Onboarding.pricingFooter)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func sourceRow(_ source: PricingSourceID) -> some View {
        let status = environment.pricingRefreshStatus.sources.first { $0.source == source }
        return HStack(spacing: 10) {
            Circle()
                .fill(statusColor(status?.result ?? .never))
                .frame(width: 7, height: 7)
            Text(source.label)
                .font(.system(size: 13))
            Spacer()
            Text(sourceDetail(status))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func sourceDetail(_ status: PricingSourceStatus?) -> String {
        guard let status else { return L10n.Onboarding.pricingSourceNotRefreshed }
        switch status.result {
        case .ready: return L10n.Onboarding.pricingSourceModels(count: status.modelCount)
        case .unchanged: return L10n.Onboarding.pricingSourceUnchanged(count: status.modelCount)
        case .failed: return L10n.Onboarding.pricingSourceFailed(count: status.modelCount)
        case .never: return L10n.Onboarding.pricingSourceNotRefreshed
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
        return hours == 1
            ? L10n.Onboarding.pricingIntervalHour
            : L10n.Onboarding.pricingIntervalHours(hours: hours)
    }
}

// MARK: - Launch at login

struct OnboardingLaunchAtLoginStep: View {
    let density: Theme.Density

    @EnvironmentObject private var settingsStore: SettingsStore
    // A demo launch registers nothing with the system and must not read the
    // real login item either: the captured state is the settings file's.
    @State private var statusText: String = DemoMode.isEnabled
        ? L10n.Platform.macosLaunchAtLoginOff
        : LoginItemController.statusText
    @State private var errorText: String?

    var body: some View {
        CardShell(density: density) {
            Toggle(L10n.Platform.macosLaunchAtLoginToggle, isOn: binding)
                .toggleStyle(.switch)
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Divider()
            Text(L10n.Platform.macosLaunchAtLoginDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refreshState)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.launchAtLogin },
            set: { enabled in
                if DemoMode.isEnabled {
                    settingsStore.settings.launchAtLogin = enabled
                    statusText = enabled
                        ? L10n.Platform.macosLaunchAtLoginEnabled
                        : L10n.Platform.macosLaunchAtLoginOff
                    return
                }
                do {
                    try LoginItemController.reconcileDesiredState(enabled)
                    settingsStore.settings.launchAtLogin = enabled
                    errorText = nil
                } catch {
                    errorText = error.localizedDescription
                }
                refreshState()
            }
        )
    }

    private func refreshState() {
        guard !DemoMode.isEnabled else { return }
        switch LoginItemController.status {
        case .enabled, .requiresApproval:
            settingsStore.settings.launchAtLogin = true
        case .notRegistered:
            settingsStore.settings.launchAtLogin = false
        case .notFound:
            break
        @unknown default:
            break
        }
        statusText = LoginItemController.statusText
    }
}

// MARK: - Done

struct OnboardingDoneStep: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        CardShell(density: density) {
            Text(L10n.Onboarding.doneIntro)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            summaryRow(L10n.Onboarding.doneSubscriptions, value: visibleCoreProviders)
            summaryRow(
                L10n.Onboarding.doneBrowserCookies,
                value: L10n.Onboarding.doneCookieCount(saved: savedCookieCount, total: 4)
            )
            summaryRow(
                L10n.Onboarding.doneApiKeyProviders,
                value: L10n.Onboarding.doneMiscCount(count: visibleMiscCount)
            )
            summaryRow(L10n.Onboarding.doneModelPricing, value: pricingSummary)
            summaryRow(
                L10n.Onboarding.doneLaunchAtLogin,
                value: settingsStore.settings.launchAtLogin ? L10n.Common.on : L10n.Common.off
            )
        }
        Text(L10n.Onboarding.doneFooter)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 12)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var visibleCoreProviders: String {
        let names = ToolType.coreProviderRepresentatives
            .filter { settingsStore.settings.isCoreProviderVisible($0) }
            .map(\.vendorName)
        return names.isEmpty ? L10n.Onboarding.doneNoneShown : names.joined(separator: ", ")
    }

    private var savedCookieCount: Int {
        [
            environment.hasOpenAIWebCookies,
            environment.hasClaudeWebCookies,
            environment.hasGeminiWebCookies,
            environment.hasGrokWebCookies,
        ].filter { $0 }.count
    }

    private var visibleMiscCount: Int {
        settingsStore.settings.miscProviderInstances
            .filter { $0.tool.isMiscPageProvider && $0.isVisible }
            .count
    }

    private var pricingSummary: String {
        if let date = environment.pricingRefreshStatus.mergedAt {
            return L10n.Onboarding.donePricingMerged(when: date.formatted(date: .abbreviated, time: .shortened))
        }
        return L10n.Onboarding.donePricingBundled
    }
}
