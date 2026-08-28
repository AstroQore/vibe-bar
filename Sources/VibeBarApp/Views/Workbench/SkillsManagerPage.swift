import SwiftUI
import UniformTypeIdentifiers
import VibeBarCore

/// The Workbench's Skills page.
///
/// Unlike Usage Stats, which is one scrolling column of cards, this page is a
/// fixed toolbar over a list that owns the remaining height: the installed set
/// is routinely a hundred rows on a machine that already uses skills, and a
/// list that scrolls inside its own frame keeps the search field and the
/// action buttons on screen while the user works through it.
struct SkillsManagerPage: View {
    let density: Theme.Density
    @ObservedObject var model: SkillsManagerModel

    @State private var showsZipImporter = false
    @State private var toastDismissal: Task<Void, Never>?
    @State private var showingSyncExplainer = false

    var body: some View {
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            toolbar
            skillList
        }
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, density.popoverPaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) { toastBanner }
        .task {
            model.activate()
            await model.monitorFilesystem()
        }
        .onChange(of: model.toast) { _, newValue in
            toastDismissal?.cancel()
            guard newValue != nil else { return }
            toastDismissal = Task {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                model.toast = nil
            }
        }
        .fileImporter(
            isPresented: $showsZipImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                // Installed into the shared directory only. An archive can
                // hold several skills, and switching all of them on for every
                // agent CLI is not what picking a file asked for.
                model.installZip(url: url, apps: [])
            case let .failure(error):
                model.toast = error.localizedDescription
            }
        }
        // The sheets are native forms: no initial selection, but the system
        // focus ring the Workbench window switches off comes back for their
        // fields, toggles, and default-styled buttons.
        .sheet(isPresented: $model.isDiscoverSheetPresented, onDismiss: model.discoverSheetDismissed) {
            SkillDiscoverSheet(density: density, model: model)
                .vibeBarNoInitialFocus()
                .vibeBarSystemControlFocus()
        }
        .sheet(isPresented: $model.isImportSheetPresented) {
            SkillImportSheet(density: density, model: model)
                .vibeBarNoInitialFocus()
                .vibeBarSystemControlFocus()
        }
        .sheet(isPresented: $model.isBackupsSheetPresented) {
            SkillBackupsSheet(density: density, model: model)
                .vibeBarNoInitialFocus()
                .vibeBarSystemControlFocus()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    searchField
                    actionButtons
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
            Divider().opacity(0.35)
            appCountRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .workbenchToolbarSurface()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Filter installed skills", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: max(12, density.segmentedFontSize)))
                // A text field draws nothing of its own to say keyboard focus
                // arrived; the system ring comes back for it alone.
                .vibeBarSystemControlFocus()
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.vibeBar)
                .accessibilityLabel("Clear the filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .frame(width: 250)
        .workbenchFieldSurface(cornerRadius: 15)
    }

    // The porcelain pill is part of each button's label, not decoration
    // around it: applied outside the Button its 11 pt side padding sat
    // outside the clickable area, so the pill's edges ignored clicks.
    private var actionButtons: some View {
        HStack(spacing: 6) {
            Button {
                model.checkForUpdates()
            } label: {
                buttonLabel(
                    systemImage: "arrow.triangle.2.circlepath",
                    title: model.updatesAvailableCount > 0
                        ? "Check Updates · \(model.updatesAvailableCount)"
                        : "Check Updates",
                    busy: model.isBusy(SkillsManagerModel.BusyKey.updates)
                )
                .porcelainToolbarButton()
            }
            .buttonStyle(.vibeBar(cornerRadius: 11))
            .disabled(model.isBusy(SkillsManagerModel.BusyKey.updates))

            Button {
                showsZipImporter = true
            } label: {
                buttonLabel(
                    systemImage: "doc.zipper",
                    title: "Install from ZIP",
                    busy: model.isBusy(SkillsManagerModel.BusyKey.zip)
                )
                .porcelainToolbarButton()
            }
            .buttonStyle(.vibeBar(cornerRadius: 11))

            Button {
                model.presentImportSheet()
            } label: {
                buttonLabel(
                    systemImage: "square.and.arrow.down.on.square",
                    title: "Import Existing",
                    busy: model.isBusy(SkillsManagerModel.BusyKey.importing)
                )
                .porcelainToolbarButton()
            }
            .buttonStyle(.vibeBar(cornerRadius: 11))

            Button {
                model.presentBackupsSheet()
            } label: {
                buttonLabel(systemImage: "clock.arrow.circlepath", title: "Backups", busy: false)
                    .porcelainToolbarButton()
            }
            .buttonStyle(.vibeBar(cornerRadius: 11))

            Button {
                model.isDiscoverSheetPresented = true
            } label: {
                buttonLabel(systemImage: "sparkle.magnifyingglass", title: "Discover", busy: false)
                    .porcelainToolbarButton(prominent: true)
            }
            .buttonStyle(.vibeBar(cornerRadius: 11))
            .help("Browse configured repositories and the skills.sh index")
        }
    }

    private func buttonLabel(systemImage: String, title: String, busy: Bool) -> some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: max(9, density.segmentedFontSize - 1), weight: .semibold))
            }
            Text(title)
                .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                .lineLimit(1)
        }
        .frame(minHeight: 28)
    }

    /// How many skills each agent CLI can actually use right now — enabled
    /// plus shared-root discoveries, the number that answers "what does this
    /// harness see", with the enabled/coupled split spelled out in the
    /// tooltip. The old pill counted only `.enabled`, so Cursor claimed three
    /// skills while its shared-root scan saw nearly a hundred.
    private var appCountRow: some View {
        HStack(spacing: 6) {
            ForEach(SkillAppTarget.managedHarnesses, id: \.self) { app in
                let count = model.visibleCount(for: app)
                let enabled = model.installedCount(for: app)
                let nativeDisabled = model.nativeDisabledCount(for: app)
                let coupled = model.coupledCount(for: app)
                HStack(spacing: 4) {
                    SkillAppGlyph(app: app, size: density.segmentedFontSize)
                    Text("\(count)")
                        .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold,
                                      design: .rounded).monospacedDigit())
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background(Capsule().fill(app.accent.opacity(count == 0 ? 0.05 : 0.14)))
                .overlay(Capsule().stroke(app.accent.opacity(count == 0 ? 0.16 : 0.45), lineWidth: 0.8))
                .opacity(count == 0 ? 0.5 : 1)
                .saturation(count == 0 ? 0.2 : 1)
                .help(appCountHelp(
                    app: app,
                    count: count,
                    enabled: enabled,
                    coupled: coupled,
                    nativeDisabled: nativeDisabled
                ))
                .accessibilityLabel("\(app.displayName), sees \(count) skills")
            }
            Button {
                showingSyncExplainer = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: max(10, density.segmentedFontSize), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.vibeBar)
            .help("How skill syncing works — roots, links, and native switches")
            .popover(isPresented: $showingSyncExplainer, arrowEdge: .bottom) {
                SkillSyncExplainerPopover(density: density)
                    .vibeBarNoInitialFocus()
            }
            Spacer(minLength: 8)
            Text(countSummary)
                .font(.system(size: max(10, density.resetCountdownFontSize), design: .rounded)
                    .monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func appCountHelp(
        app: SkillAppTarget,
        count: Int,
        enabled: Int,
        coupled: Int,
        nativeDisabled: Int
    ) -> String {
        var help = "\(app.displayName) sees \(count) skill\(count == 1 ? "" : "s")"
        if coupled > 0 {
            // AntiGravity's coupled skills arrive through the Gemini CLI
            // compatibility root, not the shared root it never scans — name
            // the mechanism the harness actually uses.
            let root = app.discoversSharedSkillRoot
                ? "the shared skills root"
                : "the Gemini CLI compatibility root"
            help += " · \(enabled) enabled + \(coupled) via \(root)"
        }
        if nativeDisabled > 0 {
            help += " · \(nativeDisabled) projected but disabled"
        }
        return help
    }

    private var countSummary: String {
        let total = model.skills.count
        let shown = model.filteredSkills.count
        if shown == total { return "\(total) skill\(total == 1 ? "" : "s")" }
        return "\(shown) of \(total) skills"
    }

    // MARK: - List

    @ViewBuilder
    private var skillList: some View {
        if model.skills.isEmpty {
            emptyCard
        } else if model.filteredSkills.isEmpty {
            CardShell(density: density, alignment: .center) {
                Text("No skill matches \"\(model.searchText)\"")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredSkills) { skill in
                        SkillListRow(
                            density: density,
                            skill: skill,
                            updateState: model.updateState(for: skill),
                            isBusy: model.isBusy(skill: skill),
                            onSetActivation: {
                                model.setActivation(skill: skill, app: $0, action: $1)
                            },
                            onUpdate: { model.updateSkill(skill) },
                            onUninstall: { model.uninstall(skill) }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            .cardSurface(density: density)
            .frame(maxHeight: .infinity)
        }
    }

    private var emptyCard: some View {
        CardShell(density: density, alignment: .center) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("No skills recorded yet")
                .font(.system(size: density.titleFontSize, weight: .semibold))
            Text("Vibe Bar keeps one copy of every skill in ~/.agents/skills and links it into "
                + "each agent CLI. Import what is already on this Mac, or install something new "
                + "from a repository.")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button("Import Existing") { model.presentImportSheet() }
                    .buttonStyle(WorkbenchPillButtonStyle())
                Button("Discover") { model.isDiscoverSheetPresented = true }
                    .buttonStyle(WorkbenchPillButtonStyle(prominent: true))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastBanner: some View {
        if let toast = model.toast {
            HStack(spacing: 8) {
                Text(toast)
                    .font(.system(size: density.subtitleFontSize))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.toast = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: density.subtitleFontSize - 2, weight: .semibold))
                }
                .buttonStyle(.vibeBar)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 520)
            .workbenchOverlaySurface(
                in: RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
            )
            .padding(.bottom, density.popoverPaddingV)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private extension View {
    /// Small neutral actions use the same rounded hairline as the mockup's
    /// porcelain controls; Discover opts into the one deliberate accent.
    func porcelainToolbarButton(prominent: Bool = false) -> some View {
        modifier(PorcelainToolbarButtonStyle(prominent: prominent))
    }
}

private struct PorcelainToolbarButtonStyle: ViewModifier {
    let prominent: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 11)
            .frame(minHeight: 27)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(prominent ? Color.accentColor : Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(prominent ? Color.accentColor.opacity(0.72) : Color.primary.opacity(0.12), lineWidth: 0.7)
            )
    }
}
