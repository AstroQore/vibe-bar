import AppKit
import VibeBarCore

@MainActor
enum MenuBarAllowListRepair {
    struct Outcome {
        enum Status { case changed, cleanNoop, failed }
        let status: Status
        let message: String

        var succeeded: Bool { status != .failed }
        var changed: Bool { status == .changed }
    }

    struct AuditOutcome {
        enum State { case clean, polluted, unavailable }
        let state: State
        let message: String
    }

    static func audit() async -> AuditOutcome {
        if DemoMode.isEnabled {
            return AuditOutcome(state: .clean, message: "Demo mode does not inspect the live allow-list")
        }
        guard let script = scriptURL() else {
            return AuditOutcome(state: .unavailable, message: "Bundled repair script missing")
        }
        do {
            let result = try await ProcessRunner.run(
                binary: "/usr/bin/python3",
                arguments: [script.path],
                timeout: 15,
                label: "menu bar allow-list audit"
            )
            let combined = [result.stdout, result.stderr].joined(separator: "\n")
            if combined.contains("Orphaned references to") {
                let owner = combined.split(separator: "\n")
                    .map(String.init)
                    .first { $0.contains("isAllowed=") }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return AuditOutcome(
                    state: .polluted,
                    message: owner.map { "Stale mapping: \($0)" } ?? "Stale cross-app mapping found"
                )
            }
            if result.terminationStatus == 0, combined.contains("allow-list is clean") {
                return AuditOutcome(state: .clean, message: "Control Center allow-list is clean")
            }
            return AuditOutcome(
                state: .unavailable,
                message: combined.localizedCaseInsensitiveContains("permission denied")
                    ? "Full Disk Access is required to inspect the allow-list"
                    : Self.lastUsefulLine(in: combined)
            )
        } catch {
            return AuditOutcome(state: .unavailable, message: error.localizedDescription)
        }
    }

    static func apply() async -> Outcome {
        guard !DemoMode.isEnabled else {
            return Outcome(status: .failed, message: "Repair is unavailable in demo mode.")
        }
        guard let script = scriptURL() else {
            return Outcome(status: .failed, message: "The bundled repair script is missing.")
        }
        do {
            let result = try await ProcessRunner.run(
                binary: "/usr/bin/python3",
                arguments: [script.path, "--apply"],
                timeout: 30,
                label: "menu bar allow-list repair"
            )
            let combined = [result.stdout, result.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result.terminationStatus == 0, combined.contains("Updated:") {
                return Outcome(
                    status: .changed,
                    message: combined.isEmpty
                        ? "Repair completed and Control Center restarted."
                        : Self.lastUsefulLine(in: combined)
                )
            }
            if result.terminationStatus == 0, combined.contains("allow-list is clean") {
                return Outcome(status: .cleanNoop, message: "Control Center allow-list was already clean.")
            }
            return Outcome(
                status: .failed,
                message: combined.localizedCaseInsensitiveContains("permission denied")
                    ? "Vibe Bar needs Full Disk Access to repair Control Center."
                    : (combined.isEmpty ? "Repair failed." : Self.lastUsefulLine(in: combined))
            )
        } catch {
            return Outcome(status: .failed, message: error.localizedDescription)
        }
    }

    static func copyCommand() -> Bool {
        guard !DemoMode.isEnabled else { return false }
        guard let script = scriptURL() else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString("python3 \"\(script.path)\" --apply", forType: .string)
    }

    static func scriptURL() -> URL? {
        if let bundled = Bundle.main.url(
            forResource: "fix_menu_bar_allowlist",
            withExtension: "py"
        ) {
            return bundled
        }
        var directory = Bundle.main.bundleURL.resolvingSymlinksInPath()
        for _ in 0..<6 {
            let candidate = directory
                .appendingPathComponent("Scripts", isDirectory: true)
                .appendingPathComponent("fix_menu_bar_allowlist.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func lastUsefulLine(in text: String) -> String {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
            ?? "Repair completed."
    }
}
