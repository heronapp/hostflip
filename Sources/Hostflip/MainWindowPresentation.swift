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
    /// Clicks on activation controls are ignored — includes the sub-second window
    /// while a switch is in flight.
    let activationControlsDisabled: Bool
    /// Activation controls draw dimmed — persistent blocks only (paused, drift);
    /// an in-flight switch must not flash every row's control.
    let activationControlsDimmed: Bool
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
        self.activationControlsDimmed = isPaused || hasHostsDrift
        self.showsEmptyState = profileCount == 0
    }
}
