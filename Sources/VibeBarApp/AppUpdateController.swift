import Combine
import Foundation
import Sparkle
import VibeBarCore

/// Owns Sparkle's standard updater UI and exposes the small amount of state
/// needed by Vibe Bar's menu-bar and Settings surfaces.
@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var updateChannel: UpdateChannel

    private let bundle: Bundle
    private let isConfigured: Bool
    private var canCheckObservation: NSKeyValueObservation?

    private lazy var standardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: isConfigured,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    init(bundle: Bundle = .main, updateChannel: UpdateChannel = .main) {
        self.bundle = bundle
        self.updateChannel = updateChannel
        let hasExpectedBundleIdentifier = bundle.bundleIdentifier == "com.astroqore.VibeBar"
        let hasFeedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil
        self.isConfigured = hasExpectedBundleIdentifier && hasFeedURL
        super.init()

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
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
        guard let build = bundle.object(
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

    func setUpdateChannel(_ channel: UpdateChannel) {
        guard updateChannel != channel else { return }
        updateChannel = channel
        guard isConfigured else { return }
        standardUpdaterController.updater.resetUpdateCycleAfterShortDelay()
    }

    /// Main maps to Sparkle's untagged default channel. Dev adds preview
    /// entries while Sparkle continues to consider Main entries as well.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        updateChannel.additionalSparkleChannels
    }
}
