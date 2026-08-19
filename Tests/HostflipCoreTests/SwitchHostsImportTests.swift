import Foundation
import HostflipCore
import XCTest

/// The SwitchHosts import (#74, ADR-0013): the mapping engine over the intermediate model,
/// the v4 PotDb directory reader, and the two end to end. Directory fixtures are desensitized
/// samples of real v4 data shapes (nested folders, remote rules, combined rules).
final class SwitchHostsImportTests: XCTestCase {

    // MARK: - Mapping: structure

    func testFoldersFlattenToPathNamedGroupsAndLooseItemsLandStandalone() {
        let data = SwitchHostsData(items: [
            SwitchHostsItem(id: "a", title: "dev", content: "127.0.0.1 dev.example.test\n", kind: .local),
            SwitchHostsItem(id: "f1", title: "Staging", kind: .folder(isSingleSelection: true, children: [
                SwitchHostsItem(id: "b", title: "pre1", content: "10.0.2.1 app.example.test\n", kind: .local),
                SwitchHostsItem(id: "f2", title: "Frontend", kind: .folder(isSingleSelection: true, children: [
                    SwitchHostsItem(id: "c", title: "web1", content: "10.0.2.2 web.example.test\n", kind: .local)
                ])),
                SwitchHostsItem(id: "d", title: "pre2", content: "10.0.2.3 app.example.test\n", kind: .local),
            ])),
        ])

        let plan = SwitchHostsMapper.plan(for: data)

        XCTAssertEqual(plan.snapshot, ExportSnapshot(
            standaloneProfiles: [.init(name: "dev", content: "127.0.0.1 dev.example.test\n")],
            groups: [
                .init(name: "Staging", profiles: [
                    .init(name: "pre1", content: "10.0.2.1 app.example.test\n"),
                    .init(name: "pre2", content: "10.0.2.3 app.example.test\n"),
                ]),
                .init(name: "Staging / Frontend", profiles: [
                    .init(name: "web1", content: "10.0.2.2 web.example.test\n")
                ]),
            ]
        ))
        XCTAssertEqual(plan.summary.profileCount, 4)
        XCTAssertEqual(plan.summary.groupCount, 2)
        XCTAssertEqual(plan.summary.exclusivityTightenedGroups, [])
    }

    func testFolderOfOnlySubfoldersAddsNoGroupOfItsOwn() {
        let data = SwitchHostsData(items: [
            SwitchHostsItem(id: "f1", title: "Outer", kind: .folder(isSingleSelection: true, children: [
                SwitchHostsItem(id: "f2", title: "Inner", kind: .folder(isSingleSelection: true, children: [
                    SwitchHostsItem(id: "a", title: "only", content: "x\n", kind: .local)
                ]))
            ]))
        ])

        let plan = SwitchHostsMapper.plan(for: data)

        XCTAssertEqual(plan.snapshot.groups.map(\.name), ["Outer / Inner"])
        XCTAssertEqual(plan.summary.groupCount, 1)
    }

    func testNonSingleSelectionFolderBecomesAGroupAndReportsTheTightening() {
        let stacking = SwitchHostsData(items: [
            SwitchHostsItem(id: "f1", title: "Overrides", kind: .folder(isSingleSelection: false, children: [
                SwitchHostsItem(id: "a", title: "one", content: "a\n", kind: .local),
                SwitchHostsItem(id: "b", title: "two", content: "b\n", kind: .local),
            ]))
        ])
        XCTAssertEqual(
            SwitchHostsMapper.plan(for: stacking).summary.exclusivityTightenedGroups,
            ["Overrides"]
        )

        // ADR-0013 wants every non-single folder disclosed, member count regardless.
        let singleMember = SwitchHostsData(items: [
            SwitchHostsItem(id: "f1", title: "Overrides", kind: .folder(isSingleSelection: false, children: [
                SwitchHostsItem(id: "a", title: "one", content: "a\n", kind: .local)
            ]))
        ])
        XCTAssertEqual(
            SwitchHostsMapper.plan(for: singleMember).summary.exclusivityTightenedGroups,
            ["Overrides"]
        )
    }

    func testSystemEntriesAreSkippedAndCounted() {
        let data = SwitchHostsData(items: [
            SwitchHostsItem(id: "0", title: "system", content: "127.0.0.1 localhost\n", isSystem: true, kind: .local),
            SwitchHostsItem(id: "a", title: "dev", content: "x\n", kind: .local),
        ])

        let plan = SwitchHostsMapper.plan(for: data)

        XCTAssertEqual(plan.snapshot.standaloneProfiles.map(\.name), ["dev"])
        XCTAssertEqual(plan.summary.skippedSystemEntryCount, 1)
        XCTAssertEqual(plan.summary.profileCount, 1)
    }

    func testHistoryAndTrashCountsPassThroughToTheSummary() {
        let data = SwitchHostsData(
            items: [SwitchHostsItem(id: "a", title: "dev", content: "x\n", kind: .local)],
            historyEntryCount: 23,
            trashedItemCount: 2
        )

        let summary = SwitchHostsMapper.plan(for: data).summary

        XCTAssertEqual(summary.skippedHistoryEntryCount, 23)
        XCTAssertEqual(summary.skippedTrashedItemCount, 2)
    }

    func testBlankTitlesFallBackToUntitled() {
        let data = SwitchHostsData(items: [
            SwitchHostsItem(id: "a", title: "  ", content: "x\n", kind: .local),
            SwitchHostsItem(id: "f", title: "", kind: .folder(isSingleSelection: true, children: [
                SwitchHostsItem(id: "b", title: "member", content: "y\n", kind: .local)
            ])),
        ])

        let snapshot = SwitchHostsMapper.plan(for: data).snapshot

        XCTAssertEqual(snapshot.standaloneProfiles.map(\.name), ["Untitled"])
        XCTAssertEqual(snapshot.groups.map(\.name), ["Untitled"])
    }

    func testLocalContentWhoseFirstLineIsARemoteHeaderIsEscaped() {
        let data = SwitchHostsData(items: [
            SwitchHostsItem(
                id: "a",
                title: "sneaky",
                content: "#!hostflip-remote https://x.example.test/a interval=1h\n0.0.0.0 ads.example.test\n",
                kind: .local
            )
        ])

        let plan = SwitchHostsMapper.plan(for: data)

        let imported = plan.snapshot.standaloneProfiles[0].content
        XCTAssertNil(RemoteHeader.parse(fromContent: imported), "a local rule must stay local")
        XCTAssertEqual(plan.summary.remoteProfiles, [])
    }

    // MARK: - Mapping: remote rules

    func testRemoteRuleBecomesARemoteProfileOverItsCachedContent() {
        let data = SwitchHostsData(items: [
            SwitchHostsItem(
                id: "r",
                title: "Team Blocklist",
                content: "0.0.0.0 tracker.example.test\n",
                kind: .remote(urlString: "https://rules.example.test/list.hosts", refreshIntervalSeconds: 86400)
            )
        ])

        let plan = SwitchHostsMapper.plan(for: data)

        XCTAssertEqual(plan.snapshot.standaloneProfiles, [.init(
            name: "Team Blocklist",
            content: "#!hostflip-remote https://rules.example.test/list.hosts interval=24h\n"
                + "0.0.0.0 tracker.example.test\n"
        )])
        XCTAssertEqual(plan.summary.remoteProfiles, [.init(
            profileName: "Team Blocklist",
            sourceURL: "https://rules.example.test/list.hosts",
            interval: .twentyFourHours
        )])
    }

    func testRefreshIntervalsMapToTheNearestPresetThatFetchesAtLeastAsOften() {
        func mapped(_ seconds: Int?) -> (interval: RemoteHeader.RefreshInterval, isAdjusted: Bool) {
            SwitchHostsMapper.refreshInterval(forSeconds: seconds)
        }
        XCTAssertEqual(mapped(nil).interval, .manual)
        XCTAssertEqual(mapped(0).interval, .manual)
        XCTAssertFalse(mapped(0).isAdjusted)
        XCTAssertEqual(mapped(3600).interval, .oneHour)
        XCTAssertFalse(mapped(3600).isAdjusted)
        XCTAssertEqual(mapped(1800).interval, .oneHour)
        XCTAssertTrue(mapped(1800).isAdjusted)
        XCTAssertEqual(mapped(21600).interval, .sixHours)
        XCTAssertFalse(mapped(21600).isAdjusted)
        // 2h has no exact preset; 6h would silently slow it down, so it rounds down to 1h.
        XCTAssertEqual(mapped(7200).interval, .oneHour)
        XCTAssertTrue(mapped(7200).isAdjusted)
        XCTAssertEqual(mapped(43200).interval, .sixHours)
        XCTAssertTrue(mapped(43200).isAdjusted)
        XCTAssertEqual(mapped(86400).interval, .twentyFourHours)
        XCTAssertFalse(mapped(86400).isAdjusted)
        XCTAssertEqual(mapped(604800).interval, .twentyFourHours)
        XCTAssertTrue(mapped(604800).isAdjusted)
    }

    func testAdjustedIntervalsAreReportedOnTheRemoteProfile() {
        let data = SwitchHostsData(items: [
            SwitchHostsItem(
                id: "r",
                title: "Weekly",
                content: "",
                kind: .remote(urlString: "https://rules.example.test/w.hosts", refreshIntervalSeconds: 604800)
            )
        ])

        let remoteProfiles = SwitchHostsMapper.plan(for: data).summary.remoteProfiles

        XCTAssertEqual(remoteProfiles, [.init(
            profileName: "Weekly",
            sourceURL: "https://rules.example.test/w.hosts",
            interval: .twentyFourHours,
            adjustedFromSeconds: 604800
        )])
    }

    func testNonHTTPSRemoteRuleImportsAsLocalAndIsReported() {
        let data = SwitchHostsData(items: [
            SwitchHostsItem(
                id: "r",
                title: "Intranet Feed",
                content: "10.0.0.1 feed.example.test\n",
                kind: .remote(urlString: "http://feed.example.test/rules", refreshIntervalSeconds: 3600)
            )
        ])

        let plan = SwitchHostsMapper.plan(for: data)

        XCTAssertEqual(plan.snapshot.standaloneProfiles, [.init(
            name: "Intranet Feed",
            content: "10.0.0.1 feed.example.test\n"
        )])
        XCTAssertEqual(plan.summary.remoteProfiles, [])
        XCTAssertEqual(plan.summary.downgradedRemotes, [.init(
            profileName: "Intranet Feed",
            urlString: "http://feed.example.test/rules"
        )])
    }

    // MARK: - Mapping: combined rules

    func testCombinedRuleExpandsMembersInIncludeOrderAndIsReportedFrozen() {
        let data = SwitchHostsData(items: [
            SwitchHostsItem(id: "a", title: "one", content: "1.1.1.1 a.example.test\n", kind: .local),
            SwitchHostsItem(id: "f", title: "F", kind: .folder(isSingleSelection: true, children: [
                SwitchHostsItem(
                    id: "r",
                    title: "cached remote",
                    content: "2.2.2.2 b.example.test\n",
                    kind: .remote(urlString: "https://x.example.test/r", refreshIntervalSeconds: 0)
                )
            ])),
            SwitchHostsItem(id: "c", title: "combo", kind: .combined(memberIDs: ["r", "missing", "a"])),
        ])

        let plan = SwitchHostsMapper.plan(for: data)

        let combo = plan.snapshot.standaloneProfiles.first { $0.name == "combo" }
        XCTAssertEqual(combo?.content, "2.2.2.2 b.example.test\n\n1.1.1.1 a.example.test\n")
        XCTAssertEqual(plan.summary.frozenCombinedProfiles, ["combo"])
    }

    func testCombinedRuleCyclesExpandEachMemberOnce() {
        let data = SwitchHostsData(items: [
            SwitchHostsItem(id: "c1", title: "combo1", kind: .combined(memberIDs: ["c2", "a"])),
            SwitchHostsItem(id: "c2", title: "combo2", kind: .combined(memberIDs: ["c1", "a"])),
            SwitchHostsItem(id: "a", title: "leaf", content: "x\n", kind: .local),
        ])

        let snapshot = SwitchHostsMapper.plan(for: data).snapshot

        let combo1 = snapshot.standaloneProfiles.first { $0.name == "combo1" }
        // c1 → c2 → (c1 already visited, skipped) → leaf, then c1's own leaf.
        XCTAssertEqual(combo1?.content, "x\n\nx\n")
    }

    // MARK: - v4 directory reading

    func testReadsANestedFolderDirectoryEndToEnd() throws {
        let root = try writeV4Fixture(
            tree: Self.nestedFoldersTree,
            hostsRecords: [
                "1": #"{"id": "aaaa", "content": "127.0.0.1 dev.example.test\n", "_id": "1"}"#,
                "2": #"{"id": "bbbb", "content": "10.0.2.1 app.example.test\n", "_id": "2"}"#,
                "3": #"{"id": "cccc", "content": "10.0.2.2 web.example.test\n", "_id": "3"}"#,
            ],
            hostsIDs: #"["1", null, "2", "3"]"#,
            historyIDs: #"["7", "8", null]"#,
            trashcan: #"[{"data": {"id": "gone", "title": "old"}, "parent_id": null}]"#
        )

        let plan = SwitchHostsMapper.plan(for: try SwitchHostsV4Reader.read(at: root))

        XCTAssertEqual(plan.snapshot.standaloneProfiles, [
            .init(name: "dev", content: "127.0.0.1 dev.example.test\n")
        ])
        XCTAssertEqual(plan.snapshot.groups, [
            .init(name: "预发环境", profiles: [.init(name: "pre1", content: "10.0.2.1 app.example.test\n")]),
            .init(name: "预发环境 / 前端", profiles: [.init(name: "web1", content: "10.0.2.2 web.example.test\n")]),
        ])
        XCTAssertEqual(plan.summary.skippedSystemEntryCount, 1)
        XCTAssertEqual(plan.summary.skippedHistoryEntryCount, 2)
        XCTAssertEqual(plan.summary.skippedTrashedItemCount, 1)

        // The plan applies through the ADR-0008 import path: appended, fresh IDs, all inactive.
        var model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost\n"),
            standaloneProfiles: [],
            groups: []
        )
        try model.importSnapshot(plan.snapshot)
        XCTAssertEqual(model.standaloneProfiles.map(\.name), ["dev"])
        XCTAssertEqual(model.groups.map(\.name), ["预发环境", "预发环境 / 前端"])
        XCTAssertEqual(model.activeProfileIDs, [])
    }

    func testReadsARemoteRuleWithURLAndInterval() throws {
        let root = try writeV4Fixture(
            tree: Self.remoteRuleTree,
            hostsRecords: [
                "1": #"{"id": "rrrr", "content": "0.0.0.0 tracker.example.test\n", "_id": "1"}"#
            ],
            hostsIDs: #"["1"]"#
        )

        let data = try SwitchHostsV4Reader.read(at: root)

        XCTAssertEqual(data.items, [SwitchHostsItem(
            id: "rrrr",
            title: "Team Blocklist",
            content: "0.0.0.0 tracker.example.test\n",
            kind: .remote(urlString: "https://rules.example.test/list.hosts", refreshIntervalSeconds: 604800)
        )])
    }

    func testReadsACombinedRuleWithItsIncludeOrder() throws {
        let root = try writeV4Fixture(
            tree: Self.combinedRuleTree,
            hostsRecords: [
                "1": #"{"id": "aaaa", "content": "1.1.1.1 a.example.test\n", "_id": "1"}"#,
                "2": #"{"id": "bbbb", "content": "2.2.2.2 b.example.test\n", "_id": "2"}"#,
            ],
            hostsIDs: #"["1", "2"]"#
        )

        let data = try SwitchHostsV4Reader.read(at: root)

        XCTAssertEqual(data.items.last, SwitchHostsItem(
            id: "cccc",
            title: "combo",
            content: "",
            kind: .combined(memberIDs: ["bbbb", "aaaa"])
        ))
    }

    func testEntriesWithoutATypeReadAsLocal() throws {
        let root = try writeV4Fixture(
            tree: #"[{"title": "dev", "id": "aaaa", "on": false}]"#,
            hostsRecords: [:],
            hostsIDs: "[]"
        )

        let data = try SwitchHostsV4Reader.read(at: root)

        XCTAssertEqual(data.items, [SwitchHostsItem(id: "aaaa", title: "dev", content: "", kind: .local)])
    }

    func testMissingTreeReadsAsDataNotFound() throws {
        let root = try makeTemporaryDirectory()

        XCTAssertThrowsError(try SwitchHostsV4Reader.read(at: root)) { error in
            XCTAssertEqual(error as? SwitchHostsImportError, .dataNotFound)
        }
    }

    func testACorruptCollectionRecordFailsTheWholeRead() throws {
        let root = try writeV4Fixture(
            tree: #"[{"title": "dev", "id": "aaaa", "on": false}]"#,
            hostsRecords: ["1": "not json"],
            hostsIDs: #"["1"]"#
        )

        XCTAssertThrowsError(try SwitchHostsV4Reader.read(at: root)) { error in
            XCTAssertEqual(
                error as? SwitchHostsImportError,
                .malformedData(file: "data/collection/hosts/data/1.json")
            )
        }
    }

    func testAListedButMissingCollectionRecordFailsTheWholeRead() throws {
        let root = try writeV4Fixture(
            tree: #"[{"title": "dev", "id": "aaaa", "on": false}]"#,
            hostsRecords: [:],
            hostsIDs: #"["1"]"#
        )

        XCTAssertThrowsError(try SwitchHostsV4Reader.read(at: root)) { error in
            XCTAssertEqual(
                error as? SwitchHostsImportError,
                .malformedData(file: "data/collection/hosts/data/1.json")
            )
        }
    }

    func testAnOutOfRangeRefreshIntervalClampsInsteadOfTrapping() throws {
        let root = try writeV4Fixture(
            tree: #"""
            [{"type": "remote", "title": "r", "id": "rrrr",
              "url": "https://rules.example.test/r", "refresh_interval": 1e100}]
            """#,
            hostsRecords: [:],
            hostsIDs: "[]"
        )

        let data = try SwitchHostsV4Reader.read(at: root)

        // The absurd cadence stays "very slow": 24h after mapping, disclosed as adjusted.
        XCTAssertEqual(data.items.first?.kind, .remote(
            urlString: "https://rules.example.test/r",
            refreshIntervalSeconds: .max
        ))
        let mapped = SwitchHostsMapper.refreshInterval(forSeconds: .max)
        XCTAssertEqual(mapped.interval, .twentyFourHours)
        XCTAssertTrue(mapped.isAdjusted)
    }

    func testAMissingOrDuplicateEntryIDFailsTheRead() throws {
        let missingID = try writeV4Fixture(
            tree: #"[{"title": "dev", "on": false}]"#,
            hostsRecords: [:],
            hostsIDs: "[]"
        )
        XCTAssertThrowsError(try SwitchHostsV4Reader.read(at: missingID)) { error in
            XCTAssertEqual(
                error as? SwitchHostsImportError,
                .malformedData(file: "data/list/tree.json")
            )
        }

        let duplicateID = try writeV4Fixture(
            tree: #"[{"title": "a", "id": "aaaa"}, {"title": "b", "id": "aaaa"}]"#,
            hostsRecords: [:],
            hostsIDs: "[]"
        )
        XCTAssertThrowsError(try SwitchHostsV4Reader.read(at: duplicateID)) { error in
            XCTAssertEqual(
                error as? SwitchHostsImportError,
                .malformedData(file: "data/list/tree.json")
            )
        }
    }

    func testAnUnknownEntryTypeFailsTheRead() throws {
        let root = try writeV4Fixture(
            tree: #"[{"title": "dev", "id": "aaaa", "type": "hologram"}]"#,
            hostsRecords: [:],
            hostsIDs: "[]"
        )

        XCTAssertThrowsError(try SwitchHostsV4Reader.read(at: root)) { error in
            XCTAssertEqual(
                error as? SwitchHostsImportError,
                .malformedData(file: "data/list/tree.json")
            )
        }
    }

    // MARK: - Fixtures

    /// Desensitized sample of a real v4 tree (#74): the system entry, a loose rule, and a
    /// single-selection folder with a rule and a nested subfolder — v4 writes `type` only
    /// for non-default entries, keeps `folder_mode`, and carries UI noise fields.
    private static let nestedFoldersTree = #"""
    [
     {"id": "0", "title": "系统 Hosts", "is_sys": true, "on": true},
     {"title": "dev", "id": "aaaa", "on": false},
     {"type": "folder", "title": "预发环境", "folder_mode": 1, "id": "ffff",
      "children": [
       {"title": "pre1", "id": "bbbb", "on": false},
       {"type": "folder", "title": "前端", "folder_mode": 1, "id": "gggg",
        "children": [{"title": "web1", "type": "local", "id": "cccc", "on": false}],
        "is_collapsed": false}
      ],
      "on": false, "is_collapsed": false}
    ]
    """#

    /// Desensitized sample of a v4 remote rule: URL, weekly refresh, cached content in the
    /// hosts collection, and the refresh bookkeeping fields v4 writes alongside.
    private static let remoteRuleTree = #"""
    [
     {"type": "remote", "title": "Team Blocklist", "id": "rrrr",
      "url": "https://rules.example.test/list.hosts", "refresh_interval": 604800,
      "last_refresh": "8/19/2026, 10:00:00 AM", "last_refresh_ms": 1787101200000, "on": false}
    ]
    """#

    /// Desensitized sample of a v4 combined rule: `include` lists member ids in combination order.
    private static let combinedRuleTree = #"""
    [
     {"title": "one", "id": "aaaa", "on": false},
     {"title": "two", "id": "bbbb", "on": false},
     {"type": "group", "title": "combo", "id": "cccc", "include": ["bbbb", "aaaa"], "on": false}
    ]
    """#

    /// Materializes a v4 PotDb directory: `data/list/tree.json`, the hosts collection
    /// (`ids.json` + one file per record), and optionally history ids and a trashcan list.
    private func writeV4Fixture(
        tree: String,
        hostsRecords: [String: String],
        hostsIDs: String,
        historyIDs: String? = nil,
        trashcan: String? = nil
    ) throws -> URL {
        let root = try makeTemporaryDirectory()
        let fileManager = FileManager.default
        let listDirectory = root.appendingPathComponent("data/list", isDirectory: true)
        let hostsDirectory = root.appendingPathComponent("data/collection/hosts/data", isDirectory: true)
        try fileManager.createDirectory(at: listDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: hostsDirectory, withIntermediateDirectories: true)
        try Data(tree.utf8).write(to: listDirectory.appendingPathComponent("tree.json"))
        try Data(hostsIDs.utf8).write(
            to: hostsDirectory.deletingLastPathComponent().appendingPathComponent("ids.json")
        )
        try Data(#"{"index": \#(hostsRecords.count)}"#.utf8).write(
            to: hostsDirectory.deletingLastPathComponent().appendingPathComponent("meta.json")
        )
        for (recordID, json) in hostsRecords {
            try Data(json.utf8).write(to: hostsDirectory.appendingPathComponent("\(recordID).json"))
        }
        if let historyIDs {
            let historyDirectory = root.appendingPathComponent("data/collection/history", isDirectory: true)
            try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
            try Data(historyIDs.utf8).write(to: historyDirectory.appendingPathComponent("ids.json"))
        }
        if let trashcan {
            try Data(trashcan.utf8).write(to: listDirectory.appendingPathComponent("trashcan.json"))
        }
        return root
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchhosts-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
