import AppKit
import Combine
import SwiftUI
import VibeBarCore

/// The measurements a composed strip is drawn at.
///
/// One table, because the status item and the Settings preview draw the same
/// strip: a preview at a different face, a different glyph cap, or without the
/// bar's fit-to-height pass is a preview of a different strip.
enum MenuBarStripMetrics {
    /// The face a one-row strip is drawn at — the status item's own.
    static var singleRowFontSize: CGFloat { NSFont.smallSystemFontSize }
    /// ...and a rasterized two-row strip, which has half the height each.
    static let twoRowFontSize: CGFloat = 9
    /// Deliberate negative tuck between the two bands.
    static let twoRowLineSpacing: CGFloat = -2
    static let twoRowVerticalPadding: CGFloat = 1
    /// Past this it is the glyph, not the type, that sets the row height.
    static let maximumGlyphSide = CGFloat(MenuBarStripGeometry.maximumTwoRowGlyphSide)

    /// The glyph box every drawing path asks for — the arithmetic lives in
    /// `MenuBarStripGeometry` so it is one decision with tests, not three that
    /// agree by coincidence.
    static func glyphSide(fontSize: CGFloat, rowCount: Int) -> CGFloat {
        CGFloat(MenuBarStripGeometry.glyphSide(fontSize: Double(fontSize), rowCount: rowCount))
    }

    static func singleRowGlyphSide(fontSize: CGFloat) -> CGFloat {
        CGFloat(MenuBarStripGeometry.singleRowGlyphSide(fontSize: Double(fontSize)))
    }

    static func twoRowGlyphSide(fontSize: CGFloat) -> CGFloat {
        CGFloat(MenuBarStripGeometry.twoRowGlyphSide(fontSize: Double(fontSize)))
    }
    /// System text occupies roughly this much vertical space per point of
    /// font size. Only used to *estimate* the preview's height; the status
    /// item measures its real attributed strings.
    static let lineHeightRatio: CGFloat = 1.2

    /// The face the status item would draw this strip at. The choice lives in
    /// `MenuBarStripGeometry.face`; this only spells the point sizes.
    static func baseFontSize(template: MenuBarComposition.Template, rowCount: Int) -> CGFloat {
        switch MenuBarStripGeometry.face(template: template, rowCount: rowCount) {
        case .system: return singleRowFontSize
        case .compact: return twoRowFontSize
        }
    }

    /// Points between two adjacent columns of a rasterized strip.
    static let twoRowColumnSpacing: CGFloat = 8

    /// Height the rasterized image actually has for content, after padding.
    static func twoRowAvailableHeight() -> CGFloat {
        max(18, NSStatusBar.system.thickness - 2) - twoRowVerticalPadding * 2
    }

    /// The canvas a stacked strip is planned against — this Mac's bar, not the
    /// nominal one. The status item and the preview both ask for it here, so a
    /// block capped in the bar is capped in the preview by the same arithmetic.
    static func twoRowCanvas() -> MenuBarStripCanvas {
        MenuBarStripCanvas(
            availableHeight: Double(twoRowAvailableHeight()),
            baseFontSize: Double(twoRowFontSize),
            lineHeightRatio: Double(lineHeightRatio),
            lineSpacing: Double(twoRowLineSpacing)
        )
    }

    /// The fit-to-height scale for a plan drawn at `baseFontSize`, estimated
    /// from the type metrics rather than measured. The status item applies the
    /// same `MenuBarStripFit` rule to its real measurements — this is the
    /// preview's approximation of it, so a two-row strip previews at roughly
    /// the size it will actually be drawn.
    static func estimatedFitScale(plan: MenuBarRenderPlan, baseFontSize: CGFloat) -> CGFloat {
        guard plan.isTwoRow else { return 1 }
        let rows = plan.rows
        let content = CGFloat(MenuBarStripGeometry.twoRowContentHeight(
            rowFontSizes: rows.map { Double(baseFontSize) * ($0.tokens.map(\.fontScale).max() ?? 1) },
            lineSpacing: Double(twoRowLineSpacing),
            lineHeightRatio: Double(lineHeightRatio)
        ))
        return CGFloat(MenuBarStripFit.scale(
            contentHeight: Double(content),
            availableHeight: Double(twoRowAvailableHeight())
        ))
    }
}

/// The paint a composed block ends up wearing.
///
/// One step past `MenuBarTokenColorRole`: the role says *which* colour to
/// follow, this says which colour that turned out to be. It exists so the
/// status item and the editor's preview share one decision and only differ in
/// how they spell the result — an `NSColor` in an attributed string, a
/// SwiftUI `Color` in a view. Two independent switches would drift the day
/// somebody adds a role.
enum MenuBarStripPaint: Equatable {
    case quota(MenuBarPercentColor)
    case brand(ToolType)
    case primary
    case secondary
    case tertiary
    case fixed(red: Double, green: Double, blue: Double, alpha: Double)
}

enum MenuBarStripPalette {
    /// Resolve a role against the snapshot it was planned with.
    ///
    /// Pure and cheap: the expensive inputs (the forecast verdict) are already
    /// in the snapshot, so this is safe to call while drawing.
    static func paint(
        for role: MenuBarTokenColorRole,
        quotas: [MenuBarQuotaSnapshot],
        displayMode: DisplayMode
    ) -> MenuBarStripPaint {
        switch role {
        case let .quota(fieldId, basis):
            guard let quota = quotas.first(where: { $0.fieldId == fieldId }) else { return .primary }
            return .quota(MenuBarPercentColor.resolve(
                basis: basis,
                verdict: basis == .forecast ? quota.forecast?.verdict : nil,
                percent: quota.displayPercent,
                displayMode: displayMode
            ))
        case let .brand(tool):
            return .brand(tool)
        case .primary:
            return .primary
        case .secondary:
            return .secondary
        case .tertiary:
            return .tertiary
        case let .fixed(hex):
            guard let parts = MenuBarHexColor.components(hex) else { return .primary }
            return .fixed(red: parts.r, green: parts.g, blue: parts.b, alpha: parts.a)
        }
    }

    /// AppKit spelling, for the status item's attributed strings and its
    /// rasterized two-row image.
    @MainActor
    static func nsColor(_ paint: MenuBarStripPaint) -> NSColor {
        switch paint {
        case let .quota(color):
            // The same system colours the pre-composer menu bar used: they
            // have to stay legible against light, dark, and tinted wallpapers.
            switch color {
            case .healthy: return .systemGreen
            case .surplus: return .systemBlue
            case .watch: return .systemOrange
            case .risk: return .systemRed
            }
        case let .brand(tool):
            return brandAccent(for: tool)
        case .primary:
            return .labelColor
        case .secondary:
            return .secondaryLabelColor
        case .tertiary:
            return .tertiaryLabelColor
        case let .fixed(red, green, blue, alpha):
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    /// SwiftUI spelling, for the editor's preview. `.primary` and friends stay
    /// semantic so a preview rendered in the opposite colour scheme shows what
    /// the other menu bar will actually look like — which is the entire point
    /// of showing both.
    static func color(_ paint: MenuBarStripPaint) -> Color {
        switch paint {
        case let .quota(color):
            switch color {
            case .healthy: return Color(nsColor: .systemGreen)
            case .surplus: return Color(nsColor: .systemBlue)
            case .watch: return Color(nsColor: .systemOrange)
            case .risk: return Color(nsColor: .systemRed)
            }
        case let .brand(tool):
            return Theme.providerAccent(for: tool)
        case .primary:
            return .primary
        case .secondary:
            return .secondary
        case .tertiary:
            return Color.primary.opacity(0.45)
        case let .fixed(red, green, blue, alpha):
            return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
        }
    }

    /// Stable cache key for a resolved paint, used to key rasterized brand
    /// marks. Keyed on the paint rather than the `NSColor`, whose description
    /// is not stable for a dynamic system colour.
    static func cacheKey(_ paint: MenuBarStripPaint) -> String {
        switch paint {
        case let .quota(color):
            switch color {
            case .healthy: return "healthy"
            case .surplus: return "surplus"
            case .watch: return "watch"
            case .risk: return "risk"
            }
        case let .brand(tool): return "brand.\(tool.rawValue)"
        case .primary: return "label"
        case .secondary: return "secondary"
        case .tertiary: return "tertiary"
        case let .fixed(red, green, blue, alpha):
            return "fixed.\(red).\(green).\(blue).\(alpha)"
        }
    }

    /// AppKit twin of the shared provider accent table, memoized for the
    /// process: the status item re-renders on a 120 ms throttle and must not
    /// bridge a SwiftUI colour every tick.
    ///
    /// The table itself is `Theme.providerAccent` — the composer's brand
    /// swatches, the mini window, and the charts all read that one table, so a
    /// provider cannot be teal in one place and green in another.
    @MainActor
    static func brandAccent(for tool: ToolType) -> NSColor {
        if let cached = brandAccentCache[tool] { return cached }
        let color = NSColor(Theme.providerAccent(for: tool))
        brandAccentCache[tool] = color
        return color
    }

    @MainActor private static var brandAccentCache: [ToolType: NSColor] = [:]
}

/// Builds the live quota snapshots a composed strip is planned against.
///
/// Shared by the status item and the editor's preview so both are looking at
/// the same numbers, and so the rule about *which* quotas get a forecast is
/// written once. Only the fields the strip actually names are resolved, and a
/// forecast is computed only where a block, a colour, or a rule reads one —
/// plus the case the plain field strip already pays for, an automatic colour
/// under the forecast basis.
@MainActor
enum MenuBarStripResolver {
    /// Every publisher a composed strip's inputs arrive on.
    ///
    /// One list with two consumers — the status item's render pipeline and the
    /// Settings preview — because two lists is two chances to forget one, and
    /// forgetting one is invisible: the preview simply keeps showing the
    /// previous generation while the bar beside it updates.
    ///
    /// Everything `snapshots(...)` and `liveFieldIds(...)` read has to be here:
    ///
    /// | What the resolver reads | Publisher |
    /// | --- | --- |
    /// | display mode, colour basis, custom labels, the composition itself | `settingsStore.$settings` |
    /// | the live buckets | `quotaService.$lastSuccessByAccount`, `$lastErrorByAccount` |
    /// | discovered fields, so a new bucket resolves | `quotaService.$fieldRegistry` |
    /// | forecast evidence | `quotaService.$observationsByAccountBucket`, `$historyByAccountBucket` |
    /// | forecast activity weighting | `costService.$snapshots` |
    /// | the account id a forecast is keyed on | `accountStore.$accounts` |
    /// | the field path's provider status | `serviceStatus.$snapshotByTool` |
    ///
    /// A refresh publishes the quota first and records observations in a
    /// follow-up task, so the later ones are not redundant — they are the
    /// difference between a forecast colour describing this refresh and the
    /// previous one.
    static func inputPublishers(environment: AppEnvironment) -> [AnyPublisher<Void, Never>] {
        [
            environment.settingsStore.$settings.map { _ in () }.eraseToAnyPublisher(),
            environment.quotaService.$lastSuccessByAccount.map { _ in () }.eraseToAnyPublisher(),
            environment.quotaService.$lastErrorByAccount.map { _ in () }.eraseToAnyPublisher(),
            environment.quotaService.$fieldRegistry.map { _ in () }.eraseToAnyPublisher(),
            environment.quotaService.$observationsByAccountBucket.map { _ in () }.eraseToAnyPublisher(),
            environment.quotaService.$historyByAccountBucket.map { _ in () }.eraseToAnyPublisher(),
            environment.costService.$snapshots.map { _ in () }.eraseToAnyPublisher(),
            environment.accountStore.$accounts.map { _ in () }.eraseToAnyPublisher(),
            environment.serviceStatus.$snapshotByTool.map { _ in () }.eraseToAnyPublisher()
        ]
    }

    static func snapshots(
        for composition: MenuBarComposition,
        itemSettings: MenuBarItemSettings,
        settings: AppSettings,
        environment: AppEnvironment,
        now: Date = Date()
    ) -> [MenuBarQuotaSnapshot] {
        let registry = environment.quotaService.fieldRegistry
        let requirements = composition.quotaRequirements
        let wantsForecastColors = settings.menuBarColorBasis == .forecast
        var out: [MenuBarQuotaSnapshot] = []
        out.reserveCapacity(requirements.count)
        for requirement in requirements {
            guard
                let field = MenuBarFieldCatalog.field(id: requirement.fieldId, registry: registry),
                let bucket = environment.quota(for: field.tool)?.bucket(id: field.bucketId)
            else { continue }
            var forecast: MenuBarQuotaSnapshot.Forecast?
            if requirement.needsForecast || wantsForecastColors,
               let computed = paceForecast(for: field.tool, bucket: bucket, environment: environment) {
                forecast = MenuBarQuotaSnapshot.Forecast(
                    verdict: computed.verdict,
                    projectedRemainingPercent: computed.projectedRemainingPercent,
                    runOutAt: computed.runOutAt
                )
            }
            out.append(MenuBarQuotaSnapshot(
                fieldId: field.id,
                tool: field.tool,
                label: label(for: field, bucket: bucket, itemSettings: itemSettings),
                usedPercent: bucket.usedPercent,
                displayPercent: bucket.displayPercent(settings.displayMode, tool: field.tool),
                resetAt: bucket.resetAt,
                rawWindowSeconds: bucket.rawWindowSeconds,
                forecast: forecast
            ))
        }
        return out
    }

    /// Every catalog field whose bucket a provider is currently returning.
    /// Feeds `MenuBarComposition.availability(liveFieldIds:)`, which is how the
    /// editor tells "this block is misconfigured" apart from "this provider is
    /// not answering right now".
    static func liveFieldIds(environment: AppEnvironment) -> Set<String> {
        let registry = environment.quotaService.fieldRegistry
        var live: Set<String> = []
        for option in MenuBarFieldCatalog.mergedFields(registry: registry)
        where environment.quota(for: option.tool)?.bucket(id: option.bucketId) != nil {
            live.insert(option.id)
        }
        return live
    }

    static func paceForecast(
        for tool: ToolType,
        bucket: QuotaBucket,
        environment: AppEnvironment
    ) -> QuotaPaceForecast? {
        guard let accountId = environment.account(for: tool)?.id else { return nil }
        let snapshot = environment.costService.snapshot(for: tool)
        return environment.quotaService.paceForecast(
            accountId: accountId,
            bucket: bucket,
            activityHeatmap: snapshot?.heatmap,
            dailyActivity: snapshot?.dailyHistory ?? [],
            now: Date(),
            allowsPostResetGrace: true
        )
    }

    /// What a quota is called on this item's strip: the user's rename if there
    /// is one, else the live bucket's own short label.
    ///
    /// Resolved here, on every render, rather than captured once: the generic
    /// window words go through `QuotaGroupLabelLocalizer`, so the name follows
    /// the app's language the way every other label does. A rename the user
    /// typed is returned untouched — it is their text, not a contract value a
    /// translation may improve.
    static func label(
        for field: MenuBarFieldOption,
        bucket: QuotaBucket,
        itemSettings: MenuBarItemSettings
    ) -> String {
        let custom = itemSettings.customLabels[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        let contractLabel = field.defaultLabel != bucket.shortLabel
            ? bucket.shortLabel
            : field.defaultLabel
        return QuotaGroupLabelLocalizer.display(contractLabel)
    }
}

/// Subscribes once to `MenuBarStripResolver.inputPublishers` and republishes a
/// counter.
///
/// A SwiftUI surface cannot subscribe to a merged publisher directly without
/// rebuilding it on every body pass, so this holds the subscription for the
/// life of the view and lets the view depend on exactly the inputs the status
/// item depends on.
@MainActor
final class MenuBarStripInputObserver: ObservableObject {
    @Published private(set) var generation = 0
    private var cancellables: Set<AnyCancellable> = []

    func start(environment: AppEnvironment) {
        guard cancellables.isEmpty else { return }
        Publishers.MergeMany(MenuBarStripResolver.inputPublishers(environment: environment))
            // The same 120 ms coalescing the status item uses: one refresh
            // publishes several of these back to back.
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.generation &+= 1 }
            .store(in: &cancellables)
    }
}

/// The composed strip, drawn in SwiftUI.
///
/// This is the editor's preview, and it consumes exactly the plan the status
/// item consumes — same blocks, same order, same colours, same truncation. It
/// is deliberately not an independent drawing of the same idea: the whole
/// reason the plan is a value in Core is so the preview cannot tell a
/// different story from the menu bar.
///
/// It does not resolve quotas, compute forecasts, or read settings. Everything
/// it needs arrives as a value, so re-rendering it while the user types costs
/// a layout pass and nothing else.
struct MenuBarStripView: View {
    let plan: MenuBarRenderPlan
    let quotas: [MenuBarQuotaSnapshot]
    let displayMode: DisplayMode
    /// The face the status item would draw this plan at.
    var baseFontSize: CGFloat = MenuBarStripMetrics.singleRowFontSize
    /// Draws the id'd block with a selection ring, so the editor's chip
    /// selection is visible in the preview too.
    var highlighted: UUID?

    /// Rows the strip actually draws — the same count the status item uses to
    /// pick its face and its glyph box.
    private var drawnRowCount: Int {
        plan.isTwoRow ? 2 : 1
    }

    var body: some View {
        Group {
            if plan.columns.isEmpty {
                Text("—")
                    .font(.system(size: baseFontSize, weight: .regular).monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else if plan.isTwoRow {
                // Columns side by side at the rasterizer's own spacing, each
                // cell centred inside the column — `twoRowImage` centres a
                // narrower cell inside the width its column earned, and a
                // preview that left-aligned it would show the user something
                // the menu bar will not draw.
                HStack(alignment: .center, spacing: MenuBarStripMetrics.twoRowColumnSpacing) {
                    ForEach(Array(plan.columns.enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .center, spacing: 0) {
                            rowView(column.top)
                            if let bottom = column.bottom { rowView(bottom) }
                        }
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(plan.columns.enumerated()), id: \.offset) { index, column in
                        if index > 0 { columnBoundary }
                        rowView(column.top)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            plan.spokenDescription.isEmpty
                ? L10n.MenuBar.composerPreviewEmpty
                : plan.spokenDescription
        )
    }

    /// What a one-row strip puts between two groups: the template's divider
    /// with the strip's own gap on each side, or just the gap.
    @ViewBuilder
    private var columnBoundary: some View {
        let gap = baseFontSize * plan.tokenSpacing * Self.spacingToPoints
        if let separator = plan.columnSeparator {
            Text(separator)
                .font(.system(size: baseFontSize, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.45))
                .fixedSize()
                .padding(.horizontal, gap)
        } else {
            Color.clear.frame(width: gap, height: 0)
        }
    }

    private func rowView(_ row: MenuBarRenderRow) -> some View {
        HStack(spacing: baseFontSize * plan.tokenSpacing * Self.spacingToPoints) {
            ForEach(row.tokens) { token in
                tokenView(token)
            }
        }
    }

    /// The plan states gaps as a multiplier on the base font size because the
    /// status item realizes them as a space glyph, which is the only thing the
    /// two-row canvas can carry. A stack has real point spacing, so convert
    /// with the width a system-font space actually occupies — close enough
    /// that the preview and the bar agree at a glance.
    private static let spacingToPoints: CGFloat = 0.28

    @ViewBuilder
    private func tokenView(_ token: MenuBarRenderedToken) -> some View {
        let size = max(4, baseFontSize * token.fontScale)
        let paint = MenuBarStripPalette.paint(
            for: token.color,
            quotas: quotas,
            displayMode: displayMode
        )
        Group {
            if let glyph = token.glyph {
                MenuBarStripGlyph(
                    glyph: glyph,
                    // Whatever the bar will use for this many rows, not a
                    // preview-only cap.
                    side: MenuBarStripMetrics.glyphSide(
                        fontSize: size,
                        rowCount: drawnRowCount
                    ),
                    paint: paint
                )
            } else if let text = token.text {
                Text(text)
                    .font(font(for: token, size: size))
                    .foregroundStyle(MenuBarStripPalette.color(paint))
                    .fixedSize()
            }
        }
        .padding(.horizontal, highlighted == token.id ? 2 : 0)
        .background {
            if highlighted == token.id {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.accentColor.opacity(0.28))
            }
        }
    }

    private func font(for token: MenuBarRenderedToken, size: CGFloat) -> Font {
        let weight: Font.Weight
        switch token.weight {
        case .regular: weight = .regular
        case .medium: weight = .medium
        case .semibold: weight = .semibold
        }
        let base = Font.system(size: size, weight: weight)
        return token.monospacedDigits ? base.monospacedDigit() : base
    }
}

/// A glyph inside the preview — a provider's brand mark or Vibe Bar's own —
/// tinted to match the block's paint and rasterized against the preview's own
/// colour scheme rather than the app's: a light-menu-bar preview has to show
/// the light-menu-bar glyph.
private struct MenuBarStripGlyph: View {
    @Environment(\.colorScheme) private var colorScheme
    let glyph: MenuBarRenderedToken.Glyph
    let side: CGFloat
    let paint: MenuBarStripPaint

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(MenuBarStripPalette.color(paint))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private var image: NSImage? {
        let size = NSSize(width: side, height: side)
        let tint = MenuBarStripPalette.nsColor(paint)
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        switch glyph {
        case let .provider(tool):
            return ProviderBrandIcon.image(for: tool, size: size, tint: tint, appearance: appearance)
        case .app:
            return ProviderBrandIcon.image(
                for: MenuBarItemKind.compact, size: size, tint: tint, appearance: appearance
            )
        }
    }

    private var fallbackSymbol: String {
        switch glyph {
        case let .provider(tool): return ProviderBrandIcon.fallbackSystemImage(for: tool)
        case .app: return ProviderBrandIcon.fallbackSystemImage(for: MenuBarItemKind.compact)
        }
    }
}

/// The strip shown twice, on a light and a dark menu-bar ground.
///
/// Both, always: a fixed colour is the one thing in the composer that can look
/// deliberate on one menu bar and be invisible on the other, and the user has
/// no way to check that without switching their whole system appearance.
struct MenuBarStripPreview: View {
    let plan: MenuBarRenderPlan
    let quotas: [MenuBarQuotaSnapshot]
    let displayMode: DisplayMode
    /// Which face the bar will use — see `MenuBarStripGeometry.face`.
    let template: MenuBarComposition.Template
    var highlighted: UUID?

    var body: some View {
        HStack(spacing: 8) {
            ground(scheme: .light)
            ground(scheme: .dark)
        }
    }

    private func ground(scheme: ColorScheme) -> some View {
        // The bar draws a one-row strip at the small system face and a
        // rasterized two-row strip at 9pt, then shrinks two rows that do not
        // fit. The preview does all three, or it is previewing a strip the
        // user will never see.
        let base = MenuBarStripMetrics.baseFontSize(
            template: template,
            rowCount: plan.isTwoRow ? 2 : 1
        )
        let fit = MenuBarStripMetrics.estimatedFitScale(plan: plan, baseFontSize: base)
        return MenuBarStripView(
            plan: plan,
            quotas: quotas,
            displayMode: displayMode,
            baseFontSize: base * fit,
            highlighted: highlighted
        )
        .environment(\.colorScheme, scheme)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                // A stand-in for a menu bar, not a card: the point is a light
                // and a dark ground to read the strip against.
                .fill(scheme == .dark ? Color.black.opacity(0.82) : Color.white.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            scheme == .dark ? L10n.MenuBar.composerPreviewDark : L10n.MenuBar.composerPreviewLight
        )
    }
}
