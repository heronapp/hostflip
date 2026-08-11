import AppKit
import Observation
import ServiceManagement

/// Settings toggle behind SMAppService.mainApp (#37): registration state lives in
/// the system (visible and revocable in System Settings > Login Items), this store
/// only mirrors it. Default is off — a never-registered app reports .notRegistered.
@MainActor
@Observable
final class LaunchAtLoginStore {
    private(set) var isEnabled: Bool

    private let register: () throws -> Void
    private let unregister: () throws -> Void

    convenience init() {
        self.init(
            isEnabled: SMAppService.mainApp.status == .enabled,
            register: { try SMAppService.mainApp.register() },
            unregister: { try SMAppService.mainApp.unregister() }
        )
    }

    init(
        isEnabled: Bool,
        register: @escaping () throws -> Void,
        unregister: @escaping () throws -> Void
    ) {
        self.isEnabled = isEnabled
        self.register = register
        self.unregister = unregister
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            if enabled {
                try register()
            } else {
                try unregister()
            }
            isEnabled = enabled
        } catch {
            // Leave isEnabled untouched so the toggle snaps back to the system's truth.
        }
    }
}

/// Distinguishes a login-item launch from a user-initiated one (Finder, Spotlight, `open`):
/// launchd tags the opening Apple event with keyAELaunchedAsLogInItem.
enum LoginItemLaunch {
    static var isCurrent: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return isLoginItemLaunch(
            eventID: event.eventID,
            propDataEnumCode: event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        )
    }

    static func isLoginItemLaunch(eventID: AEEventID?, propDataEnumCode: OSType?) -> Bool {
        eventID == kAEOpenApplication && propDataEnumCode == keyAELaunchedAsLogInItem
    }
}
