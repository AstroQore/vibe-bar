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
    /// The bulk change waiting on its confirmation dialog. Planned when the
    /// menu item is picked so the title quotes the count the loop will act
    /// on; the model re-reads the registry before running it.
    @State private var pendingBulk: SkillBulkPlan?

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
                // An archive can hold several skills, and switching all of
                // them on for every agent CLI is not what picking a file
                // asked for — but the harnesses the user marked as the
                // default for new installs are exactly that ask.
                model.installZip(url: url, apps: model.defaultApps)
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
        .sheet(item: $model.copiesSheet) { request in
            SkillCopiesSheet(density: density, skillID: request.id, model: model)
                .vibeBarNoInitialFocus()
                .vibeBarSystemControlFocus()
        }
        .sheet(item: $model.sharedPreview) { preview in
            SharedSkillPreviewSheet(preview: preview)
                .vibeBarNoInitialFocus()
                .vibeBarSystemControlFocus()
        }
        .confirmationDialog(
            pendingBulk.map(bulkConfirmTitle) ?? "",
            isPresented: Binding(
                get: { pendingBulk != nil },
                set: { if !$0 { pendingBulk = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingBulk
        ) { plan in
            Button(L10n.Workbench.Skills.Bulk.apply) {
                model.startBulk(plan)
                pendingBulk = nil
            }
            Button(L10n.Common.cancel, role: .cancel) { pendingBulk = nil }
        } message: { _ in
            Text(L10n.Workbench.Skills.Bulk.confirmMessage)
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
            TextField(L10n.Workbench.Skills.filterPlaceholder, text: $model.searchText)
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
                .accessibilityLabel(L10n.Workbench.Skills.filterClear)
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
                        ? L10n.Workbench.Skills.checkUpdatesCount(count: model.updatesAvailableCount)
                        : L10n.Workbench.Skills.checkUpdates,
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
                    title: L10n.Workbench.Skills.installFromZip,
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
                    title: L10n.Workbench.Skills.importExisting,
                    busy: model.isBusy(SkillsManagerModel.BusyKey.importing)
                )
                .porcelainToolbarButton()
            }
            .buttonStyle(.vibeBar(cornerRadius: 11))

            if !model.builtIns.isEmpty {
                builtInToggle
            }

            Button {
                model.presentBackupsSheet()
            } label: {
                buttonLabel(
                    systemImage: "clock.arrow.circlepath",
                    title: L10n.Workbench.Skills.backups,
                    busy: false
                )
                .porcelainToolbarButton()
            }
            .buttonStyle(.vibeBar(cornerRadius: 11))

            Button {
                model.isDiscoverSheetPresented = true
            } label: {
                buttonLabel(
                    systemImage: "sparkle.magnifyingglass",
                    title: L10n.Workbench.Skills.discover,
                    busy: false
                )
                .porcelainToolbarButton(prominent: true)
            }
            .buttonStyle(.vibeBar(cornerRadius: 11))
            .help(L10n.Workbench.Skills.discoverHelp)
        }
    }

    /// Only offered when this Mac has built-ins to show, so the toolbar of
    /// someone without any is unchanged. Writes the setting on click only.
    private var builtInToggle: some View {
        Button {
            model.setShowsBuiltIn(!model.showsBuiltIn)
        } label: {
            buttonLabel(
                systemImage: model.showsBuiltIn ? "checkmark.square" : "square",
                title: L10n.Workbench.Skills.filterBuiltIn,
                busy: false
            )
            .porcelainToolbarButton()
        }
        .buttonStyle(.vibeBar(cornerRadius: 11))
        .accessibilityAddTraits(model.showsBuiltIn ? [.isSelected] : [])
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
                    Text(AppLocale.number(count))
                        .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold,
                                      design: .rounded).monospacedDigit())
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background(Capsule().fill(app.accent.opacity(count == 0 ? 0.05 : 0.14)))
                .overlay(Capsule().stroke(app.accent.opacity(count == 0 ? 0.16 : 0.45), lineWidth: 0.8))
                .opacity(count == 0 ? 0.5 : 1)
                .saturation(count == 0 ? 0.2 : 1)
                .contentShape(Capsule())
                .help(appCountHelp(
                    app: app,
                    count: count,
                    enabled: enabled,
                    coupled: coupled,
                    nativeDisabled: nativeDisabled
                ))
                // Right-click only: a left-click `Menu` would restyle the
                // capsule into a pop-up button, and the pill reads as a count
                // first. The tooltip's second line says the menu is there.
                .contextMenu { bulkMenu(for: app) }
                .disabled(isBulkRunning)
                .accessibilityLabel(
                    L10n.Workbench.Skills.appSeesCount(app: app.displayName, count: count)
                )
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
            .help(L10n.Workbench.Skills.syncExplainerHelp)
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

    private var isBulkRunning: Bool {
        model.isBusy(SkillsManagerModel.BusyKey.bulk)
    }

    /// Kept to labels and one `contains` lookup: the menu is built with the
    /// capsule on every render, so the plans — and even whether the filter
    /// shows anything — are only worked out on a pick.
    @ViewBuilder
    private func bulkMenu(for app: SkillAppTarget) -> some View {
        let name = app.displayName
        Button(L10n.Workbench.Skills.Bulk.enableForShown(app: name)) {
            requestBulk(app: app, direction: .enable)
        }
        Button(L10n.Workbench.Skills.Bulk.disableForShown(app: name)) {
            requestBulk(app: app, direction: .disable)
        }
        Divider()
        Toggle(
            L10n.Workbench.Skills.Bulk.useAsDefault,
            isOn: Binding(
                get: { model.isDefaultApp(app) },
                set: { model.setDefaultApp(app, isOn: $0) }
            )
        )
    }

    /// Rows that cannot be changed still go through the dialog: its title
    /// quotes how many will actually change, so the "failed" count in the
    /// summary is never a surprise. Only a filter whose every row is already
    /// in the requested state is answered straight away.
    private func requestBulk(app: SkillAppTarget, direction: SkillBulkDirection) {
        let plan = model.bulkPlan(app: app, direction: direction)
        if !plan.needsConfirmation {
            model.toast = L10n.Workbench.Skills.Toast.bulkDone(app: app.displayName, succeeded: 0)
        } else {
            pendingBulk = plan
        }
    }

    private func bulkConfirmTitle(_ plan: SkillBulkPlan) -> String {
        switch plan.direction {
        case .enable:
            L10n.Workbench.Skills.Bulk.confirmEnableTitle(
                app: plan.app.displayName, count: plan.steps.count
            )
        case .disable:
            L10n.Workbench.Skills.Bulk.confirmDisableTitle(
                app: plan.app.displayName, count: plan.steps.count
            )
        }
    }

    private func appCountHelp(
        app: SkillAppTarget,
        count: Int,
        enabled: Int,
        coupled: Int,
        nativeDisabled: Int
    ) -> String {
        var help = L10n.Workbench.Skills.appSeesCount(app: app.displayName, count: count)
        if coupled > 0 {
            // AntiGravity's coupled skills arrive through the Gemini CLI
            // compatibility root, not the shared root it never scans — name
            // the mechanism the harness actually uses. Each variant is one
            // whole clause: a translated sentence cannot be built by dropping
            // a noun phrase into an English frame.
            let clause = app.discoversSharedSkillRoot
                ? L10n.Workbench.Skills.appCountViaSharedRoot(enabled: enabled, coupled: coupled)
                : L10n.Workbench.Skills.appCountViaGeminiRoot(enabled: enabled, coupled: coupled)
            help += " · " + clause
        }
        if nativeDisabled > 0 {
            help += " · " + L10n.Workbench.Skills.appCountNativeDisabled(count: nativeDisabled)
        }
        // Its own line rather than another " · " clause: the count answers
        // "what does this harness see", the second line says what a
        // right-click does about it.
        return [help, L10n.Workbench.Skills.Bulk.defaultHelp].joined(separator: "\n")
    }

    private var countSummary: String {
        let total = model.skills.count + model.discoveredShared.count
        let shown = model.filteredSkills.count + model.filteredSharedDiscoveries.count
        var parts = [
            shown == total
                ? L10n.Workbench.Skills.countTotal(count: total)
                : L10n.Workbench.Skills.countFiltered(shown: shown, total: total)
        ]
        // Each part is a complete count in its own right, listed with the
        // same " · " the app-count tooltips use — not a clause spliced into
        // the other's sentence.
        let modified = model.locallyModifiedCount
        if modified > 0 { parts.append(L10n.Workbench.Skills.modifiedCount(count: modified)) }
        // What the list shows: already empty while the toggle hides them,
        // and narrowed by the search like the installed count.
        let builtIns = model.filteredBuiltIns.count
        if builtIns > 0 { parts.append(L10n.Workbench.Skills.builtInCount(count: builtIns)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - List

    @ViewBuilder
    private var skillList: some View {
        let installed = model.filteredSkills
        let builtIns = model.filteredBuiltIns
        let discovered = model.filteredSharedDiscoveries
        if model.skills.isEmpty && model.discoveredShared.isEmpty && (!model.showsBuiltIn || model.builtIns.isEmpty) {
            emptyCard
        } else if installed.isEmpty && builtIns.isEmpty && discovered.isEmpty {
            CardShell(density: density, alignment: .center) {
                Text(L10n.Workbench.Skills.noMatch(query: model.searchText))
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !installed.isEmpty {
                        resourceSection(L10n.Workbench.Library.managed)
                    }
                    ForEach(installed) { skill in
                        SkillListRow(
                            density: density,
                            skill: skill,
                            updateState: model.updateState(for: skill),
                            isBusy: model.isBusy(skill: skill),
                            onSetActivation: {
                                model.setActivation(skill: skill, app: $0, action: $1)
                            },
                            onUpdate: { model.updateSkill(skill) },
                            onAcceptLocalChanges: { model.acceptLocalChanges(skill) },
                            onUninstall: { model.uninstall(skill) },
                            onShowCopies: { model.presentCopies(skill) },
                            onReconfirmSource: { model.reconfirmLink(skill) },
                            onConvertToCopy: { model.convertToCopy(skill) }
                        )
                    }
                    if !discovered.isEmpty {
                        resourceSection(L10n.Workbench.Library.discovered)
                        ForEach(discovered) { entry in
                            SharedSkillDiscoveryRow(
                                entry: entry,
                                density: density,
                                isBusy: model.isBusy(SkillsManagerModel.BusyKey.shared(entry)),
                                preview: { model.previewSharedSkill(entry) },
                                onAdoptLink: { model.adoptLink(entry) },
                                onReconfirm: { model.reconfirmLink(entry) },
                                onUnlink: { model.unlink(entry) }
                            )
                        }
                    }
                    // Built-ins trail the installed rows: they are the
                    // harnesses' own, read-only, and the list is about the
                    // shared library first.
                    ForEach(builtIns) { copy in
                        SkillBuiltInRow(
                            density: density,
                            copy: copy,
                            isBusy: model.isBusy(SkillsManagerModel.BusyKey.copy(copy)),
                            onCopyToShared: { model.copyToShared(copy) }
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

    private func resourceSection(_ title: String) -> some View {
        Text(title)
            .font(.system(size: density.subtitleFontSize, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, density.cardSpacing)
            .padding(.bottom, density.cardSpacing / 2)
    }

    private var emptyCard: some View {
        CardShell(density: density, alignment: .center) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(L10n.Workbench.Skills.Empty.headline)
                .font(.system(size: density.titleFontSize, weight: .semibold))
            Text(L10n.Workbench.Skills.Empty.body)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button(L10n.Workbench.Skills.importExisting) { model.presentImportSheet() }
                    .buttonStyle(WorkbenchPillButtonStyle())
                Button(L10n.Workbench.Skills.discover) { model.isDiscoverSheetPresented = true }
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
                .accessibilityLabel(L10n.Common.dismiss)
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
