import Foundation

/// `AppSettings.sessionBodyIndexingEnabled`, readable from the session index
/// actor's executor.
///
/// The setting lives on the main actor and `SessionIndexService` does not, so
/// every owner of an index mirrors the value here rather than hopping mid-pass
/// or — worse — snapshotting it once at construction. Snapshotting is the bug
/// this type exists to prevent: the switch is a privacy control, so a scan
/// started after the user turned bodies off must see "off", whether it was the
/// Workbench or an agent over MCP that asked for it.
final class BodyIndexingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    var current: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
