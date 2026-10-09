import Foundation
import VibeBarCore

/// A main-thread stall meter for measuring the Usage page against AGENTS.md
/// § 7's budget (≤ 16 ms on an interaction path), in demo mode only and only
/// when `VIBEBAR_USAGE_PROBE=1` is set.
///
/// A utility-priority timer posts a block to the main queue every 4 ms and
/// records how late it ran; the worst lateness in each second is the longest
/// time the main thread was busy with something else — a view update after a
/// snapshot landed, a hover, a scroll. One line per second with activity:
/// `VIBEBAR_USAGE_STALL max_ms=<n> samples=<n>`.
final class UsageStallProbe: @unchecked Sendable {
    static let shared = UsageStallProbe()

    static var isEnabled: Bool {
        DemoMode.isEnabled && ProcessInfo.processInfo.environment["VIBEBAR_USAGE_PROBE"] == "1"
    }

    private let queue = DispatchQueue(label: "vibebar.usage-stall-probe", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var windowMax: Double = 0
    private var samples = 0
    private var windowStart = Date()

    func start() {
        guard Self.isEnabled else { return }
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    private func tick() {
        let posted = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            let late = Double(DispatchTime.now().uptimeNanoseconds - posted) / 1_000_000
            self?.queue.async { self?.record(late) }
        }
        if Date().timeIntervalSince(windowStart) >= 1 {
            if windowMax >= 4 {
                let line = String(format: "VIBEBAR_USAGE_STALL max_ms=%.1f samples=%d\n", windowMax, samples)
                FileHandle.standardOutput.write(Data(line.utf8))
            }
            windowMax = 0
            samples = 0
            windowStart = Date()
        }
    }

    private func record(_ late: Double) {
        windowMax = max(windowMax, late)
        samples += 1
    }
}
