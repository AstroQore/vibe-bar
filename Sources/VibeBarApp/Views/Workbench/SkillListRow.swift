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
        case .claude, .codex, .gemini, .grok, .antigravity, .cursor, .muse, .mistralVibe:
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

/// The circle every harness switch draws — Skills' enable bits and the
/// Library's share toggles — so "lit in this harness's accent" means the
/// same thing on every page. The caller owns the button, the dimming and the
/// badge; this owns only the shape.
struct HarnessToggleCircle<Badge: View>: View {
    let app: SkillAppTarget
    let isOn: Bool
    let isHovered: Bool
    var diameter: CGFloat = 25
    var glyphSize: CGFloat = 13
    @ViewBuilder var badge: Badge

    var body: some View {
        let accent = app.accent
        SkillAppGlyph(app: app, size: glyphSize)
            .frame(width: diameter, height: diameter)
            .background(
                Circle().fill(accent.opacity(isOn ? 0.18 : isHovered ? 0.10 : 0.05))
            )
            .overlay(
                Circle().stroke(accent.opacity(isOn ? 0.6 : isHovered ? 0.42 : 0.20), lineWidth: 0.8)
            )
            .overlay(alignment: .topTrailing) {
                badge.offset(x: 2, y: -2)
            }
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
        return Button {
            action(app, defaultAction(for: app, state: activation))
        } label: {
            HarnessToggleCircle(
                app: app,
                isOn: on,
                isHovered: hoveredApp == app,
                diameter: diameter,
                glyphSize: glyphSize
            ) {
                stateBadge(activation)
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
                Button(L10n.Workbench.Skills.contextEnableIn(app: app.displayName)) {
                    action(app, .enable)
                }
                if app.supportsNativeSkillActivation {
                    Button(
                        L10n.Workbench.Skills.contextDisableKeepProjection(app: app.displayName)
                    ) {
                        action(app, .disableInHarness)
                    }
                }
                Divider()
                Button(L10n.Workbench.Skills.contextRemoveProjection(app: app.displayName)) {
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
        case .notProjected: L10n.Workbench.Skills.State.notProjected
        case .enabled: L10n.Workbench.Skills.State.enabled
        case .disabledInHarness: L10n.Workbench.Skills.State.disabledInHarness
        case .coupled: L10n.Workbench.Skills.State.coupled
        case .unknown: L10n.Workbench.Skills.State.unknown
        }
    }

    private func helpText(app: SkillAppTarget, state: SkillActivationState) -> String {
        if let helpOverride { return helpOverride(app) }
        let name = app.displayName
        switch state {
        case .notProjected:
            return L10n.Workbench.Skills.ToggleState.notProjected(app: name)
        case .enabled where app.supportsNativeSkillActivation:
            return L10n.Workbench.Skills.ToggleState.enabledNative(app: name)
        case .enabled where app.discoversSharedSkillRoot:
            return L10n.Workbench.Skills.ToggleState.enabledSharedRoot(app: name)
        case .enabled:
            return L10n.Workbench.Skills.ToggleState.enabled(app: name)
        case .disabledInHarness:
            return L10n.Workbench.Skills.ToggleState.disabledInHarness(app: name)
        case .coupled where app.discoversSharedSkillRoot:
            return L10n.Workbench.Skills.ToggleState.coupledSharedRoot(app: name)
        case .coupled:
            return L10n.Workbench.Skills.ToggleState.coupledGemini(app: name)
        case .unknown:
            return L10n.Workbench.Skills.ToggleState.unknown(app: name)
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
    let onAcceptLocalChanges: () -> Void
    let onUninstall: () -> Void
    /// Makes one of `skill.otherCopies` the shared copy. Confirmed here, not
    /// in the copies popover, so the dialog is not torn down with it.
    var onReplaceShared: (SkillCopy) -> Void = { _ in }

    @State private var confirmingUninstall = false
    @State private var isHovering = false
    @State private var showingWiring = false
    @State private var showingCopies = false
    @State private var pendingReplacement: SkillCopy?

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
            L10n.Workbench.Skills.uninstallConfirmTitle(skill: skill.name),
            isPresented: $confirmingUninstall,
            titleVisibility: .visible
        ) {
            Button(L10n.Workbench.Skills.uninstall, role: .destructive) { onUninstall() }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Workbench.Skills.uninstallConfirmMessage)
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
                if skill.isLocallyModified {
                    modifiedBadge
                }
                if updateState?.updateAvailable == true {
                    updateBadge
                }
                if !skill.otherCopies.isEmpty {
                    copiesBadge
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
                .map { L10n.Workbench.Skills.Badge.nativeOff(app: $0.displayName) }
                .joined(separator: " · ")
            Text(names)
                .font(.system(size: max(9, density.resetCountdownFontSize - 2), weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
                .help(L10n.Workbench.Skills.Badge.nativeOffHelp)
        } else if !unknown.isEmpty {
            Text(L10n.Workbench.Skills.Badge.nativeUnknown)
                .font(.system(size: max(9, density.resetCountdownFontSize - 2), weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
                .help(L10n.Workbench.Skills.Badge.nativeUnknownHelp)
        }
        // `.coupled` deliberately gets no row capsule: it is the *normal*
        // state for every skill Cursor sees, and a permanent orange
        // "Cursor LINKED" on nearly every row read as a problem needing a
        // click that then did nothing. The circle's small link badge and the
        // wiring popover carry the information instead.
    }

    private var sourceBadge: some View {
        Group {
            if let slug = skill.id.repositorySlug,
               slug.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
               let url = URL(string: "https://github.com/" + slug) {
                Link(slug, destination: url)
            } else {
                Text(skill.id.repositorySlug ?? L10n.Workbench.Skills.sourceLocal)
            }
        }
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
                skill.repoBranch.map { L10n.Workbench.Skills.sourceBranch(branch: $0) }
                    ?? L10n.Workbench.Skills.sourceInstalledLocally
            )
    }

    /// Orange like the native-off capsule: the row is fine to use, but what
    /// is on disk is no longer what Vibe Bar installed.
    private var modifiedBadge: some View {
        Text(L10n.Workbench.Skills.Badge.modified)
            .font(.system(size: max(9, density.resetCountdownFontSize - 2), weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.12)))
            .help(L10n.Workbench.Skills.Badge.modifiedHelp)
    }

    @ViewBuilder
    private var updateBadge: some View {
        // Updating replaces the shared copy wholesale; when that copy carries
        // edits, say so before the click rather than after.
        if skill.isLocallyModified {
            updateCapsule.help(L10n.Workbench.Skills.Badge.updateHelpModified)
        } else {
            updateCapsule
        }
    }

    private var updateCapsule: some View {
        Text(L10n.Workbench.Skills.Badge.update)
            .font(.system(size: max(10, density.resetCountdownFontSize - 2), weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.45), lineWidth: 0.7))
    }

    private var copiesBadge: some View {
        Button {
            showingCopies = true
        } label: {
            Text(L10n.Workbench.Skills.Badge.copies(count: skill.otherCopies.count))
                .font(.system(size: max(10, density.resetCountdownFontSize - 2), weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.45), lineWidth: 0.7))
                .contentShape(Capsule())
        }
        .buttonStyle(.vibeBar)
        .help(L10n.Workbench.Skills.Badge.copiesHelp)
        .popover(isPresented: $showingCopies, arrowEdge: .bottom) {
            SkillCopiesPopover(skill: skill, density: density) { copy in
                showingCopies = false
                // Let the popover finish closing first: a dialog raised in
                // the same transaction can be dismissed along with it.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    pendingReplacement = copy
                }
            }
            .vibeBarNoInitialFocus()
        }
        .confirmationDialog(
            L10n.Workbench.Skills.Copies.replaceConfirmTitle(skill: skill.name),
            isPresented: Binding(
                get: { pendingReplacement != nil },
                set: { if !$0 { pendingReplacement = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingReplacement
        ) { copy in
            Button(L10n.Workbench.Skills.Copies.replaceShared, role: .destructive) {
                onReplaceShared(copy)
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.Workbench.Skills.Copies.replaceConfirmMessage)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button(
                L10n.Workbench.Skills.menuWiringDetails,
                systemImage: "point.3.connected.trianglepath.dotted"
            ) {
                showingWiring = true
            }
            Button(L10n.Workbench.Skills.menuRevealInFinder, systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    SkillAppCatalog.ssotDirectory()
                        .appendingPathComponent(skill.directory, isDirectory: true)
                ])
            }
            Divider()
            Button(
                L10n.Workbench.Skills.menuUpdateFromRepository,
                systemImage: "arrow.down.circle"
            ) { onUpdate() }
                .disabled(!skill.id.isRepositoryBacked)
            Button(
                L10n.Workbench.Skills.menuAcceptLocalChanges,
                systemImage: "checkmark.seal"
            ) { onAcceptLocalChanges() }
                .disabled(!skill.isLocallyModified)
            Divider()
            Button(L10n.Workbench.Skills.menuUninstall, systemImage: "trash", role: .destructive) {
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
        .accessibilityLabel(L10n.Workbench.Skills.menuMoreActions(skill: skill.name))
        .popover(isPresented: $showingWiring, arrowEdge: .trailing) {
            SkillWiringPopover(skill: skill, density: density)
                .vibeBarNoInitialFocus()
        }
    }
}
