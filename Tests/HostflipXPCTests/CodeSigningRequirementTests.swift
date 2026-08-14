import XCTest
@testable import HostflipXPC

final class CodeSigningRequirementTests: XCTestCase {
    func testBuildsDesignatedRequirementForSingleIdentifier() throws {
        let requirement = try CodeSigningRequirement.peerRequirement(
            identifiers: ["com.heronapp.hostflip.daemon"],
            teamID: "ABCDE12345"
        )

        XCTAssertEqual(
            requirement,
            #"identifier "com.heronapp.hostflip.daemon" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#
        )
    }

    func testBuildsAlternationRequirementForAppAndCLIIdentifiers() throws {
        let requirement = try CodeSigningRequirement.peerRequirement(
            identifiers: [ChannelIdentity.appBundleID, ChannelIdentity.cliIdentifier],
            teamID: "ABCDE12345"
        )

        XCTAssertEqual(
            requirement,
            #"(identifier "com.heronapp.hostflip" or identifier "com.heronapp.hostflip.cli") and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#
        )
    }

    func testRejectsEmptyIdentifierList() {
        XCTAssertThrowsError(
            try CodeSigningRequirement.peerRequirement(identifiers: [], teamID: "ABCDE12345")
        ) { error in
            XCTAssertEqual(error as? CodeSigningRequirementError, .invalidIdentifier(""))
        }
    }

    func testRejectsIdentifierWithCharactersOutsideBundleIDAlphabet() {
        for identifier in [#"a"b"#, "a\"", "a b", "", "a\n.b"] {
            XCTAssertThrowsError(
                try CodeSigningRequirement.peerRequirement(identifiers: [identifier], teamID: "ABCDE12345")
            ) { error in
                XCTAssertEqual(error as? CodeSigningRequirementError, .invalidIdentifier(identifier))
            }
        }
    }

    func testRejectsInvalidIdentifierAnywhereInTheList() {
        XCTAssertThrowsError(
            try CodeSigningRequirement.peerRequirement(
                identifiers: ["com.heronapp.hostflip", #"evil" or identifier "x"#],
                teamID: "ABCDE12345"
            )
        ) { error in
            XCTAssertEqual(
                error as? CodeSigningRequirementError,
                .invalidIdentifier(#"evil" or identifier "x"#)
            )
        }
    }

    func testRejectsMalformedTeamID() {
        for teamID in ["", "abcde12345", "ABCDE1234", "ABCDE123456", #"ABCDE1234""#] {
            XCTAssertThrowsError(
                try CodeSigningRequirement.peerRequirement(identifiers: ["com.heronapp.hostflip"], teamID: teamID)
            ) { error in
                XCTAssertEqual(error as? CodeSigningRequirementError, .invalidTeamID(teamID))
            }
        }
    }
}
