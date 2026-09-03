import AppKit
import SwiftUI
import VibeBarCore

extension SkillAppTarget {
    /// The provider this agent CLI shares a brand mark with, when there is
    /// one. Every visible managed harness has a real provider asset, so the
    /// toggle row never falls back to an empty or unrelated glyph.
    var brandTool: ToolType? { ToolType(rawValue: rawValue) }

    var fallbackSystemImage: String {
        switch self {
        case .hermes: return "cross.case"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .claude, .codex, .gemini, .grok, .antigravity, .cursor:
            return "puzzlepiece.extension"
        }
    }

    var accent: Color {
        brandTool.map(Theme.providerAccent(for:)) ?? .accentColor
    }
}

/// One agent CLI's mark at a given size — brand icon where the app has one,
/// SF Symbol where it does not.
struct SkillAppGlyph: View {
    let app: SkillAppTarget
    var size: CGFloat = 13

    var body: some View {
        if let tool = app.brandTool {
            ToolBrandIconView(tool: tool, size: size)
        } else if app == .hermes, let image = hermesImage {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: app.fallbackSystemImage)
                .font(.system(size: size * 0.92, weight: .semibold))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    /// Official Hermes mark from NousResearch's hermes-agent site:
    /// https://github.com/NousResearch/hermes-agent/blob/main/website/static/img/favicon.svg
    private var hermesImage: NSImage? {
        let filename = "ProviderIcon-hermes.svg"
        let bundled = Bundle.main.url(
            forResource: "ProviderIcon-hermes",
            withExtension: "svg",
            subdirectory: "ProviderIcons"
        )
        let local = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ProviderIcons/\(filename)")
        guard let url = bundled ?? (FileManager.default.fileExists(atPath: local.path) ? local : nil),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}

/// One circular brand button per locally manageable core harness.
///
/// Used both as a live control (an installed skill's enable bits) and as a
/// selection (which apps a pending install should be enabled for) — the two
/// read identically on purpose, because they mean the same thing.
struct SkillAppToggleRow: View {
    let state: (SkillAppTarget) -> SkillActivationState
    let isProjected: (SkillAppTarget) -> Bool
    let action: (SkillAppTarget, SkillActivationAction) -> Void
    let showsNativeActions: Bool
    var diameter: CGFloat
    var glyphSize: CGFloat
    var spacing: CGFloat
    /// A whole-sentence tooltip for the selection form, where a circle means
    /// "install into" rather than "currently on". A closure rather than a
    /// suffix: a translated sentence cannot be assembled by appending a noun
    /// phrase to an English frame.
    var helpOverride: ((SkillAppTarget) -> String)?

    @State private var hoveredApp: SkillAppTarget?

    /// Selection-only form used before installation. It remains a binary
    /// choice and does not offer native runtime actions.
    init(
        isOn: @escaping (SkillAppTarget) -> Bool,
        toggle: @escaping (SkillAppTarget) -> Void,
        diameter: CGFloat = 25,
        glyphSize: CGFloat = 13,
        spacing: CGFloat = 4,
        helpOverride: ((SkillAppTarget) -> String)? = nil
    ) {
        self.state = { isOn($0) ? .enabled : .notProjected }
        self.isProjected = isOn
        self.action = { app, _ in toggle(app) }
        self.showsNativeActions = false
        self.diameter = diameter
        self.glyphSize = glyphSize
        self.spacing = spacing
        self.helpOverride = helpOverride
    }

    /// Installed-skill form. It exposes projection and native harness state
    /// as separate choices.
    init(
        state: @escaping (SkillAppTarget) -> SkillActivationState,
        isProjected: @escaping (SkillAppTarget) -> Bool,
        action: @escaping (SkillAppTarget, SkillActivationAction) -> Void,
        diameter: CGFloat = 25,
        glyphSize: CGFloat = 13,
        spacing: CGFloat = 4,
        helpOverride: ((SkillAppTarget) -> String)? = nil
    ) {
        self.state = state
        self.isProjected = isProjected
        self.action = action
        self.showsNativeActions = true
        self.diameter = diameter
        self.glyphSize = glyphSize
        self.spacing = spacing
        self.helpOverride = helpOverride
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(SkillAppTarget.managedHarnesses, id: \.self) { app in
                button(for: app)
            }
        }
    }

    private func button(for app: SkillAppTarget) -> some View {
        let activation = state(app)
        let on = activation == .enabled
        let accent = app.accent
        return Button {
            action(app, defaultAction(for: app, state: activation))
        } label: {
            SkillAppGlyph(app: app, size: glyphSize)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(accent.opacity(on ? 0.18 : hoveredApp == app ? 0.10 : 0.05))
                )
                .overlay(
                    Circle().stroke(accent.opacity(on ? 0.6 : hoveredApp == app ? 0.42 : 0.20), lineWidth: 0.8)
                )
                .overlay(alignment: .topTrailing) {
                    stateBadge(activation)
                        .offset(x: 2, y: -2)
                }
        }
        .buttonStyle(.vibeBar)
        // An off app has to stay readable — the user is picking from these —
        // but must not wear the accent, which is the only signal that says
        // "this skill is live here".
        .opacity(on ? 1 : activation == .notProjected ? 0.62 : 0.82)
        .saturation(on ? 1 : activation == .notProjected ? 0.45 : 0.65)
        .onHover { hovering in hoveredApp = hovering ? app : nil }
        .help(helpText(app: app, state: activation))
        .contextMenu {
            if showsNativeActions {
                Button(L10n.Workbench.skillsContextEnableIn(app: app.displayName)) {
                    action(app, .enable)
                }
                if app.supportsNativeSkillActivation {
                    Button(
                        L10n.Workbench.skillsContextDisableKeepProjection(app: app.displayName)
                    ) {
                        action(app, .disableInHarness)
                    }
                }
                Divider()
                Button(L10n.Workbench.skillsContextRemoveProjection(app: app.displayName)) {
                    action(app, .removeProjection)
                }
                .disabled(!isProjected(app))
            }
        }
        .accessibilityLabel(app.displayName)
        .accessibilityValue(accessibilityValue(activation))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func defaultAction(
        for app: SkillAppTarget,
        state: SkillActivationState
    ) -> SkillActivationAction {
        switch state {
        case .notProjected: return .enable
        case .enabled:
            if app.supportsNativeSkillActivation && showsNativeActions {
                return .disableInHarness
            }
            // A shared-root harness's projection is redundant — deleting it
            // from a plain click would look like an off switch that doesn't
            // work (the skill stays discovered). Route the click to the
            // explanatory no-op and keep removal in the context menu.
            return app.discoversSharedSkillRoot ? .enable : .removeProjection
        case .coupled:
            return app.supportsNativeSkillActivation && showsNativeActions
                ? .disableInHarness
                : .enable
        case .disabledInHarness, .unknown: return .enable
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: SkillActivationState) -> some View {
        switch state {
        case .disabledInHarness:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.orange)
                .background(Circle().fill(.background))
        case .unknown:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.orange)
                .background(Circle().fill(.background))
        case .coupled:
            // Informational, not a warning: the skill *is* available — the
            // harness reads a root Vibe Bar doesn't gate. Orange is reserved
            // for the two states that actually need attention.
            Image(systemName: "link.circle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .background(Circle().fill(.background))
        case .enabled, .notProjected:
            EmptyView()
        }
    }

    private func accessibilityValue(_ state: SkillActivationState) -> String {
        switch state {
        case .notProjected: L10n.Workbench.skillsStateNotProjected
        case .enabled: L10n.Workbench.skillsStateEnabled
        case .disabledInHarness: L10n.Workbench.skillsStateDisabledInHarness
        case .coupled: L10n.Workbench.skillsStateCoupled
        case .unknown: L10n.Workbench.skillsStateUnknown
        }
    }

    private func helpText(app: SkillAppTarget, state: SkillActivationState) -> String {
        if let helpOverride { return helpOverride(app) }
        let name = app.displayName
        switch state {
        case .notProjected:
            return L10n.Workbench.skillsToggleStateNotProjected(app: name)
        case .enabled where app.supportsNativeSkillActivation:
            return L10n.Workbench.skillsToggleStateEnabledNative(app: name)
        case .enabled where app.discoversSharedSkillRoot:
            return L10n.Workbench.skillsToggleStateEnabledSharedRoot(app: name)
        case .enabled:
            return L10n.Workbench.skillsToggleStateEnabled(app: name)
        case .disabledInHarness:
            return L10n.Workbench.skillsToggleStateDisabledInHarness(app: name)
        case .coupled where app.discoversSharedSkillRoot:
            return L10n.Workbench.skillsToggleStateCoupledSharedRoot(app: name)
        case .coupled:
            return L10n.Workbench.skillsToggleStateCoupledGemini(app: name)
        case .unknown:
            return L10n.Workbench.skillsToggleStateUnknown(app: name)
        }
    }
}

/// One installed skill: what it is, where it came from, and which agent CLIs
/// currently see it.
struct SkillListRow: View {
    let density: Theme.Density
    let skill: Skill
    let updateState: SkillUpdateState?
    let isBusy: Bool
    let onSetActivation: (SkillAppTarget, SkillActivationAction) -> Void
    let onUpdate: () -> Void
    let onUninstall: () -> Void

    @State private var confirmingUninstall = false
    @State private var isHovering = false
    @State private var showingWiring = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            details
            Spacer(minLength: 8)
            SkillAppToggleRow(
                state: { skill.activationState(for: $0) },
                isProjected: { skill.isProjected(for: $0) },
                action: onSetActivation,
                helpOverride: nil
            )
            .disabled(isBusy)
            overflowMenu
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 11)
        .opacity(isBusy ? 0.55 : 1)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.045) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isHovering ? Color.primary.opacity(0.12) : Color.clear,
                    lineWidth: 0.7
                )
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
                .padding(.horizontal, 2)
        }
        .overlay(alignment: .trailing) {
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .confirmationDialog(
            L10n.Workbench.skillsUninstallConfirmTitle(skill: skill.name),
            isPresented: $confirmingUninstall,
            titleVisibility: .visible
        ) {
            Button(L10n.Workbench.skillsUninstall, role: .destructive) { onUninstall() }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Workbench.skillsUninstallConfirmMessage)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(skill.name)
                    .font(.system(size: max(12, density.bucketTitleFontSize), weight: .semibold))
                    .lineLimit(1)
                sourceBadge
                nativeStateBadge
                if updateState?.updateAvailable == true {
                    updateBadge
                }
            }
            if let description = skill.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: max(10, density.subtitleFontSize)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var nativeStateBadge: some View {
        let disabled = SkillAppTarget.managedHarnesses.filter {
            skill.activationState(for: $0) == .disabledInHarness
        }
        let unknown = SkillAppTarget.managedHarnesses.filter {
            skill.activationState(for: $0) == .unknown
        }
        if !disabled.isEmpty {
            let names = disabled
                .map { L10n.Workbench.skillsBadgeNativeOff(app: $0.displayName) }
                .joined(separator: " · ")
            Text(names)
                .font(.system(size: max(9, density.resetCountdownFontSize - 2), weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
                .help(L10n.Workbench.skillsBadgeNativeOffHelp)
        } else if !unknown.isEmpty {
            Text(L10n.Workbench.skillsBadgeNativeUnknown)
                .font(.system(size: max(9, density.resetCountdownFontSize - 2), weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
                .help(L10n.Workbench.skillsBadgeNativeUnknownHelp)
        }
        // `.coupled` deliberately gets no row capsule: it is the *normal*
        // state for every skill Cursor sees, and a permanent orange
        // "Cursor LINKED" on nearly every row read as a problem needing a
        // click that then did nothing. The circle's small link badge and the
        // wiring popover carry the information instead.
    }

    private var sourceBadge: some View {
        Text(skill.id.repositorySlug ?? L10n.Workbench.skillsSourceLocal)
            .font(.system(size: max(10, density.resetCountdownFontSize - 1), design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
            )
            .help(
                skill.repoBranch.map { L10n.Workbench.skillsSourceBranch(branch: $0) }
                    ?? L10n.Workbench.skillsSourceInstalledLocally
            )
    }

    private var updateBadge: some View {
        Text(L10n.Workbench.skillsBadgeUpdate)
            .font(.system(size: max(10, density.resetCountdownFontSize - 2), weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.45), lineWidth: 0.7))
    }

    private var overflowMenu: some View {
        Menu {
            Button(
                L10n.Workbench.skillsMenuWiringDetails,
                systemImage: "point.3.connected.trianglepath.dotted"
            ) {
                showingWiring = true
            }
            Button(L10n.Workbench.skillsMenuRevealInFinder, systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    SkillAppCatalog.ssotDirectory()
                        .appendingPathComponent(skill.directory, isDirectory: true)
                ])
            }
            Divider()
            Button(
                L10n.Workbench.skillsMenuUpdateFromRepository,
                systemImage: "arrow.down.circle"
            ) { onUpdate() }
                .disabled(!skill.id.isRepositoryBacked)
            Divider()
            Button(L10n.Workbench.skillsMenuUninstall, systemImage: "trash", role: .destructive) {
                confirmingUninstall = true
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: max(10, density.subtitleFontSize), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isBusy)
        .accessibilityLabel(L10n.Workbench.skillsMenuMoreActions(skill: skill.name))
        .popover(isPresented: $showingWiring, arrowEdge: .trailing) {
            SkillWiringPopover(skill: skill, density: density)
                .vibeBarNoInitialFocus()
        }
    }
}
