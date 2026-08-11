import SwiftUI
import XCTest
@testable import Hostflip
@testable import HostflipXPC

/// The passive helper status light. SMAppService reports `.notFound` for a
/// daemon that has simply never been registered (see
/// docs/helper-reregistration-verification.md step 1), so a fresh install must
/// present it as "not installed yet", never as a broken state — genuine
/// unavailability surfaces through switch feedback when a switch is attempted.
final class HelperStatusPresentationTests: XCTestCase {
    func testNeverRegisteredPresentsAsNotInstalledNotAsFailure() {
        let presentation = HelperStatusPresentation(.notFound)
        XCTAssertEqual(presentation.title, "Helper Not Installed")
        XCTAssertNotEqual(presentation.color, .red)
        XCTAssertFalse(presentation.description.localizedCaseInsensitiveContains("reinstall"))
        XCTAssertFalse(presentation.canRemove)
    }

    func testNotRegisteredPresentsTheSamePristineGuidance() {
        let notFound = HelperStatusPresentation(.notFound)
        let notRegistered = HelperStatusPresentation(.notRegistered)
        XCTAssertEqual(notRegistered.title, notFound.title)
        XCTAssertEqual(notRegistered.description, notFound.description)
    }

    func testEnabledPresentsAsReadyAndRemovable() {
        let presentation = HelperStatusPresentation(.enabled)
        XCTAssertEqual(presentation.title, "Helper Ready")
        XCTAssertTrue(presentation.canRemove)
    }

    func testRequiresApprovalIsActionableIntoSystemSettings() {
        let presentation = HelperStatusPresentation(.requiresApproval)
        XCTAssertEqual(presentation.title, "Helper Approval Required")
        XCTAssertTrue(presentation.canOpenApprovalSettings)
        XCTAssertTrue(presentation.canRemove)
    }
}
