import AppKit

/// The alert shown when `MenuBarBlockWatchdog` confirms macOS is hiding our
/// status item.
///
/// Deliberately explicit about *whose* bug this is. Someone hitting this sees
/// an app that appears not to launch, and the honest thing is to say plainly
/// that the app is running, that macOS is holding the icon back, and exactly
/// what to run — rather than let them reinstall and reboot in circles.
@MainActor
enum MenuBarBlockAlert {
    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"
    )

    /// - Parameter onSuppress: invoked when the user ticks "Don't check again".
    ///   The flag itself belongs to `AppSettings`, so persisting it stays with
    ///   the caller that owns the store.
    static func present(onSuppress: () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "macOS is hiding Vibe Bar's menu bar icon"
        alert.informativeText = """
            Vibe Bar is running, but macOS never placed its menu bar item. This \
            is a Control Center bug in macOS 26: an app you hid from the menu \
            bar holds a stale reference to Vibe Bar, and Control Center applies \
            that app's "hidden" setting to us. Vibe Bar's own toggle under \
            System Settings > Menu Bar already reads as on, so flipping it will \
            not help.

            "Copy Repair Command" puts a command on your clipboard that removes \
            only the stale reference — no app's show/hide setting changes. Run \
            it in Terminal, which needs Full Disk Access.
            """
        // The copy button is only offered when the script is actually locatable,
        // so it can never be a button that does nothing when clicked.
        let script = MenuBarAllowListRepair.scriptURL()
        var actions: [Action] = []
        if script != nil {
            alert.addButton(withTitle: "Copy Repair Command")
            actions.append(.copy)
        }
        alert.addButton(withTitle: "Open Menu Bar Settings")
        actions.append(.openSettings)
        alert.addButton(withTitle: "Dismiss")
        actions.append(.dismiss)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't check again"

        // An accessory app has no window to sheet from, and the alert has to
        // win attention from whatever the user is doing — the icon they are
        // looking for is missing, so there is nothing of ours to click.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if alert.suppressionButton?.state == .on {
            onSuppress()
        }

        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard actions.indices.contains(index) else { return }
        switch actions[index] {
        case .copy:
            if let script {
                copyRepairCommand(script)
            }
        case .openSettings:
            if let settingsURL {
                NSWorkspace.shared.open(settingsURL)
            }
        case .dismiss:
            break
        }
    }

    private enum Action {
        case copy
        case openSettings
        case dismiss
    }

    /// The command is built against this bundle's own copy of the script, so it
    /// stays correct whether Vibe Bar runs from /Applications, a build
    /// directory, or a worktree.
    private static func copyRepairCommand(_ script: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("python3 \"\(script.path)\" --apply", forType: .string)
    }

}
