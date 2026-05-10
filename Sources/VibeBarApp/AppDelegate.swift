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

        CookieRefreshScheduler.shared.start()
        observeCookieRefreshes(environment: env)

        SafeLog.info("Vibe Bar started")
    }

    private func observeCookieRefreshes(environment: AppEnvironment) {
        NotificationCenter.default.addObserver(
            forName: .cookiesRefreshed,
            object: nil,
            queue: .main
        ) { [weak environment] notification in
            guard let environment,
                  let raw = notification.userInfo?["tool"] as? String,
                  let tool = ToolType(rawValue: raw),
                  let account = environment.account(for: tool) else { return }
            Task { _ = await environment.quotaService.refresh(account) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        statusItem?.applicationWillTerminate()
        environment?.scheduler.stop()
        environment?.serviceStatus.stop()
        CookieRefreshScheduler.shared.stop()
        return .terminateNow
    }
}
