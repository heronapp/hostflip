import XCTest
@testable import HostflipCore

final class MergedHostsTests: XCTestCase {
    func testOutputAppendsFencedBlockOrderedStandaloneProfilesThenGroups() throws {
        let blocker = Profile(id: .init("blocker"), name: "Blocker", content: "0.0.0.0 ads.example.com\n")
        let tracker = Profile(id: .init("tracker"), name: "Tracker", content: "0.0.0.0 tracker.example.com\n")
        let staging = Profile(id: .init("staging"), name: "Staging", content: "10.0.0.1 api.example.com\n")
        let production = Profile(id: .init("production"), name: "Production", content: "10.0.0.2 api.example.com\n")
        let proxy = Profile(id: .init("proxy"), name: "Proxy", content: "10.0.0.9 proxy.example.com\n")
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost\n"),
            standaloneProfiles: [blocker, tracker],
            groups: [
                Group(id: .init("environment"), name: "Environment", profiles: [staging, production]),
                Group(id: .init("network"), name: "Network", profiles: [proxy]),
            ],
            activeProfileIDs: [blocker.id, staging.id, proxy.id]
        )

        XCTAssertEqual(model.mergedHosts.content, """
        127.0.0.1 localhost

        # ══ hostflip:begin — delete through hostflip:end to remove ══
        # ── Blocker ──
        0.0.0.0 ads.example.com
        # ── Environment/Staging ──
        10.0.0.1 api.example.com
        # ── Network/Proxy ──
        10.0.0.9 proxy.example.com
        # ══ hostflip:end ══

        """)
    }

    func testPausedOutputIsExactlyBaseHostsWithNoCommentsAndKeepsActivationState() throws {
        let blocker = Profile(id: .init("blocker"), name: "Blocker", content: "0.0.0.0 ads.example.com\n")
        var model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost\n"),
            standaloneProfiles: [blocker],
            groups: [],
            activeProfileIDs: [blocker.id]
        )
        model.setPaused(true)

        // Byte-identical to the baseline: pausing (e.g. before uninstalling)
        // leaves a pristine file with no hostflip traces at all.
        XCTAssertEqual(model.mergedHosts.content, "127.0.0.1 localhost\n")
        XCTAssertEqual(model.activeProfileIDs, [blocker.id])
    }

    func testNothingActiveOutputsExactlyBaseHostsEvenWithoutTrailingNewline() throws {
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost"),
            standaloneProfiles: [],
            groups: []
        )

        // With no fence to follow, the baseline is not even newline-terminated.
        XCTAssertEqual(model.mergedHosts.content, "127.0.0.1 localhost")
    }

    func testContentWithoutTrailingNewlineIsTerminatedBeforeTheNextMarker() throws {
        let blocker = Profile(id: .init("blocker"), name: "Blocker", content: "0.0.0.0 ads.example.com")
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost"),
            standaloneProfiles: [blocker],
            groups: [],
            activeProfileIDs: [blocker.id]
        )

        XCTAssertEqual(model.mergedHosts.content, """
        127.0.0.1 localhost

        # ══ hostflip:begin — delete through hostflip:end to remove ══
        # ── Blocker ──
        0.0.0.0 ads.example.com
        # ══ hostflip:end ══

        """)
    }

    func testTrailingBlankLinesAndCarriageReturnLineEndingsArePreservedVerbatim() throws {
        let blank = Profile(id: .init("blank"), name: "Blank", content: "1.2.3.4 a.example.com\n\n\n")
        let windows = Profile(id: .init("windows"), name: "Windows", content: "5.6.7.8 b.example.com\r\n")
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost\n"),
            standaloneProfiles: [blank, windows],
            groups: [],
            activeProfileIDs: [blank.id, windows.id]
        )

        XCTAssertEqual(
            model.mergedHosts.content,
            "127.0.0.1 localhost\n"
                + "\n"
                + MergedHosts.appendedBlockBegin + "\n"
                + "# ── Blank ──\n"
                + "1.2.3.4 a.example.com\n\n\n"
                + "# ── Windows ──\n"
                + "5.6.7.8 b.example.com\r\n"
                + MergedHosts.appendedBlockEnd + "\n"
        )
    }

    func testEmptyContentProducesABareMarkerInsideTheFence() throws {
        let empty = Profile(id: .init("empty"), name: "Empty", content: "")
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: ""),
            standaloneProfiles: [empty],
            groups: [],
            activeProfileIDs: [empty.id]
        )

        XCTAssertEqual(model.mergedHosts.content, """

        # ══ hostflip:begin — delete through hostflip:end to remove ══
        # ── Empty ──
        # ══ hostflip:end ══

        """)
    }

    func testSameHostLinesAreNeitherDeduplicatedNorReordered() throws {
        let first = Profile(id: .init("first"), name: "First", content: "2.2.2.2 dup.example.com\n1.1.1.1 dup.example.com\n")
        let second = Profile(id: .init("second"), name: "Second", content: "2.2.2.2 dup.example.com\n")
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: "1.1.1.1 dup.example.com\n"),
            standaloneProfiles: [first, second],
            groups: [],
            activeProfileIDs: [first.id, second.id]
        )

        XCTAssertEqual(model.mergedHosts.content, """
        1.1.1.1 dup.example.com

        # ══ hostflip:begin — delete through hostflip:end to remove ══
        # ── First ──
        2.2.2.2 dup.example.com
        1.1.1.1 dup.example.com
        # ── Second ──
        2.2.2.2 dup.example.com
        # ══ hostflip:end ══

        """)
    }

    func testUnicodeGroupAndProfileNamesAppearVerbatimInMarkers() throws {
        let adBlock = Profile(id: .init("adblock"), name: "去广告🚫", content: "0.0.0.0 ads.example.com\n")
        let staging = Profile(id: .init("staging"), name: "预发 β", content: "10.0.0.1 api.example.com\n")
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost\n"),
            standaloneProfiles: [adBlock],
            groups: [Group(id: .init("environment"), name: "环境🌏", profiles: [staging])],
            activeProfileIDs: [adBlock.id, staging.id]
        )

        XCTAssertEqual(model.mergedHosts.content, """
        127.0.0.1 localhost

        # ══ hostflip:begin — delete through hostflip:end to remove ══
        # ── 去广告🚫 ──
        0.0.0.0 ads.example.com
        # ── 环境🌏/预发 β ──
        10.0.0.1 api.example.com
        # ══ hostflip:end ══

        """)
    }

    func testARemoteProfilesHeaderLineFlowsIntoTheMergedOutput() throws {
        // Q18 (ADR-0012): the Remote Header is ordinary first-line content, so the merge carries
        // it verbatim and the /etc/hosts block shows the Source URL for traceability.
        let remoteProfile = Profile(
            id: .init("remote-profile"),
            name: "GitHub520",
            content: "#!hostflip-remote https://example.com/hosts.txt interval=6h\n140.82.113.3 github.com\n"
        )
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost\n"),
            standaloneProfiles: [remoteProfile],
            groups: [],
            activeProfileIDs: [remoteProfile.id]
        )

        XCTAssertEqual(model.mergedHosts.content, """
        127.0.0.1 localhost

        # ══ hostflip:begin — delete through hostflip:end to remove ══
        # ── GitHub520 ──
        #!hostflip-remote https://example.com/hosts.txt interval=6h
        140.82.113.3 github.com
        # ══ hostflip:end ══

        """)
    }

    func testHashMatchesAKnownSHA256VectorComputedIndependently() throws {
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost\n"),
            standaloneProfiles: [],
            groups: []
        )

        // Fixed SHA-256 vector (UTF-8 bytes, lowercase hex) computed by an independent implementation;
        // a change in this value means the merge output or hash algorithm changed, which would invalidate every stored last-written hash.
        XCTAssertEqual(
            model.mergedHosts.hash,
            "081ef9d5367595d16e30b4b4549d9f43537320508b4ce0788963e10e4f808857"
        )
    }

    func testDifferentActivationStatesProduceDifferentHashes() throws {
        let blocker = Profile(id: .init("blocker"), name: "Blocker", content: "0.0.0.0 ads.example.com\n")
        var model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost\n"),
            standaloneProfiles: [blocker],
            groups: []
        )
        let inactiveHash = model.mergedHosts.hash

        try model.toggleProfile(blocker.id)

        XCTAssertNotEqual(model.mergedHosts.hash, inactiveHash)
    }
}
