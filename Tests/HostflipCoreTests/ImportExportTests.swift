import Foundation
import HostflipCore
import XCTest

final class ImportExportTests: XCTestCase {
    /// A workspace with base hosts, a standalone profile, and a group with one active member.
    private func makeModel() throws -> ActivationModel {
        try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost\n"),
            standaloneProfiles: [
                Profile(id: .init("s1"), name: "Ad Block", content: "0.0.0.0 ads.example\n")
            ],
            groups: [
                Group(id: .init("g1"), name: "Staging", profiles: [
                    Profile(id: .init("p1"), name: "API", content: "10.0.0.1 api.example\n"),
                    Profile(id: .init("p2"), name: "Web", content: "10.0.0.2 web.example\n"),
                ])
            ],
            activeProfileIDs: [.init("p1")]
        )
    }

    // MARK: - Export

    func testSnapshotCapturesProfilesAndGroupStructure() throws {
        let snapshot = ExportSnapshot(of: try makeModel())

        XCTAssertEqual(snapshot, ExportSnapshot(
            standaloneProfiles: [.init(name: "Ad Block", content: "0.0.0.0 ads.example\n")],
            groups: [.init(name: "Staging", profiles: [
                .init(name: "API", content: "10.0.0.1 api.example\n"),
                .init(name: "Web", content: "10.0.0.2 web.example\n"),
            ])]
        ))
    }

    func testEncodedSnapshotIsVersionedJSONCarryingOnlyNamesAndContents() throws {
        let data = try ExportSnapshot(of: makeModel()).encoded()

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(Set(object.keys), ["version", "standaloneProfiles", "groups"])
        let groups = try XCTUnwrap(object["groups"] as? [[String: Any]])
        XCTAssertEqual(Set(groups[0].keys), ["name", "profiles"])
        let profile = try XCTUnwrap((groups[0]["profiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(profile.keys), ["name", "content"])
    }

    // MARK: - Reading import files

    func testReadingAnExportedFileRoundTripsTheSnapshot() throws {
        let snapshot = ExportSnapshot(of: try makeModel())

        let read = try ImportReader.read(data: snapshot.encoded(), fileName: "hostflip-2026-08-12.json")

        XCTAssertEqual(read, .snapshot(snapshot))
    }

    func testPlainTextFileBecomesAProfileNamedAfterTheFile() throws {
        let read = try ImportReader.read(
            data: Data("10.0.0.3 db.example\n".utf8),
            fileName: "Staging DB.hosts"
        )

        XCTAssertEqual(read, .plainText(name: "Staging DB", content: "10.0.0.3 db.example\n"))
    }

    func testSnapshotFromANewerVersionIsRejected() {
        let data = Data(#"{"version": 2, "standaloneProfiles": [], "groups": []}"#.utf8)

        XCTAssertThrowsError(try ImportReader.read(data: data, fileName: "future.json")) { error in
            XCTAssertEqual(error as? ImportError, .unsupportedVersion(2))
        }
    }

    func testSnapshotWithNonPositiveVersionIsMalformedNotNewer() {
        let data = Data(#"{"version": 0, "standaloneProfiles": [], "groups": []}"#.utf8)

        XCTAssertThrowsError(try ImportReader.read(data: data, fileName: "zero.json")) { error in
            XCTAssertEqual(error as? ImportError, .malformedSnapshot)
        }
    }

    func testWhitespaceOnlyFileNameStemFallsBackToUntitled() throws {
        let read = try ImportReader.read(data: Data("# empty\n".utf8), fileName: "   .hosts")

        XCTAssertEqual(read, .plainText(name: "Untitled", content: "# empty\n"))
    }

    func testJSONWithWrongShapeIsRejectedRatherThanTreatedAsPlainText() {
        let data = Data(#"{"hosts": "127.0.0.1 localhost"}"#.utf8)

        XCTAssertThrowsError(try ImportReader.read(data: data, fileName: "weird.json")) { error in
            XCTAssertEqual(error as? ImportError, .malformedSnapshot)
        }
    }

    func testTopLevelJSONScalarIsRejectedRatherThanTreatedAsPlainText() {
        for scalar in ["42", "null", #""hello""#] {
            XCTAssertThrowsError(
                try ImportReader.read(data: Data(scalar.utf8), fileName: "scalar.json"),
                scalar
            ) { error in
                XCTAssertEqual(error as? ImportError, .malformedSnapshot, scalar)
            }
        }
    }

    func testBlankNameInSnapshotIsRejected() {
        let data = Data(
            #"{"version": 1, "standaloneProfiles": [{"name": "  ", "content": "x"}], "groups": []}"#.utf8
        )

        XCTAssertThrowsError(try ImportReader.read(data: data, fileName: "blank.json")) { error in
            XCTAssertEqual(error as? ImportError, .blankName)
        }
    }

    func testNonUTF8PlainTextIsRejected() {
        XCTAssertThrowsError(try ImportReader.read(data: Data([0xFF, 0xFE]), fileName: "binary")) { error in
            XCTAssertEqual(error as? ImportError, .invalidTextEncoding)
        }
    }

    // MARK: - Importing a snapshot into a model

    func testImportAppendsInactiveProfilesAndGroupsWithFreshIDs() throws {
        var model = try makeModel()
        let snapshot = ExportSnapshot(of: model)
        var minted = 0

        try model.importSnapshot(
            snapshot,
            makeProfileID: { minted += 1; return .init("new-p\(minted)") },
            makeGroupID: { .init("new-g") }
        )

        XCTAssertEqual(model.standaloneProfiles.map(\.name), ["Ad Block", "Ad Block"])
        XCTAssertEqual(model.standaloneProfiles.map(\.id.rawValue), ["s1", "new-p1"])
        XCTAssertEqual(model.groups.map(\.name), ["Staging", "Staging"])
        XCTAssertEqual(model.groups.map(\.id.rawValue), ["g1", "new-g"])
        XCTAssertEqual(model.groups[1].profiles.map(\.name), ["API", "Web"])
        XCTAssertEqual(model.groups[1].profiles.map(\.content), [
            "10.0.0.1 api.example\n", "10.0.0.2 web.example\n",
        ])
        // Existing content and active state stay untouched; every imported profile is inactive.
        XCTAssertEqual(model.groups[0].profiles.map(\.id.rawValue), ["p1", "p2"])
        XCTAssertEqual(model.activeProfileIDs, [.init("p1")])
        XCTAssertFalse(model.isPaused)
    }

    func testImportWithDefaultIDMintingProducesUniqueIDs() throws {
        var model = try makeModel()
        let snapshot = ExportSnapshot(of: model)

        try model.importSnapshot(snapshot)
        try model.importSnapshot(snapshot)

        let allIDs = (model.standaloneProfiles + model.groups.flatMap(\.profiles)).map(\.id)
        XCTAssertEqual(Set(allIDs).count, allIDs.count)
        XCTAssertEqual(allIDs.count, 9)
    }
}
