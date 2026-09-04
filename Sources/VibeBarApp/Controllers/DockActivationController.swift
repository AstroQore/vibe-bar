import AppKit

/// Owns the app's activation policy.
///
/// Vibe Bar ships as an `LSUIElement` agent, so it normally has no Dock icon
/// and no app menu. Full windows such as the Workbench need both, and they
/// need them to survive a second window opening and closing underneath. Each
/// surface holds a token while it is on screen; the Dock icon appears while at
/// least one token is held and disappears once the last one is released.
@MainActor
final class DockActivationController {
    static let shared = DockActivationController()

    enum DockToken: String, Hashable {
        case workbench
        case onboarding
        /// The layout studio outlives the Workbench that opened it, so it
        /// cannot borrow the Workbench's token: closing the Workbench would
        /// drop the app back to `.accessory` and leave a window on screen that
        /// nothing can bring back to the front.
        case layoutStudio
    }

    private var tokens: Set<DockToken> = []

    private init() {}

    func acquire(_ token: DockToken) {
        guard tokens.insert(token).inserted else { return }
        applyActivationPolicy()
    }

    func release(_ token: DockToken) {
        guard tokens.remove(token) != nil else { return }
        applyActivationPolicy()
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(tokens.isEmpty ? .accessory : .regular)
    }
}
