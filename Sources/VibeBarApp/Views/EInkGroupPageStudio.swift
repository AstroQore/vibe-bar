import SwiftUI
import VibeBarCore

/// Reuses the ordinary paper stage and inspector at the region's full size.
/// Saving forks the page into a group-owned layout, so editing a spanning
/// page cannot resize a standalone page that was used as its starting point.
struct EInkGroupPageStudio: View {
    let region: EInkScreenRegion
    let width: Int
    let height: Int
    /// The screens under the region, so a preset explodes the way it draws —
    /// screen by screen, nothing across a bezel.
    var panes: [EInkRect] = []
    let snapshot: EInkDataSnapshot?
    let onSave: (EInkSlide, EInkCanvasLayout) -> Void
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService
    @Environment(\.dismiss) private var dismiss
    @State private var layout = EInkCanvasLayout()
    @State private var slide = EInkSlide(id: "", kind: .preset(.quotaLedger))
    @State private var selection: Set<UUID> = []
    @State private var report: EInkLayoutDiagnostics.Report?
    @State private var sections: [EInkFieldSection] = []
    @State private var ready = false
    @StateObject private var pending = PendingEditQueue()

    private var profile: EInkDeviceProfile {
        var profile = EInkDeviceProfile(width: width, height: height)
        profile.panes = panes
        return profile
    }
    private var scale: CGFloat { min(2, 650 / CGFloat(max(1, width))) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L10n.Settings.Eink.ScreenGroups.edit).font(.headline)
                Spacer()
                Button(L10n.Common.cancel) { dismiss() }
                Button(L10n.Common.save) {
                    pending.flush()
                    var saved = slide
                    saved.options.sourcePreset = saved.kind.preset ?? saved.options.sourcePreset
                    saved.kind = .custom(layoutID: "group-region-" + region.id)
                    onSave(saved, layout.normalized())
                    dismiss()
                }.disabled(!ready)
            }
            if ready {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView([.horizontal, .vertical]) {
                        EInkStudioStage(layout: $layout, selection: $selection, slide: slide,
                            orientation: .degrees0, profile: profile, snapshot: snapshot, scale: scale,
                            onReport: { report = $0 })
                            .frame(width: CGFloat(width), height: CGFloat(height))
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: CGFloat(width) * scale, height: CGFloat(height) * scale, alignment: .topLeading)
                    }
                    ScrollView {
                        EInkStudioInspector(layout: $layout, selection: $selection,
                            customLabels: $slide.options.customLabels, sections: sections, slide: slide,
                            orientation: .degrees0, profile: profile, snapshot: snapshot, report: report,
                            isPushing: false, canPush: false, showsPush: false, pending: pending, onPush: {})
                    }.frame(width: 300)
                }
            }
        }
        .padding(20).frame(width: 1040, height: 700)
        .onAppear {
            slide = region.slide
            if let id = slide.kind.layoutID,
               let existing = EInkRenderer.layout(id, orientation: .degrees0, layouts: settingsStore.settings.einkCanvasLayouts) {
                layout = existing.fitted(profile: profile, orientation: .degrees0)
            } else if let snapshot {
                layout = EInkPresetExploder.explode(slide: slide, orientation: .degrees0, profile: profile, snapshot: snapshot)
            } else { layout = EInkCanvasLayout(profile: profile, orientation: .degrees0) }
            sections = EInkFieldSection.sections(registry: quotaService.fieldRegistry)
            ready = true
        }
    }
}
