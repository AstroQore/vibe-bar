import Foundation
import ServiceManagement

@MainActor
enum LoginItemController {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
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
