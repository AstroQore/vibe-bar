import AppKit
import Darwin
import VibeBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handleRemoteCommandLine() { return }
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
        environment?.remoteProbeService.stop()
        CookieRefreshScheduler.shared.stop()
        return .terminateNow
    }

    private func handleRemoteCommandLine() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let commands = ["--remote-identity-descriptor", "--install-remote-provisioning"]
        let requested = commands.filter(arguments.contains)
        guard !requested.isEmpty else { return false }
        guard requested.count == 1,
              let command = requested.first,
              let index = arguments.firstIndex(of: command),
              arguments.indices.contains(index + 1)
        else {
            FileHandle.standardError.write(Data("invalid_remote_command\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
        let url = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        do {
            if command == "--remote-identity-descriptor" {
                try RemoteCoreConfigStore.writePublicDescriptor(to: url)
            } else {
                try RemoteCoreConfigStore.install(from: url)
            }
            FileHandle.standardOutput.write(Data("ok\n".utf8))
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            let code = (error as? RemoteSyncError)?.code ?? "remote_command_failed"
            FileHandle.standardError.write(Data((code + "\n").utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }
}
