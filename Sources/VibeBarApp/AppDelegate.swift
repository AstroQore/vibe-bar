import AppKit
import Darwin
import VibeBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var statusItem: StatusItemController?
    private var demoPresenter: DemoPresenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handleRemoteCommandLine() { return }
        if let appearance = DemoMode.configuration?.appearance {
            // Before any window exists, so every surface — popover, mini
            // window, Workbench — inherits the pinned appearance.
            NSApp.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        }
        // Belt-and-braces: Info.plist already sets LSUIElement, but if we are
        // launched from `swift run` (no bundle), force accessory policy here.
        if Bundle.main.bundleIdentifier == nil
           || Bundle.main.bundleIdentifier?.isEmpty == true {
            NSApp.setActivationPolicy(.accessory)
        }

        installMainMenuIfNeeded()

        // Taken before the environment exists on purpose: constructing
        // `SettingsStore` materialises the defaults and writes `settings.json`
        // back, so from that point on the file always exists and can no
        // longer tell a fresh install from an upgrade. See `OnboardingGate`.
        let hadSettingsFile = FileManager.default.fileExists(atPath: VibeBarLocalStore.settingsURL.path)

        let env = AppEnvironment()
        self.environment = env
        if let demo = DemoMode.configuration {
            // A demo launch registers nothing with the system and refreshes
            // nothing; it builds the status item like any launch and then
            // opens the one surface it was asked to show.
            let statusItem = StatusItemController(environment: env)
            self.statusItem = statusItem
            let presenter = DemoPresenter(configuration: demo, environment: env, statusItem: statusItem)
            self.demoPresenter = presenter
            presenter.present()
            SafeLog.info("Vibe Bar started in demo mode")
            return
        }
        do {
            try LoginItemController.reconcileDesiredState(env.settingsStore.settings.launchAtLogin)
        } catch {
            SafeLog.warn("Reconciling launch at login failed: \(SafeLog.sanitize(error.localizedDescription))")
        }
        let statusItem = StatusItemController(environment: env)
        self.statusItem = statusItem
        env.presentPopoverHandler = { [weak statusItem] in
            statusItem?.presentCompactPopover()
        }
        presentOnboardingIfNeeded(environment: env, hadSettingsFile: hadSettingsFile)

        CookieRefreshScheduler.shared.start()
        observeCookieRefreshes(environment: env)

        // Session-index maintenance (excerpt trims, FTS merge, vacuum) runs
        // off the launch path: the Workbench may never open on a headless
        // MCP-only day, so launch is the trigger that always exists. The
        // compactor throttles itself to one completed pass per day.
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(60))
            await SessionIndexCompactor.standard.compactIfDue()
        }

        SafeLog.info("Vibe Bar started")
    }

    /// First real launch: open the setup assistant. The decision is
    /// `OnboardingGate`'s; this only supplies its signals — a quota cache on
    /// disk, and whether `settings.json` predated this launch's store — and
    /// records completion silently for an install that predates the key.
    /// CLI credentials on the Mac are not consulted: they say the user runs
    /// Codex or Claude, not that they have run Vibe Bar.
    private func presentOnboardingIfNeeded(environment env: AppEnvironment, hadSettingsFile: Bool) {
        switch OnboardingGate.decide(
            hasCompletedOnboarding: env.settingsStore.settings.hasCompletedOnboarding,
            hasQuotaCaches: OnboardingGate.hasQuotaCaches(),
            hadSettingsFile: hadSettingsFile
        ) {
        case .show:
            env.showOnboarding()
        case .markCompleted:
            env.settingsStore.settings.hasCompletedOnboarding = true
        case .skip:
            break
        }
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

    /// Clicking the Dock icon — which only exists while the Workbench or the
    /// setup assistant holds a Dock token — should bring that window back
    /// rather than do nothing. The assistant is asked first: on a first
    /// launch it is the only window, and a minimised one has no other way
    /// back. Neither window is ever created here: a Dock icon without a live
    /// window means it is mid-teardown, and resurrecting it would fight the
    /// close the user just asked for.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let environment else { return true }
        if !environment.frontOnboardingIfOpen() {
            environment.frontWorkbenchIfOpen()
        }
        return true
    }

    /// An `LSUIElement` app starts with no main menu, and without one the
    /// standard key equivalents never reach a window — ⌘W won't close the
    /// Workbench and ⌘C/⌘V won't work in its text fields. Installed once, and
    /// only when nothing else has claimed the menu bar.
    private func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private func appMenuItem() -> NSMenuItem {
        let appName = "Vibe Bar"
        let menu = NSMenu(title: appName)
        menu.addItem(NSMenuItem(
            title: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        return submenuItem(title: appName, submenu: menu)
    }

    private func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        return submenuItem(title: "File", submenu: menu)
    }

    private func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(NSMenuItem(
            title: "Undo",
            action: NSSelectorFromString("undo:"),
            keyEquivalent: "z"
        ))
        let redo = NSMenuItem(
            title: "Redo",
            action: NSSelectorFromString("redo:"),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        return submenuItem(title: "Edit", submenu: menu)
    }

    private func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        menu.addItem(NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        ))
        let item = submenuItem(title: "Window", submenu: menu)
        NSApp.windowsMenu = menu
        return item
    }

    private func submenuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        statusItem?.applicationWillTerminate()
        // First: the socket file has to go before anything else tears down, so
        // an agent connecting during shutdown gets a clean "not running"
        // rather than a connection to a half-stopped environment.
        environment?.mcp?.stop()
        environment?.settingsStore.flush()
        environment?.scheduler.stop()
        environment?.serviceStatus.stop()
        environment?.remoteProbeService.stop()
        CookieRefreshScheduler.shared.stop()
        return .terminateNow
    }

    /// Fold each timeline database's WAL back into its main file on the way
    /// out. Writes are committed per observation, so nothing is lost without
    /// this — but the `-wal` / `-shm` sidecars otherwise survive every launch,
    /// and `flushPendingWrites` had no production caller at all.
    ///
    /// Blocking briefly is the point: after this returns the process is gone.
    /// The stores are plain actors on the global pool, so the wait cannot
    /// deadlock against the main actor, and the timeout keeps a wedged
    /// checkpoint from holding up quit.
    func applicationWillTerminate(_ notification: Notification) {
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await UsageFillTimelineStore.shared.flushPendingWrites()
            await UsageForecastTimelineStore.shared.flushPendingWrites()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
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
