import AppKit
import Darwin
import VibeBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handleMCPStdioCommandLine() { return }
        if handleRemoteCommandLine() { return }
        // Belt-and-braces: Info.plist already sets LSUIElement, but if we are
        // launched from `swift run` (no bundle), force accessory policy here.
        if Bundle.main.bundleIdentifier == nil
           || Bundle.main.bundleIdentifier?.isEmpty == true {
            NSApp.setActivationPolicy(.accessory)
        }

        installMainMenuIfNeeded()

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

    /// Clicking the Dock icon — which only exists while the Workbench holds a
    /// Dock token — should bring that window back rather than do nothing. The
    /// Workbench is never created here: a Dock icon without a live Workbench
    /// means the window is mid-teardown, and resurrecting it would fight the
    /// close the user just asked for.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        environment?.frontWorkbenchIfOpen()
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
        environment?.scheduler.stop()
        environment?.serviceStatus.stop()
        environment?.remoteProbeService.stop()
        CookieRefreshScheduler.shared.stop()
        return .terminateNow
    }

    /// `--mcp-stdio`: be a plain stdio MCP server that forwards to the running
    /// app's socket, and nothing else.
    ///
    /// This runs before any UI is created, so the process installs no status
    /// item, opens no window, and builds no `AppEnvironment`. It never returns
    /// — the pump owns the rest of this process's life — but it still reports
    /// a `Bool` so the call site reads like `handleRemoteCommandLine()` above.
    private func handleMCPStdioCommandLine() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains(MCPStdioBridge.commandLineFlag) else {
            return false
        }
        // Belt and braces against the Dock or the app switcher noticing a
        // process that is really a pipe.
        NSApp.setActivationPolicy(.prohibited)
        let code = MCPStdioBridge.run(socketPath: MCPStdioBridge.socketPath())
        Darwin.exit(code)
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
