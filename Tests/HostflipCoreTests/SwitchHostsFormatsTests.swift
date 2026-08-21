import Foundation
import HostflipCore
import XCTest

/// The M2 surface of the SwitchHosts import (#75, ADR-0013): the v5 and v3 readers over
/// the shared intermediate model, the newest-generation-first format detection, and the
/// data directory discovery chain. Directory fixtures are desensitized samples of real
/// data shapes, nested folders and remote rules included.
final class SwitchHostsFormatsTests: XCTestCase {

    // MARK: - v5 reading

    func testReadsAV5DirectoryIntoTheSharedModel() throws {
        let root = try makeTemporaryDirectory()
        try writeV5Fixture(at: root)

        let data = try SwitchHostsV5Reader.read(at: root)

        XCTAssertEqual(data.items, [
            SwitchHostsItem(id: "sys0", title: "系统 Hosts", isSystem: true, kind: .local),
            SwitchHostsItem(id: "aaaa", title: "dev", content: "127.0.0.1 dev.example.test\n", kind: .local),
            SwitchHostsItem(id: "ffff", title: "预发环境", kind: .folder(isSingleSelection: true, children: [
                SwitchHostsItem(id: "bbbb", title: "pre1", content: "10.0.2.1 app.example.test\n", kind: .local),
                SwitchHostsItem(id: "gggg", title: "前端", kind: .folder(isSingleSelection: false, children: [
                    SwitchHostsItem(id: "cccc", title: "web1", content: "10.0.2.2 web.example.test\n", kind: .local)
                ])),
            ])),
            SwitchHostsItem(
                id: "rrrr",
                title: "Team Blocklist",
                content: "0.0.0.0 tracker.example.test\n",
                kind: .remote(urlString: "https://rules.example.test/list.hosts", refreshIntervalSeconds: 86400)
            ),
            SwitchHostsItem(id: "mmmm", title: "combo", kind: .combined(memberIDs: ["rrrr", "aaaa"])),
        ])
        XCTAssertEqual(data.historyEntryCount, 2)
        XCTAssertEqual(data.trashedItemCount, 1)
    }

    func testV5MapsThroughTheUnchangedEngine() throws {
        let root = try makeTemporaryDirectory()
        try writeV5Fixture(at: root)

        let plan = SwitchHostsMapper.plan(for: try SwitchHostsV5Reader.read(at: root))

        XCTAssertEqual(plan.summary.profileCount, 5)
        XCTAssertEqual(plan.snapshot.groups.map(\.name), ["预发环境", "预发环境 / 前端"])
        XCTAssertEqual(plan.summary.exclusivityTightenedGroups, ["预发环境 / 前端"])
        XCTAssertEqual(plan.summary.remoteProfiles.map(\.sourceURL), ["https://rules.example.test/list.hosts"])
        XCTAssertEqual(plan.summary.frozenCombinedProfiles, ["combo"])
        XCTAssertEqual(plan.summary.skippedSystemEntryCount, 1)
    }

    func testAV5NodeNamingAMissingContentFileFailsTheRead() throws {
        let root = try makeTemporaryDirectory()
        try write(
            #"{"format": "switchhosts-data", "schemaVersion": 1, "root": [{"id": "aaaa", "title": "dev", "type": "local", "on": false, "contentFile": "entries/aaaa.hosts"}]}"#,
            to: root.appendingPathComponent("manifest.json")
        )

        XCTAssertThrowsError(try SwitchHostsV5Reader.read(at: root)) { error in
            XCTAssertEqual(error as? SwitchHostsImportError, .malformedData(file: "entries/aaaa.hosts"))
        }
    }

    // MARK: - v3 reading

    func testReadsAV3DataFileIntoTheSharedModel() throws {
        let root = try makeTemporaryDirectory()
        try write(Self.v3Data, to: root.appendingPathComponent("data.json"))

        let data = try SwitchHostsV3Reader.read(at: root)

        XCTAssertEqual(data.items, [
            SwitchHostsItem(id: "aaaa", title: "dev", content: "127.0.0.1 dev.example.test\n", kind: .local),
            SwitchHostsItem(id: "ffff", title: "预发环境", kind: .folder(isSingleSelection: true, children: [
                SwitchHostsItem(id: "gggg", title: "前端", kind: .folder(isSingleSelection: false, children: [
                    SwitchHostsItem(id: "cccc", title: "web1", content: "10.0.2.2 web.example.test\n", kind: .local)
                ]))
            ])),
            SwitchHostsItem(
                id: "rrrr",
                title: "Team Blocklist",
                content: "0.0.0.0 tracker.example.test\n",
                // 24 hours → 86400 seconds; v3's one unit quirk.
                kind: .remote(urlString: "https://rules.example.test/list.hosts", refreshIntervalSeconds: 86400)
            ),
            SwitchHostsItem(id: "mmmm", title: "combo", kind: .combined(memberIDs: ["aaaa", "rrrr"])),
        ])
        XCTAssertEqual(data.historyEntryCount, 0)
        XCTAssertEqual(data.trashedItemCount, 0)
    }

    func testV3FractionalHoursConvertToSeconds() throws {
        let root = try makeTemporaryDirectory()
        try write(
            #"{"list": [{"id": "r", "title": "r", "where": "remote", "url": "https://x.example.test/r", "refresh_interval": 0.5, "on": false}], "version": [3, 5, 8, 0]}"#,
            to: root.appendingPathComponent("data.json")
        )

        let data = try SwitchHostsV3Reader.read(at: root)

        XCTAssertEqual(data.items.first?.kind, .remote(
            urlString: "https://x.example.test/r",
            refreshIntervalSeconds: 1800
        ))
    }

    func testAV3EntryWithoutAWhereFieldReadsAsLocal() throws {
        let root = try makeTemporaryDirectory()
        try write(
            #"{"list": [{"id": "aaaa", "title": "dev", "content": "x\n", "on": false}], "version": [3, 5, 8, 0]}"#,
            to: root.appendingPathComponent("data.json")
        )

        let data = try SwitchHostsV3Reader.read(at: root)

        XCTAssertEqual(data.items, [
            SwitchHostsItem(id: "aaaa", title: "dev", content: "x\n", kind: .local)
        ])
    }

    // MARK: - Format detection

    func testDetectionPrefersTheNewestGenerationAmongLeftovers() throws {
        let root = try makeTemporaryDirectory()
        try write(#"{"list": [], "version": [3, 5, 8, 0]}"#, to: root.appendingPathComponent("data.json"))
        XCTAssertEqual(SwitchHostsReader.detectFormat(at: root), .v3)

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("data/list"), withIntermediateDirectories: true
        )
        try write("[]", to: root.appendingPathComponent("data/list/tree.json"))
        XCTAssertEqual(SwitchHostsReader.detectFormat(at: root), .v4)

        try write(
            #"{"format": "switchhosts-data", "schemaVersion": 1, "root": []}"#,
            to: root.appendingPathComponent("manifest.json")
        )
        XCTAssertEqual(SwitchHostsReader.detectFormat(at: root), .v5)
    }

    func testDetectionReturnsNilForAnEmptyDirectory() throws {
        XCTAssertNil(SwitchHostsReader.detectFormat(at: try makeTemporaryDirectory()))
    }

    func testUnifiedReadResolvesASwitchHostsDataSubdirectory() throws {
        let wrapper = try makeTemporaryDirectory()
        let store = wrapper.appendingPathComponent("SwitchHosts.data", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try writeV5Fixture(at: store)

        let (data, format) = try SwitchHostsReader.read(at: wrapper)

        XCTAssertEqual(format, .v5)
        XCTAssertEqual(data.items.count, 5)
    }

    func testResolutionPrefersANestedV5StoreOverOlderLeftoversBeside() throws {
        let wrapper = try makeTemporaryDirectory()
        // v4 leftovers at the wrapper level…
        try FileManager.default.createDirectory(
            at: wrapper.appendingPathComponent("data/list"), withIntermediateDirectories: true
        )
        try write("[]", to: wrapper.appendingPathComponent("data/list/tree.json"))
        // …must not shadow the live v5 store nested underneath.
        let store = wrapper.appendingPathComponent("SwitchHosts.data", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try writeV5Fixture(at: store)

        let (data, format) = try SwitchHostsReader.read(at: wrapper)

        XCTAssertEqual(format, .v5)
        XCTAssertEqual(data.items.count, 5)
    }

    func testAV5ContentFileMustStayInsideTheDataRoot() throws {
        let root = try makeTemporaryDirectory()
        try write("outside\n", to: root.deletingLastPathComponent().appendingPathComponent("escape.hosts"))
        try write(
            #"{"format": "switchhosts-data", "schemaVersion": 1, "root": [{"id": "aaaa", "title": "dev", "type": "local", "contentFile": "../escape.hosts"}]}"#,
            to: root.appendingPathComponent("manifest.json")
        )

        XCTAssertThrowsError(try SwitchHostsV5Reader.read(at: root)) { error in
            XCTAssertEqual(error as? SwitchHostsImportError, .malformedData(file: "../escape.hosts"))
        }
    }

    func testAV3VersionFromAnotherMajorFailsTheRead() throws {
        let root = try makeTemporaryDirectory()
        try write(
            #"{"list": [{"id": "aaaa", "title": "dev", "content": "x\n"}], "version": [4, 0, 0, 0]}"#,
            to: root.appendingPathComponent("data.json")
        )

        XCTAssertThrowsError(try SwitchHostsV3Reader.read(at: root)) { error in
            XCTAssertEqual(error as? SwitchHostsImportError, .malformedData(file: "data.json"))
        }

        // The earliest 3.x files predate the version array: absent stays tolerated.
        let versionless = try makeTemporaryDirectory()
        try write(
            #"{"list": [{"id": "aaaa", "title": "dev", "content": "x\n"}]}"#,
            to: versionless.appendingPathComponent("data.json")
        )
        XCTAssertEqual(try SwitchHostsV3Reader.read(at: versionless).items.count, 1)
    }

    func testUnifiedReadTagsTheDetectedFormat() throws {
        let root = try makeTemporaryDirectory()
        try write(Self.v3Data, to: root.appendingPathComponent("data.json"))

        let (_, format) = try SwitchHostsReader.read(at: root)

        XCTAssertEqual(format, .v3)
    }

    func testUnifiedReadReportsAnEmptyDirectoryAsDataNotFound() throws {
        XCTAssertThrowsError(try SwitchHostsReader.read(at: try makeTemporaryDirectory())) { error in
            XCTAssertEqual(error as? SwitchHostsImportError, .dataNotFound)
        }
    }

    // MARK: - Discovery chain

    func testDiscoveryFindsTheDefaultDirectoryFirst() throws {
        let home = try makeTemporaryDirectory()
        let defaultDirectory = home.appendingPathComponent(".SwitchHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        try writeV5Fixture(at: defaultDirectory)

        let discovered = SwitchHostsDiscovery.discoverDataDirectory(
            homeDirectory: home,
            applicationSupportDirectory: try makeTemporaryDirectory()
        )

        XCTAssertEqual(discovered, defaultDirectory)
    }

    func testDiscoveryFollowsTheV5PointerWhenTheDefaultIsEmpty() throws {
        let home = try makeTemporaryDirectory()
        let applicationSupport = try makeTemporaryDirectory()
        let custom = try makeTemporaryDirectory()
        let store = custom.appendingPathComponent("SwitchHosts.data", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try writeV5Fixture(at: store)
        let pointerDirectory = applicationSupport.appendingPathComponent("net.oldj.switchhosts")
        try FileManager.default.createDirectory(at: pointerDirectory, withIntermediateDirectories: true)
        try write(
            #"{"format": "switchhosts-data-dir-pointer", "schemaVersion": 1, "dataDir": "\#(custom.path)"}"#,
            to: pointerDirectory.appendingPathComponent("data_dir.json")
        )

        let discovered = SwitchHostsDiscovery.discoverDataDirectory(
            homeDirectory: home,
            applicationSupportDirectory: applicationSupport
        )

        // The chain hands back the resolved store, SwitchHosts.data nesting included.
        XCTAssertEqual(discovered, store)
    }

    func testDiscoveryReadsTheSnakeCasePointerSpellingToo() throws {
        let home = try makeTemporaryDirectory()
        let applicationSupport = try makeTemporaryDirectory()
        let custom = try makeTemporaryDirectory()
        try write(Self.v3Data, to: custom.appendingPathComponent("data.json"))
        let pointerDirectory = applicationSupport.appendingPathComponent("net.oldj.switchhosts")
        try FileManager.default.createDirectory(at: pointerDirectory, withIntermediateDirectories: true)
        try write(
            #"{"data_dir": "\#(custom.path)"}"#,
            to: pointerDirectory.appendingPathComponent("data_dir.json")
        )

        let discovered = SwitchHostsDiscovery.discoverDataDirectory(
            homeDirectory: home,
            applicationSupportDirectory: applicationSupport
        )

        XCTAssertEqual(discovered, custom)
    }

    func testDiscoveryFallsBackToTheNewestV4ArchiveWhenTheLiveStoreIsEmpty() throws {
        let home = try makeTemporaryDirectory()
        let defaultDirectory = home.appendingPathComponent(".SwitchHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        try write(Self.systemOnlyV5Manifest, to: defaultDirectory.appendingPathComponent("manifest.json"))
        // The newest archive kept only config (the shape SwitchHosts #998 reported); the
        // two older ones still hold a v4 tree.
        let archives = defaultDirectory.appendingPathComponent("v4", isDirectory: true)
        let configOnly = archives.appendingPathComponent("migration-1800000000/config/dict", isDirectory: true)
        try FileManager.default.createDirectory(at: configOnly, withIntermediateDirectories: true)
        try write("{}", to: configOnly.appendingPathComponent("cfg.json"))
        let newer = archives.appendingPathComponent("migration-1700000000", isDirectory: true)
        let older = archives.appendingPathComponent("migration-1600000000", isDirectory: true)
        try writeV4Archive(at: newer)
        try writeV4Archive(at: older)

        let discovered = SwitchHostsDiscovery.discoverDataDirectory(
            homeDirectory: home,
            applicationSupportDirectory: try makeTemporaryDirectory()
        )

        XCTAssertEqual(discovered, newer)
    }

    func testDiscoveryPrefersALiveStoreWithRulesOverTheArchives() throws {
        let home = try makeTemporaryDirectory()
        let defaultDirectory = home.appendingPathComponent(".SwitchHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        try writeV5Fixture(at: defaultDirectory)
        try writeV4Archive(at: defaultDirectory.appendingPathComponent("v4/migration-1700000000", isDirectory: true))

        let discovered = SwitchHostsDiscovery.discoverDataDirectory(
            homeDirectory: home,
            applicationSupportDirectory: try makeTemporaryDirectory()
        )

        XCTAssertEqual(discovered, defaultDirectory)
    }

    func testDiscoveryStillHandsBackAnUnreadableLiveStore() throws {
        let home = try makeTemporaryDirectory()
        let defaultDirectory = home.appendingPathComponent(".SwitchHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        try write("not json", to: defaultDirectory.appendingPathComponent("manifest.json"))
        try writeV4Archive(at: defaultDirectory.appendingPathComponent("v4/migration-1700000000", isDirectory: true))

        let discovered = SwitchHostsDiscovery.discoverDataDirectory(
            homeDirectory: home,
            applicationSupportDirectory: try makeTemporaryDirectory()
        )

        // The corrupt store surfaces as an import failure with the manual pick, not as a silent skip.
        XCTAssertEqual(discovered, defaultDirectory)
    }

    func testDiscoveryReturnsNilWhenEveryStoreIsEmpty() throws {
        let home = try makeTemporaryDirectory()
        let defaultDirectory = home.appendingPathComponent(".SwitchHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        try write(Self.systemOnlyV5Manifest, to: defaultDirectory.appendingPathComponent("manifest.json"))

        XCTAssertNil(SwitchHostsDiscovery.discoverDataDirectory(
            homeDirectory: home,
            applicationSupportDirectory: try makeTemporaryDirectory()
        ))
    }

    func testDiscoveryReturnsNilWhenTheChainIsExhausted() throws {
        XCTAssertNil(SwitchHostsDiscovery.discoverDataDirectory(
            homeDirectory: try makeTemporaryDirectory(),
            applicationSupportDirectory: try makeTemporaryDirectory()
        ))
    }

    // MARK: - Fixtures

    /// Desensitized sample of a real v5 store: the manifest tree (camelCase fields, the
    /// system entry, a nested folder pair, a remote rule, a combined rule) plus content
    /// files under entries/, an apply history, and one trashed item.
    private func writeV5Fixture(at root: URL) throws {
        let manifest = #"""
        {
         "format": "switchhosts-data",
         "schemaVersion": 1,
         "root": [
          {"id": "sys0", "title": "系统 Hosts", "isSys": true, "on": true, "type": "local"},
          {"contentFile": "entries/aaaa.hosts", "id": "aaaa", "on": false, "title": "dev", "type": "local"},
          {"children": [
            {"contentFile": "entries/bbbb.hosts", "id": "bbbb", "on": false, "title": "pre1", "type": "local"},
            {"children": [
              {"contentFile": "entries/cccc.hosts", "id": "cccc", "on": false, "title": "web1", "type": "local"}
             ],
             "folder": {"mode": 2}, "id": "gggg", "on": false, "title": "前端", "type": "folder"}
           ],
           "folder": {"mode": 1}, "id": "ffff", "on": false, "title": "预发环境", "type": "folder"},
          {"contentFile": "entries/rrrr.hosts", "id": "rrrr", "on": false, "title": "Team Blocklist",
           "type": "remote", "source": "https://rules.example.test/list.hosts",
           "refreshIntervalSec": 86400, "lastRefresh": "2026-08-19 10:00:00", "lastRefreshMs": 1787101200000},
          {"id": "mmmm", "on": false, "title": "combo", "type": "group", "include": ["rrrr", "aaaa"]}
         ]
        }
        """#
        try write(manifest, to: root.appendingPathComponent("manifest.json"))
        let entries = root.appendingPathComponent("entries", isDirectory: true)
        try FileManager.default.createDirectory(at: entries, withIntermediateDirectories: true)
        try write("127.0.0.1 dev.example.test\n", to: entries.appendingPathComponent("aaaa.hosts"))
        try write("10.0.2.1 app.example.test\n", to: entries.appendingPathComponent("bbbb.hosts"))
        try write("10.0.2.2 web.example.test\n", to: entries.appendingPathComponent("cccc.hosts"))
        try write("0.0.0.0 tracker.example.test\n", to: entries.appendingPathComponent("rrrr.hosts"))
        let histories = root.appendingPathComponent("internal/histories", isDirectory: true)
        try FileManager.default.createDirectory(at: histories, withIntermediateDirectories: true)
        try write(
            #"[{"_id": "1", "add_time_ms": 1787101200000, "content": "x"}, {"_id": "2", "add_time_ms": 1787101300000, "content": "y"}]"#,
            to: histories.appendingPathComponent("system-hosts.json")
        )
        try write(
            #"{"format": "switchhosts-trashcan", "schemaVersion": 1, "items": [{"id": "gone", "title": "old"}]}"#,
            to: root.appendingPathComponent("trashcan.json")
        )
    }

    /// Desensitized sample of a v3 `data.json`: the same tree shape with `where`
    /// discriminators, inline content, and hour-based refresh intervals.
    private static let v3Data = #"""
    {
     "list": [
      {"id": "aaaa", "title": "dev", "where": "local", "content": "127.0.0.1 dev.example.test\n", "on": false},
      {"id": "ffff", "title": "预发环境", "where": "folder", "folder_mode": 1, "on": false,
       "children": [
        {"id": "gggg", "title": "前端", "where": "folder", "folder_mode": 0, "folder_open": true,
         "children": [
          {"id": "cccc", "title": "web1", "where": "local", "content": "10.0.2.2 web.example.test\n", "on": false}
         ]}
       ]},
      {"id": "rrrr", "title": "Team Blocklist", "where": "remote",
       "url": "https://rules.example.test/list.hosts", "refresh_interval": 24,
       "last_refresh": "2026-8-19 10:00:00", "content": "0.0.0.0 tracker.example.test\n", "on": false},
      {"id": "mmmm", "title": "combo", "where": "group", "include": ["aaaa", "rrrr"], "on": false}
     ],
     "version": [3, 5, 8, 0]
    }
    """#

    /// A v5 manifest holding nothing but the system entry: what a v4 → v5 upgrade that
    /// lost its rules leaves in `~/.SwitchHosts`.
    private static let systemOnlyV5Manifest = #"""
    {
     "format": "switchhosts-data",
     "schemaVersion": 1,
     "root": [{"id": "0", "title": "System Hosts", "isSys": true, "on": true}]
    }
    """#

    /// The v4 store as v5's migration archives it: `data/list/tree.json` with one loose
    /// rule; the hosts collection is absent, which the v4 reader accepts as "nothing stored".
    private func writeV4Archive(at root: URL) throws {
        let listDirectory = root.appendingPathComponent("data/list", isDirectory: true)
        try FileManager.default.createDirectory(at: listDirectory, withIntermediateDirectories: true)
        try write(
            #"[{"id": "0", "title": "System Hosts", "is_sys": true, "on": true}, {"title": "dev", "id": "aaaa", "on": false}]"#,
            to: listDirectory.appendingPathComponent("tree.json")
        )
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchhosts-formats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        // Standardized so equality against URLs the readers derive holds on /var → /private/var symlinks.
        return url.standardizedFileURL
    }
}
