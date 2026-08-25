import HostflipXPC
import XCTest
@testable import Hostflip

final class MainWindowPresentationTests: XCTestCase {
    func testPausedStateKeepsSavedSelectionsVisibleButNotEffective() {
        let presentation = MainWindowPresentation(
            isPaused: true,
            hasHostsDrift: false,
            helperStatus: .enabled,
            switchFeedback: nil,
            backgroundSyncError: nil,
            profileCount: 2,
            isSwitching: false
        )

        XCTAssertEqual(presentation.banner, .paused)
        XCTAssertFalse(presentation.profilesAreEffective)
        XCTAssertTrue(presentation.activationControlsDisabled)
        XCTAssertTrue(presentation.activationControlsDimmed)
        XCTAssertFalse(presentation.showsEmptyState)
    }

    func testInFlightSwitchBlocksClicksWithoutDimmingControls() {
        let presentation = MainWindowPresentation(
            isPaused: false,
            hasHostsDrift: false,
            helperStatus: .enabled,
            switchFeedback: nil,
            backgroundSyncError: nil,
            profileCount: 2,
            isSwitching: true
        )

        XCTAssertTrue(presentation.activationControlsDisabled)
        XCTAssertFalse(presentation.activationControlsDimmed, "a transient switch must not flash the whole control column dimmed")
    }

    func testHostsDriftBlocksActivationAndTakesBannerPriority() {
        let presentation = MainWindowPresentation(
            isPaused: false,
            hasHostsDrift: true,
            helperStatus: .requiresApproval,
            switchFeedback: .merged,
            backgroundSyncError: "Background sync failed",
            profileCount: 2,
            isSwitching: false
        )

        XCTAssertEqual(presentation.banner, .hostsDrift)
        XCTAssertTrue(presentation.profilesAreEffective)
        XCTAssertTrue(presentation.activationControlsDisabled)
        XCTAssertTrue(presentation.activationControlsDimmed)
    }

    func testApprovalRequiredIsActionableWithoutDisablingLocalEditing() {
        let presentation = MainWindowPresentation(
            isPaused: false,
            hasHostsDrift: false,
            helperStatus: .requiresApproval,
            switchFeedback: nil,
            backgroundSyncError: nil,
            profileCount: 2,
            isSwitching: false
        )

        XCTAssertEqual(presentation.banner, .approvalRequired)
        XCTAssertTrue(presentation.profilesAreEffective)
        XCTAssertFalse(presentation.activationControlsDisabled)
    }

    func testApprovalFeedbackIsRetiredOnceTheHelperIsApproved() {
        let presentation = MainWindowPresentation(
            isPaused: false,
            hasHostsDrift: false,
            helperStatus: .enabled,
            switchFeedback: .needsApproval,
            backgroundSyncError: nil,
            profileCount: 2,
            isSwitching: false
        )

        XCTAssertNil(presentation.banner)
    }

    func testApprovalFeedbackStaysWhileApprovalIsPendingOrStatusIsUnknown() {
        for helperStatus in [DaemonRegistrationStatus.requiresApproval, nil] {
            let presentation = MainWindowPresentation(
                isPaused: false,
                hasHostsDrift: false,
                helperStatus: helperStatus,
                switchFeedback: .needsApproval,
                backgroundSyncError: nil,
                profileCount: 2,
                isSwitching: false
            )

            XCTAssertEqual(presentation.banner, .switchFeedback(.needsApproval), "helperStatus: \(String(describing: helperStatus))")
        }
    }

    func testStaleApprovalFeedbackDoesNotHideOtherSwitchFeedback() {
        let presentation = MainWindowPresentation(
            isPaused: false,
            hasHostsDrift: false,
            helperStatus: .enabled,
            switchFeedback: .unavailable,
            backgroundSyncError: nil,
            profileCount: 2,
            isSwitching: false
        )

        XCTAssertEqual(presentation.banner, .switchFeedback(.unavailable))
    }

    func testEmptyWorkspaceShowsCreationStateWithoutAWarningBanner() {
        let presentation = MainWindowPresentation(
            isPaused: false,
            hasHostsDrift: false,
            helperStatus: .notRegistered,
            switchFeedback: nil,
            backgroundSyncError: nil,
            profileCount: 0,
            isSwitching: false
        )

        XCTAssertNil(presentation.banner)
        XCTAssertTrue(presentation.showsEmptyState)
        XCTAssertFalse(presentation.activationControlsDisabled)
    }

    func testSwitchFeedbackIsPresentedAheadOfTheSteadyStateBanner() {
        let feedback = SwitchFeedback.failed("Could not update system hosts")
        let presentation = MainWindowPresentation(
            isPaused: true,
            hasHostsDrift: false,
            helperStatus: .enabled,
            switchFeedback: feedback,
            backgroundSyncError: "Background sync failed",
            profileCount: 2,
            isSwitching: false
        )

        XCTAssertEqual(presentation.banner, .switchFeedback(feedback))
    }

    func testSuccessfulSwitchDoesNotUseAWarningBanner() {
        let presentation = MainWindowPresentation(
            isPaused: false,
            hasHostsDrift: false,
            helperStatus: .enabled,
            switchFeedback: .merged,
            backgroundSyncError: nil,
            profileCount: 2,
            isSwitching: false
        )

        XCTAssertNil(presentation.banner)
    }

    func testBaseHostsReplacementUsesDedicatedBannerInsteadOfHostsUpdatedFeedback() {
        let presentation = MainWindowPresentation(
            isPaused: false,
            hasHostsDrift: false,
            helperStatus: .notRegistered,
            switchFeedback: .baseHostsReplaced,
            backgroundSyncError: nil,
            profileCount: 0,
            isSwitching: false
        )

        XCTAssertEqual(presentation.banner, .switchFeedback(.baseHostsReplaced))
    }

    func testBackgroundSyncErrorUsesBannerAheadOfPausedState() {
        let message = "Changes were saved locally, but system hosts could not be updated."
        let presentation = MainWindowPresentation(
            isPaused: true,
            hasHostsDrift: false,
            helperStatus: .enabled,
            switchFeedback: nil,
            backgroundSyncError: message,
            profileCount: 2,
            isSwitching: false
        )

        XCTAssertEqual(presentation.banner, .backgroundSyncError(message))
    }
}
