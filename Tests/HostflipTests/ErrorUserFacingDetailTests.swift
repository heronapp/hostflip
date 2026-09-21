import XCTest
import HostflipCore
import HostflipXPC
@testable import Hostflip

/// The detail interpolated into failure copy: a sentence where the error has one, never an
/// NSError dump or a bare channel case name.
final class ErrorUserFacingDetailTests: XCTestCase {
    func testCocoaErrorsReadAsTheirLocalizedSentence() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/hosts")
        XCTAssertThrowsError(try Data(contentsOf: url)) { error in
            XCTAssertEqual(error.userFacingDetail, error.localizedDescription)
            XCTAssertFalse(error.userFacingDetail.contains("Error Domain="), error.userFacingDetail)
        }
    }

    func testChannelErrorsUseTheirUserMessage() {
        let error: any Error = DaemonChannelError.unavailable
        XCTAssertEqual(error.userFacingDetail, DaemonChannelError.unavailable.userMessage)
    }

    func testOwnErrorEnumsKeepTheirCaseName() {
        XCTAssertEqual(WorkspaceError.notInitialized.userFacingDetail, "notInitialized")
    }

    func testDecodingErrorsKeepTheDescriptionThatLocatesTheFault() {
        struct Payload: Decodable { let version: Int }
        XCTAssertThrowsError(
            try JSONDecoder().decode(Payload.self, from: Data(#"{"version":"x"}"#.utf8))
        ) { error in
            XCTAssertTrue(error.userFacingDetail.contains("version"), error.userFacingDetail)
        }
    }
}
