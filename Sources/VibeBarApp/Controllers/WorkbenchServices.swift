import Foundation
import VibeBarCore

/// Window-scoped state for the Workbench, built on first open.
///
/// The Workbench's page models are expensive enough to be worth keeping —
/// the usage page holds a whole query snapshot and can be polling — but
/// pointless for the menu-bar-only session that never opens the window. So
/// `AppEnvironment` holds this lazily, and the models inside it are lazy in
/// turn: opening the Workbench on Sessions never builds the usage queries.
///
/// The laziness is spelled out with explicit storage rather than `lazy var`
/// because something has to be able to ask "was this ever built?" without
/// building it: `stopBackgroundWork` runs when the window closes, and a
/// teardown that constructs the models it is tearing down (opening a SQLite
/// index on the way out, for a page the user never opened) would be worse
/// than the leak it fixes.
@MainActor
final class WorkbenchServices: ObservableObject {
    private let usageLedger: UsageEventLedger?
    private let costService: CostUsageService
    private let settingsStore: SettingsStore
    private let skillsService: SkillsService
    /// The app-wide session index, shared with the MCP surface exactly as
    /// `skillsService` is — see `SharedSessionIndex`. A closure, not the
    /// value: building it opens `session_index.sqlite3`, and only the
    /// Sessions page should be able to cause that.
    private let sessionIndex: () -> SharedSessionIndex

    private var usageStatsStorage: UsageStatsViewModel?
    private var sessionsStorage: SessionManagerModel?
    private var skillsStorage: SkillsManagerModel?

    init(
        usageLedger: UsageEventLedger?,
        costService: CostUsageService,
        settingsStore: SettingsStore,
        skillsService: SkillsService,
        sessionIndex: @escaping () -> SharedSessionIndex
    ) {
        self.usageLedger = usageLedger
        self.costService = costService
        self.settingsStore = settingsStore
        self.skillsService = skillsService
        self.sessionIndex = sessionIndex
    }

    var usageStats: UsageStatsViewModel {
        if let usageStatsStorage { return usageStatsStorage }
        let model = UsageStatsViewModel(ledger: usageLedger, costService: costService)
        usageStatsStorage = model
        return model
    }

    var sessions: SessionManagerModel {
        if let sessionsStorage { return sessionsStorage }
        let model = SessionManagerModel(settingsStore: settingsStore, index: sessionIndex())
        sessionsStorage = model
        return model
    }

    /// Lazy for the same reason as the usage page, and more so: building it
    /// opens `~/.vibebar/skills.json` and, on first activation, walks every
    /// agent CLI's skills directory. The service behind it is the app-wide
    /// one, shared with MCP's `skills.install`.
    var skills: SkillsManagerModel {
        if let skillsStorage { return skillsStorage }
        let model = SkillsManagerModel(settingsStore: settingsStore, service: skillsService)
        skillsStorage = model
        return model
    }

    /// Wind down anything a closed window left running. The models stay, so
    /// re-opening is still instant and `activate()` restarts what it needs.
    func stopBackgroundWork() {
        usageStatsStorage?.stop()
        sessionsStorage?.stop()
    }
}
