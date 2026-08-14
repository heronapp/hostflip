import HostflipCore
import XCTest
@testable import HostflipCLI

final class ProfileResolverTests: XCTestCase {
    // MARK: - Bare name

    func testUniqueBareNameResolvesAStandaloneProfile() throws {
        let model = try makeModel(
            standalone: [("solo-id", "Solo")],
            groups: [("work-id", "Work", [("dev-id", "Dev")])]
        )

        let match = try ProfileResolver.resolve(.nameOrPath("Solo"), in: model)

        XCTAssertEqual(match.profile.id.rawValue, "solo-id")
        XCTAssertNil(match.groupName)
    }

    func testUniqueBareNameResolvesAGroupMember() throws {
        let model = try makeModel(
            standalone: [("solo-id", "Solo")],
            groups: [("work-id", "Work", [("dev-id", "Dev")])]
        )

        let match = try ProfileResolver.resolve(.nameOrPath("Dev"), in: model)

        XCTAssertEqual(match.profile.id.rawValue, "dev-id")
        XCTAssertEqual(match.groupName, "Work")
    }

    func testUnknownBareNameFailsWithNotFound() throws {
        let model = try makeModel(
            standalone: [("solo-id", "Solo")],
            groups: []
        )

        XCTAssertThrowsError(try ProfileResolver.resolve(.nameOrPath("Missing"), in: model)) {
            XCTAssertEqual($0 as? ProfileResolver.Failure, .notFound(reference: "Missing"))
        }
    }

    // MARK: - Ambiguity

    func testCrossGroupDuplicateNamesFailWithEveryCandidateInModelOrder() throws {
        let model = try makeModel(
            standalone: [],
            groups: [
                ("work-id", "Work", [("work-dev-id", "Dev")]),
                ("home-id", "Home", [("home-dev-id", "Dev")]),
            ]
        )

        XCTAssertThrowsError(try ProfileResolver.resolve(.nameOrPath("Dev"), in: model)) {
            XCTAssertEqual($0 as? ProfileResolver.Failure, .ambiguous(reference: "Dev", candidates: [
                .init(id: "work-dev-id", name: "Dev", group: "Work"),
                .init(id: "home-dev-id", name: "Dev", group: "Home"),
            ]))
        }
    }

    func testStandaloneAndGroupMemberDuplicateNamesFailWithBothCandidates() throws {
        let model = try makeModel(
            standalone: [("solo-dev-id", "Dev")],
            groups: [("work-id", "Work", [("work-dev-id", "Dev")])]
        )

        XCTAssertThrowsError(try ProfileResolver.resolve(.nameOrPath("Dev"), in: model)) {
            XCTAssertEqual($0 as? ProfileResolver.Failure, .ambiguous(reference: "Dev", candidates: [
                .init(id: "solo-dev-id", name: "Dev", group: nil),
                .init(id: "work-dev-id", name: "Dev", group: "Work"),
            ]))
        }
    }

    func testDuplicateNamesWithinOneGroupFailWithBothCandidates() throws {
        let model = try makeModel(
            standalone: [],
            groups: [("work-id", "Work", [("first-id", "Dev"), ("second-id", "Dev")])]
        )

        XCTAssertThrowsError(try ProfileResolver.resolve(.nameOrPath("Dev"), in: model)) {
            XCTAssertEqual($0 as? ProfileResolver.Failure, .ambiguous(reference: "Dev", candidates: [
                .init(id: "first-id", name: "Dev", group: "Work"),
                .init(id: "second-id", name: "Dev", group: "Work"),
            ]))
        }
    }

    // MARK: - group/profile path

    func testPathResolvesTheMemberOfTheNamedGroup() throws {
        let model = try makeModel(
            standalone: [("solo-dev-id", "Dev")],
            groups: [
                ("work-id", "Work", [("work-dev-id", "Dev")]),
                ("home-id", "Home", [("home-dev-id", "Dev")]),
            ]
        )

        let match = try ProfileResolver.resolve(.nameOrPath("Home/Dev"), in: model)

        XCTAssertEqual(match.profile.id.rawValue, "home-dev-id")
        XCTAssertEqual(match.groupName, "Home")
    }

    func testPathWithUnknownGroupOrProfileFailsWithNotFound() throws {
        let model = try makeModel(
            standalone: [],
            groups: [("work-id", "Work", [("dev-id", "Dev")])]
        )

        XCTAssertThrowsError(try ProfileResolver.resolve(.nameOrPath("Home/Dev"), in: model)) {
            XCTAssertEqual($0 as? ProfileResolver.Failure, .notFound(reference: "Home/Dev"))
        }
        XCTAssertThrowsError(try ProfileResolver.resolve(.nameOrPath("Work/Staging"), in: model)) {
            XCTAssertEqual($0 as? ProfileResolver.Failure, .notFound(reference: "Work/Staging"))
        }
    }

    func testPathAcrossDuplicateGroupNamesFailsWithBothCandidates() throws {
        let model = try makeModel(
            standalone: [],
            groups: [
                ("first-work-id", "Work", [("first-dev-id", "Dev")]),
                ("second-work-id", "Work", [("second-dev-id", "Dev")]),
            ]
        )

        XCTAssertThrowsError(try ProfileResolver.resolve(.nameOrPath("Work/Dev"), in: model)) {
            XCTAssertEqual($0 as? ProfileResolver.Failure, .ambiguous(reference: "Work/Dev", candidates: [
                .init(id: "first-dev-id", name: "Dev", group: "Work"),
                .init(id: "second-dev-id", name: "Dev", group: "Work"),
            ]))
        }
    }

    func testSlashInAStandaloneNameReadsAsAPathSoOnlyIDReachesIt() throws {
        let model = try makeModel(
            standalone: [("tricky-id", "Work/Dev")],
            groups: []
        )

        // A reference containing a slash is always a path; the standalone profile literally
        // named "Work/Dev" is reachable only through --id.
        XCTAssertThrowsError(try ProfileResolver.resolve(.nameOrPath("Work/Dev"), in: model)) {
            XCTAssertEqual($0 as? ProfileResolver.Failure, .notFound(reference: "Work/Dev"))
        }
        XCTAssertEqual(
            try ProfileResolver.resolve(.id("tricky-id"), in: model).profile.name,
            "Work/Dev"
        )
    }

    func testPathSplitsOnTheFirstSlashSoMemberNamesMayContainSlashes() throws {
        let model = try makeModel(
            standalone: [],
            groups: [("work-id", "Work", [("tricky-id", "a/b")])]
        )

        let match = try ProfileResolver.resolve(.nameOrPath("Work/a/b"), in: model)

        XCTAssertEqual(match.profile.id.rawValue, "tricky-id")
    }

    // MARK: - --id

    func testIDResolvesAGroupMemberRegardlessOfDuplicateNames() throws {
        let model = try makeModel(
            standalone: [("solo-dev-id", "Dev")],
            groups: [("work-id", "Work", [("work-dev-id", "Dev")])]
        )

        let match = try ProfileResolver.resolve(.id("work-dev-id"), in: model)

        XCTAssertEqual(match.profile.id.rawValue, "work-dev-id")
        XCTAssertEqual(match.groupName, "Work")
    }

    func testUnknownIDFailsWithNotFound() throws {
        let model = try makeModel(
            standalone: [("solo-id", "Solo")],
            groups: []
        )

        XCTAssertThrowsError(try ProfileResolver.resolve(.id("missing-id"), in: model)) {
            XCTAssertEqual($0 as? ProfileResolver.Failure, .notFound(reference: "missing-id"))
        }
    }

    // MARK: - Helpers

    /// Builds a model from (id, name) tuples; content is irrelevant to addressing.
    private func makeModel(
        standalone: [(id: String, name: String)],
        groups: [(id: String, name: String, profiles: [(id: String, name: String)])]
    ) throws -> ActivationModel {
        try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost\n"),
            standaloneProfiles: standalone.map {
                Profile(id: .init($0.id), name: $0.name, content: "# \($0.id)")
            },
            groups: groups.map { group in
                Group(id: .init(group.id), name: group.name, profiles: group.profiles.map {
                    Profile(id: .init($0.id), name: $0.name, content: "# \($0.id)")
                })
            }
        )
    }
}
