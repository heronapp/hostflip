import ServiceManagement
import XCTest
@testable import HostflipXPC

final class DaemonRegistrationStatusTests: XCTestCase {
    func testMapsEachSMAppServiceStatus() {
        XCTAssertEqual(DaemonRegistrationStatus(SMAppService.Status.notRegistered), .notRegistered)
        XCTAssertEqual(DaemonRegistrationStatus(SMAppService.Status.enabled), .enabled)
        XCTAssertEqual(DaemonRegistrationStatus(SMAppService.Status.requiresApproval), .requiresApproval)
        XCTAssertEqual(DaemonRegistrationStatus(SMAppService.Status.notFound), .notFound)
    }
}
