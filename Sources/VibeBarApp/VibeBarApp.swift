import SwiftUI

/// Entry is `main.swift`, which handles `--mcp-stdio` before AppKit exists
/// and otherwise calls `VibeBarApp.main()`.
struct VibeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            // Keep an empty scene so SwiftUI doesn't insist on a window.
            EmptyView()
        }
    }
}
