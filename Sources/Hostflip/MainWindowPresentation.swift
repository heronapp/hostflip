import HostflipXPC

/// Pure presentation projection of the main window's observable state; centralizes status
/// priority so the title bar, banner, and sidebar don't each guess whether "selected"
/// means "actually active".
struct MainWindowPresentation: Equatable {
    enum Banner: Equatable {
        case paused
        case hostsDrift
        case approvalRequired
        case switchFeedback(SwitchFeedback)
        case backgroundSyncError(String)
    }

    let banner: Banner?
    let profilesAreEffective: Bool
    let activationControlsDisabled: Bool
    let showsEmptyState: Bool

    init(
        isPaused: Bool,
        hasHostsDrift: Bool,
        helperStatus: DaemonRegistrationStatus?,
        switchFeedback: SwitchFeedback?,
        backgroundSyncError: String?,
        profileCount: Int,
        isSwitching: Bool
    ) {
        if hasHostsDrift || switchFeedback == .hostsDrift {
            self.banner = .hostsDrift
        } else if let switchFeedback, switchFeedback != .merged {
            self.banner = .switchFeedback(switchFeedback)
        } else if let backgroundSyncError {
            self.banner = .backgroundSyncError(backgroundSyncError)
        } else if isPaused {
            self.banner = .paused
        } else if helperStatus == .requiresApproval {
            self.banner = .approvalRequired
        } else {
            self.banner = nil
        }
        self.profilesAreEffective = !isPaused
        self.activationControlsDisabled = isPaused || hasHostsDrift || isSwitching
        self.showsEmptyState = profileCount == 0
    }
}
