import Foundation
import VibeBarCore

/// Window-scoped state for the Workbench, built on first open.
///
/// The Workbench's page models are expensive enough to be worth keeping —
/// the usage page holds a whole query snapshot and can be polling — but
/// pointless for the menu-bar-only session that never opens the window. So
/// `AppEnvironment` holds this lazily, and the models inside it are lazy in
/// turn: opening the Workbench on Sessions never builds the usage queries.
@MainActor
final class WorkbenchServices: ObservableObject {
    private let usageLedger: UsageEventLedger?
    private let costService: CostUsageService

    init(usageLedger: UsageEventLedger?, costService: CostUsageService) {
        self.usageLedger = usageLedger
        self.costService = costService
    }

    lazy var usageStats = UsageStatsViewModel(
        ledger: usageLedger,
        costService: costService
    )
}
