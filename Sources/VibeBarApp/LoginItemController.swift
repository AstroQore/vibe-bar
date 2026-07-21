import Foundation
import ServiceManagement

@MainActor
enum LoginItemController {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// `.requiresApproval` means the login item was successfully requested
    /// and is waiting on the user in System Settings. Treat it as on in the
    /// UI so opening Settings does not erase the saved request.
    static var isRequestedOrEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard status != .enabled, status != .requiresApproval else { return }
            try SMAppService.mainApp.register()
        } else {
            guard status == .enabled || status == .requiresApproval else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// Reconcile the persisted user choice with macOS on every launch. This
    /// repairs registrations lost when a locally built app bundle is replaced
    /// while keeping `.requiresApproval` intact for the user to approve.
    static func reconcileDesiredState(_ enabled: Bool) throws {
        try setEnabled(enabled)
    }

    static var statusText: String {
        switch status {
        case .enabled:
            return "Enabled in macOS Login Items."
        case .notRegistered:
            return "Off."
        case .requiresApproval:
            return "Waiting for approval in System Settings > Login Items."
        case .notFound:
            return "Unavailable for this build. Launch the packaged app bundle first."
        @unknown default:
            return "Login item status is unknown."
        }
    }
}
