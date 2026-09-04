import SwiftUI
import VibeBarCore

enum EmptyKind: Equatable {
    case noAccount
    case needsLogin(ToolType)
    case network
    case parseChanged
    case rateLimited
}

struct EmptyStateView: View {
    let kind: EmptyKind
    var onPrimaryAction: (() -> Void)?
    var onSecondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                if let onPrimaryAction {
                    Button(primaryTitle) { onPrimaryAction() }
                        .buttonStyle(.borderedProminent)
                }
                if let onSecondaryAction {
                    Button(secondaryTitle) { onSecondaryAction() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }

    private var iconName: String {
        switch kind {
        case .noAccount: return "person.crop.circle.badge.questionmark"
        case .needsLogin: return "key.slash"
        case .network: return "wifi.exclamationmark"
        case .parseChanged: return "exclamationmark.triangle"
        case .rateLimited: return "hourglass"
        }
    }
    private var headline: String {
        switch kind {
        case .noAccount: return L10n.Error.noAccountFound
        case .needsLogin: return L10n.Error.needsReLogin
        case .network: return L10n.Error.network
        case .parseChanged: return L10n.Error.parseFailure
        case .rateLimited: return L10n.Quota.Empty.RateLimited.headline
        }
    }
    private var detail: String {
        switch kind {
        case .noAccount:
            return L10n.Quota.Empty.NoAccount.detail
        case .needsLogin(let t):
            // The CLI's name is the command the user types. It is not copy.
            return L10n.Quota.Empty.NeedsLogin.detail(command: t == .codex ? "codex" : "claude")
        case .network:
            return L10n.Quota.Empty.Network.detail
        case .parseChanged:
            return L10n.Quota.Empty.ParseChanged.detail
        case .rateLimited:
            return L10n.Quota.Empty.RateLimited.detail
        }
    }
    private var primaryTitle: String {
        switch kind {
        case .noAccount, .needsLogin, .parseChanged: return L10n.Common.refresh
        case .network, .rateLimited: return L10n.Common.retry
        }
    }
    private var secondaryTitle: String {
        L10n.Common.openSettings
    }
}
