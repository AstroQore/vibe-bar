import AppKit
import VibeBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-braces: Info.plist already sets LSUIElement, but if we are
        // launched from `swift run` (no bundle), force accessory policy here.
        if Bundle.main.bundleIdentifier == nil
           || Bundle.main.bundleIdentifier?.isEmpty == true {
            NSApp.setActivationPolicy(.accessory)
        }

        let env = AppEnvironment()
        self.environment = env
        self.statusItem = StatusItemController(environment: env)

        SafeLog.info("Vibe Bar started")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        statusItem?.applicationWillTerminate()
        environment?.scheduler.stop()
        environment?.serviceStatus.stop()
        return .terminateNow
    }
}
