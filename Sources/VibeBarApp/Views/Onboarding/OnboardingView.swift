import SwiftUI
import VibeBarCore

/// The setup assistant's steps, in order. Raw values double as the
/// `onboarding:<step>` identifiers demo mode accepts.
enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome
    case subscriptions
    case browserCookies
    case apiKeyProviders
    case pricing
    case launchAtLogin
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .subscriptions: "Subscriptions"
        case .browserCookies: "Browser cookies"
        case .apiKeyProviders: "Other plans"
        case .pricing: "Model pricing"
        case .launchAtLogin: "Launch at login"
        case .done: "All set"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "What Vibe Bar does, in one paragraph."
        case .subscriptions: "Turn on the plans you pay for."
        case .browserCookies: "Web quotas come from the session your browser already has."
        case .apiKeyProviders: "Plans tracked with an API key or a console cookie."
        case .pricing: "Where the token prices behind the cost numbers come from."
        case .launchAtLogin: "Keep the readout in your menu bar from the moment you sign in."
        case .done: "Everything here lives in Settings too."
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "hand.wave"
        case .subscriptions: "creditcard"
        case .browserCookies: "safari"
        case .apiKeyProviders: "key"
        case .pricing: "dollarsign.circle"
        case .launchAtLogin: "power"
        case .done: "checkmark.circle"
        }
    }

    var previous: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > all.startIndex else { return nil }
        return all[index - 1]
    }

    var next: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.endIndex else { return nil }
        return all[index + 1]
    }
}

/// The first-run setup assistant: a step list on the left, one step's
/// controls on the right, Back / Skip / Continue underneath.
///
/// Every control here is the same control Settings shows — the visibility
/// switches, the cookie importers, the credential fields, the pricing
/// refresh, the login item — bound to the same stores. The assistant adds
/// order and explanation, never a second copy of state.
struct OnboardingView: View {
    @ObservedObject var navigation: OnboardingNavigation

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    private static let stepListWidth: CGFloat = 212
    /// Distance from the window's top edge to the first line of either pane.
    static let titleBarInset: CGFloat = 44

    var body: some View {
        let density = Theme.density(for: settingsStore.settings.popoverDensity)
        HStack(spacing: 0) {
            OnboardingStepList(current: $navigation.step)
                .frame(width: Self.stepListWidth)
            Rectangle()
                .fill(WorkbenchPorcelain.hairline(for: colorScheme))
                .frame(width: 1)
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: density.interSectionSpacing) {
                        header
                        stepContent(density: density)
                    }
                    .padding(.horizontal, 28)
                    // Clears the traffic lights in the transparent title
                    // bar; the step list carries the same inset.
                    .padding(.top, Self.titleBarInset)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                // The step pane is native toggles and fields: their system
                // focus ring is what tells a keyboard user where they are.
                .vibeBarSystemControlFocus()
                Rectangle()
                    .fill(WorkbenchPorcelain.hairline(for: colorScheme))
                    .frame(height: 1)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: OnboardingWindowController.contentSize.width,
            minHeight: OnboardingWindowController.contentSize.height
        )
        // The window's title bar is transparent and full-size; the panes own
        // the whole height so the hairline between them runs edge to edge,
        // and each one insets its content past the traffic lights itself.
        .ignoresSafeArea(.container, edges: .top)
        .background(WorkbenchPorcelain.windowFill(for: colorScheme))
        .workbenchPorcelain()
        .vibeBarControlFocus()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(navigation.step.title)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.35)
            Text(navigation.step.subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func stepContent(density: Theme.Density) -> some View {
        switch navigation.step {
        case .welcome:
            OnboardingWelcomeStep(density: density)
        case .subscriptions:
            OnboardingSubscriptionsStep(density: density)
        case .browserCookies:
            OnboardingBrowserCookiesStep(density: density)
        case .apiKeyProviders:
            OnboardingAPIKeyProvidersStep(density: density)
        case .pricing:
            OnboardingPricingStep(density: density)
        case .launchAtLogin:
            OnboardingLaunchAtLoginStep(density: density)
        case .done:
            OnboardingDoneStep(density: density)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Back") {
                if let previous = navigation.step.previous {
                    navigation.step = previous
                }
            }
            .buttonStyle(WorkbenchPillButtonStyle())
            .disabled(navigation.step.previous == nil)

            Spacer(minLength: 12)

            if navigation.step != .done {
                Button("Skip for now") {
                    environment.finishOnboarding(openPopover: false)
                }
                .buttonStyle(WorkbenchPillButtonStyle())
            }

            if let next = navigation.step.next {
                Button("Continue") {
                    navigation.step = next
                }
                .buttonStyle(WorkbenchPillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Finish") {
                    environment.finishOnboarding(openPopover: true)
                }
                .buttonStyle(WorkbenchPillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

/// The rail of steps. A step behind the current one shows a check; any step
/// can be jumped to — the order is a suggestion, not a gate.
private struct OnboardingStepList: View {
    @Binding var current: OnboardingStep

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered: OnboardingStep?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Setup")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            ForEach(OnboardingStep.allCases) { step in
                row(step)
            }
            Spacer(minLength: 0)
            Text(versionLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 10)
        .padding(.top, OnboardingView.titleBarInset)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkbenchPorcelain.sidebarFill(for: colorScheme))
    }

    private func row(_ step: OnboardingStep) -> some View {
        let selected = current == step
        let completed = isCompleted(step)
        return Button {
            current = step
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(
                            selected
                                ? WorkbenchPorcelain.accent.opacity(0.16)
                                : (completed ? Color.green.opacity(0.14) : WorkbenchPorcelain.hoverFill(for: colorScheme))
                        )
                    Image(systemName: completed && !selected ? "checkmark" : step.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            selected
                                ? WorkbenchPorcelain.accent
                                : (completed ? Color.green : Color.secondary)
                        )
                }
                .frame(width: 22, height: 22)
                Text(step.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.78))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        selected
                            ? WorkbenchPorcelain.selectedNavigationFill(for: colorScheme)
                            : (hovered == step ? WorkbenchPorcelain.hoverFill(for: colorScheme) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        selected ? WorkbenchPorcelain.hairline(for: colorScheme) : Color.clear,
                        lineWidth: Theme.Card.hairlineWidth
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.vibeBar(cornerRadius: 9))
        .onHover { hovering in
            hovered = hovering ? step : (hovered == step ? nil : hovered)
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func isCompleted(_ step: OnboardingStep) -> Bool {
        let all = OnboardingStep.allCases
        guard let index = all.firstIndex(of: step), let currentIndex = all.firstIndex(of: current) else {
            return false
        }
        return index < currentIndex
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Vibe Bar · " + (version ?? "Setup")
    }
}
