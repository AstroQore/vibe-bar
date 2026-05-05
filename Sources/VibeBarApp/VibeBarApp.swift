import SwiftUI

@main
struct VibeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            // Keep an empty scene so SwiftUI doesn't insist on a window.
            EmptyView()
        }
    }
}
