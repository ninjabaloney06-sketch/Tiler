import Observation
import ServiceManagement

/// "Launch at login" through `SMAppService.mainApp`. The status is read from the system every
/// time `refresh()` runs (window shown or focused, after a toggle), never cached from settings.
/// Registration happens only when the user flips the toggle — nothing registers on its own.
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = .notRegistered
    /// Message of the last failed register/unregister, nil after a success.
    private(set) var lastError: String?

    init() {
        refresh()
    }

    /// On for `.enabled` and for `.requiresApproval` (registered, waiting for the user).
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setOn(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Short status note shown next to the toggle, nil when there is nothing to say.
    var note: String? {
        if let lastError { return lastError }
        return status == .requiresApproval ? "Approve Tiler in System Settings › General › Login Items" : nil
    }
}
