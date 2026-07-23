import Combine
import Foundation
import Sparkle

/// Owns Sparkle's standard updater UI and exposes the small amount of state
/// needed by Vibe Bar's menu-bar and Settings surfaces.
@MainActor
final class AppUpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    let standardUpdaterController: SPUStandardUpdaterController

    private let isConfigured: Bool
    private var canCheckObservation: NSKeyValueObservation?

    init(bundle: Bundle = .main) {
        let hasExpectedBundleIdentifier = bundle.bundleIdentifier == "com.astroqore.VibeBar"
        let hasFeedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil
        self.isConfigured = hasExpectedBundleIdentifier && hasFeedURL
        self.standardUpdaterController = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        guard isConfigured else { return }
        canCheckObservation = standardUpdaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    var currentVersionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
        guard let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String else {
            return version
        }
        return "\(version) (\(build))"
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        standardUpdaterController.checkForUpdates(nil)
    }
}
