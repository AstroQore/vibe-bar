import AppKit
import SwiftUI
import VibeBarCore

/// Default field layouts remain live in Studio before Custom is enabled.
struct MenuBarDefaultStage: View {
    let kind: MenuBarItemKind
    let scheme: ColorScheme
    let scale: CGFloat
    let onNaturalSize: (CGSize) -> Void
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService
    @StateObject private var inputs = MenuBarStripInputObserver()

    var body: some View {
        let item = settingsStore.settings.menuBarItem(kind)
        let composition = MenuBarNativeRenderer.composition(for: item, registry: quotaService.fieldRegistry, quota: { environment.quota(for: $0) })
        let zoom = MenuBarStageView.baseZoom * scale
        TimelineView(QuotaClockSchedule(isActive: composition.needsForecastClock(colorBasis: settingsStore.settings.menuBarColorBasis), interval: 300)) { clock in
            Group {
                if item.layout == .iconOnly {
                    if let image = ProviderBrandIcon.image(for: kind) {
                        Image(nsImage: image).resizable().frame(width: 16 * zoom, height: 16 * zoom)
                    }
                } else {
                    let quotas = MenuBarStripResolver.snapshots(for: composition, itemSettings: item,
                        settings: settingsStore.settings, environment: environment, now: clock.date)
                    let plan = composition.plan(quotas: quotas, displayMode: settingsStore.settings.displayMode,
                        colorBasis: settingsStore.settings.menuBarColorBasis, now: clock.date, canvas: MenuBarStripMetrics.twoRowCanvas())
                    let drawing = MenuBarNativeRenderer.render(plan: plan, quotas: quotas, template: composition.template,
                        displayMode: settingsStore.settings.displayMode,
                        appearance: NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!, magnification: zoom)
                    Image(nsImage: drawing.image)
                        .frame(width: drawing.size.width * zoom, height: drawing.size.height * zoom)
                }
            }
            .padding(18)
            .background(scheme == .dark ? Color.black.opacity(0.84) : Color.white.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .environment(\.colorScheme, scheme)
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                onNaturalSize(CGSize(width: $0.width / scale, height: $0.height / scale))
            }
        }
        .onAppear { inputs.start(environment: environment) }
    }
}
