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
        do {
            try LoginItemController.reconcileDesiredState(env.settingsStore.settings.launchAtLogin)
        } catch {
            SafeLog.warn("Reconciling launch at login failed: \(SafeLog.sanitize(error.localizedDescription))")
        }
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
            Task { @MainActor [weak environment] in
                guard let environment,
                      let raw = notification.userInfo?["tool"] as? String,
                      let tool = ToolType(rawValue: raw)
                else { return }

                if let instanceID = notification.userInfo?["instanceID"] as? String,
                   let account = environment.accountStore.account(forMiscProviderInstanceID: instanceID) {
                    _ = await environment.quotaService.refresh(account)
                } else if let account = environment.account(for: tool) {
                    _ = await environment.quotaService.refresh(account)
                }
            }
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
