import SwiftUI
import VibeBarCore

/// Per-misc-provider Settings row.
///
/// This is the skeleton landing in Phase 4 — every provider shows
/// its name, an enable toggle backed by `MiscProviderSettings`, and
/// a "Setup pending" placeholder. Each subsequent phase replaces
/// the placeholder with the real controls (API key field, paste
/// area, source-mode picker, etc.) for that provider's auth model.
struct MiscProviderSettingsSection: View {
    let tool: ToolType

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: tool.miscFallbackSymbol)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(tool.menuTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(tool.subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                sourceModePicker
            }
            placeholderRow
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    @ViewBuilder
    private var sourceModePicker: some View {
        Picker("", selection: sourceModeBinding) {
            ForEach(MiscProviderSettings.SourceMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 140)
    }

    @ViewBuilder
    private var placeholderRow: some View {
        // Every provider gets per-auth controls in a follow-up
        // phase; this row is a clear "not yet implemented" hint
        // so users can tell the slot is wired even before adapters
        // land.
        Text(setupHint)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private var setupHint: String {
        switch tool {
        case .alibaba:     return "API key + optional browser cookie fallback (coming soon)."
        case .gemini:      return "Reads ~/.gemini/oauth_creds.json (coming soon)."
        case .antigravity: return "Local language-server probe (coming soon)."
        case .copilot:     return "GitHub PAT (coming soon)."
        case .zai:         return "Z.ai API key (coming soon)."
        case .minimax:     return "Browser cookie auto-import (coming soon)."
        case .kimi:        return "Browser cookie auto-import (coming soon)."
        case .cursor:      return "Browser cookie auto-import (coming soon)."
        case .codex, .claude:
            return ""
        }
    }

    private var sourceModeBinding: Binding<MiscProviderSettings.SourceMode> {
        Binding(
            get: { settingsStore.settings.miscProvider(tool).sourceMode },
            set: { newValue in
                var current = settingsStore.settings.miscProvider(tool)
                current.sourceMode = newValue
                settingsStore.settings.setMiscProvider(current, for: tool)
            }
        )
    }
}
