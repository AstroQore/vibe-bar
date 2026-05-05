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
        case .noAccount: return "No account found"
        case .needsLogin: return "Needs re-login"
        case .network: return "Network error"
        case .parseChanged: return "Response format changed"
        case .rateLimited: return "Rate limited"
        }
    }
    private var detail: String {
        switch kind {
        case .noAccount:
            return "Log in with the official CLI on this Mac, then refresh."
        case .needsLogin(let t):
            return "Run `\(t == .codex ? "codex" : "claude") login` in your terminal, then refresh."
        case .network:
            return "Couldn't reach the official API. Check your internet connection and try again."
        case .parseChanged:
            return "The official API returned an unexpected shape. Try refreshing or update Vibe Bar."
        case .rateLimited:
            return "The official API is asking us to wait. Try again in a moment."
        }
    }
    private var primaryTitle: String {
        switch kind {
        case .noAccount: return "Refresh"
        case .needsLogin: return "Refresh"
        case .network, .rateLimited: return "Retry"
        case .parseChanged: return "Refresh"
        }
    }
    private var secondaryTitle: String {
        switch kind {
        case .noAccount: return "Open Settings"
        default: return "Open Settings"
        }
    }
}
