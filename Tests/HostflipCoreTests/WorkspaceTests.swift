import Darwin
import XCTest
@testable import HostflipCore

final class WorkspaceTests: XCTestCase {
    private var rootDirectory: URL!

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflip-workspace-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func testOpeningAnEmptyWorkspaceImportsSystemHostsAndSavesOriginalBackup() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)

        let model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })

        XCTAssertEqual(model.baseHosts.content, "127.0.0.1 localhost")
        XCTAssertEqual(model.standaloneProfiles, [])
        XCTAssertEqual(model.groups, [])
        XCTAssertEqual(model.activeProfileIDs, [])
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(try contentsOfWorkspaceFile("hosts.orig"), "127.0.0.1 localhost")
        XCTAssertTrue(workspaceFileExists("manifest.json"))
    }

    func testReopeningDoesNotReimportOrOverwriteOriginalBackup() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        _ = try workspace.open(systemHosts: { "127.0.0.1 localhost" })

        let model = try reopenWithoutImporting(workspace)

        XCTAssertEqual(model.baseHosts.content, "127.0.0.1 localhost")
        XCTAssertEqual(try contentsOfWorkspaceFile("hosts.orig"), "127.0.0.1 localhost")
    }

    func testSavingThenReopeningRestoresTheSameDomainState() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        _ = try workspace.open(systemHosts: { "127.0.0.1 localhost" })

        let blocker = Profile(id: .init("blocker"), name: "Blocker", content: "0.0.0.0 ads.example.com")
        let staging = Profile(id: .init("staging"), name: "Staging", content: "10.0.0.1 api.example.com")
        let production = Profile(id: .init("production"), name: "Production", content: "10.0.0.2 api.example.com")
        var model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost"),
            standaloneProfiles: [blocker],
            groups: [Group(id: .init("environment"), name: "Environment", profiles: [staging, production])]
        )
        try model.toggleProfile(blocker.id)
        try model.toggleProfile(staging.id)
        model.setPaused(true)

        try workspace.save(model)
        let reloaded = try reopenWithoutImporting(workspace)

        XCTAssertEqual(reloaded.baseHosts, model.baseHosts)
        XCTAssertEqual(reloaded.standaloneProfiles, model.standaloneProfiles)
        XCTAssertEqual(reloaded.groups, model.groups)
        XCTAssertEqual(reloaded.activeProfileIDs, [blocker.id, staging.id])
        XCTAssertTrue(reloaded.isPaused)
        XCTAssertEqual(try contentsOfWorkspaceFile("profiles/Blocker.hosts"), "0.0.0.0 ads.example.com")
    }

    func testSavingAnUpdatedBaseHostsSnapshotDoesNotTouchTheOriginalBackup() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        var model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })

        model.baseHosts.content = "127.0.0.1 localhost\n1.2.3.4 edited.example.com"
        try workspace.save(model)
        let reloaded = try reopenWithoutImporting(workspace)

        XCTAssertEqual(reloaded.baseHosts.content, "127.0.0.1 localhost\n1.2.3.4 edited.example.com")
        XCTAssertEqual(try contentsOfWorkspaceFile("hosts.orig"), "127.0.0.1 localhost")
    }

    func testAcceptingSystemHostsSavesBaseAndHashWithoutTouchingOriginalBackup() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        var model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })
        model.baseHosts.content = "9.9.9.9 adopted.local\n"

        try workspace.save(model, acceptingSystemHostsHash: "accepted-hash")

        XCTAssertEqual(try reopenWithoutImporting(workspace).baseHosts.content, model.baseHosts.content)
        XCTAssertEqual(try workspace.lastWrittenHash(), "accepted-hash")
        XCTAssertEqual(try contentsOfWorkspaceFile("hosts.orig"), "127.0.0.1 localhost")
    }

    func testProfileNamesAreSanitizedAndConflictsGetASuffix() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        _ = try workspace.open(systemHosts: { "127.0.0.1 localhost" })

        let slashed = Profile(id: .init("slashed"), name: "Dev/Test", content: "# slashed")
        let colonned = Profile(id: .init("colonned"), name: "Dev:Test", content: "# colonned")
        let lowercased = Profile(id: .init("lowercased"), name: "dev-test", content: "# lowercased")
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost"),
            standaloneProfiles: [slashed, colonned, lowercased],
            groups: []
        )

        try workspace.save(model)
        let reloaded = try reopenWithoutImporting(workspace)

        XCTAssertEqual(reloaded.standaloneProfiles, model.standaloneProfiles)
        XCTAssertEqual(try contentsOfWorkspaceFile("profiles/Dev-Test.hosts"), "# slashed")
        XCTAssertEqual(try contentsOfWorkspaceFile("profiles/Dev-Test 2.hosts"), "# colonned")
        XCTAssertEqual(try contentsOfWorkspaceFile("profiles/dev-test 3.hosts"), "# lowercased")
    }

    func testDeletingAllProfilesRemovesTheirFilesButKeepsBaseHosts() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        _ = try workspace.open(systemHosts: { "127.0.0.1 localhost" })
        let blocker = Profile(id: .init("blocker"), name: "Blocker", content: "# blocker")
        try workspace.save(
            ActivationModel(
                baseHosts: BaseHosts(content: "127.0.0.1 localhost"),
                standaloneProfiles: [blocker],
                groups: []
            )
        )

        try workspace.save(
            ActivationModel(
                baseHosts: BaseHosts(content: "127.0.0.1 localhost"),
                standaloneProfiles: [],
                groups: []
            )
        )
        let reloaded = try reopenWithoutImporting(workspace)

        XCTAssertFalse(workspaceFileExists("profiles/Blocker.hosts"))
        XCTAssertEqual(reloaded.standaloneProfiles, [])
        XCTAssertEqual(reloaded.baseHosts.content, "127.0.0.1 localhost")
        XCTAssertEqual(try contentsOfWorkspaceFile("hosts.orig"), "127.0.0.1 localhost")
    }

    func testOpeningAWorkspaceWithBaseHostsButNoManifestRefusesToImport() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try Data("1.2.3.4 user-edit".utf8).write(to: rootDirectory.appendingPathComponent("base.hosts"))

        let workspace = Workspace(rootDirectory: rootDirectory)

        XCTAssertThrowsError(try workspace.open(systemHosts: { "127.0.0.1 localhost" })) { error in
            XCTAssertEqual(error as? WorkspaceError, .residualContentWithoutManifest)
        }
        XCTAssertEqual(try contentsOfWorkspaceFile("base.hosts"), "1.2.3.4 user-edit")
        XCTAssertFalse(workspaceFileExists("manifest.json"))
    }

    func testOpeningAWorkspaceWithProfileFilesButNoManifestRefusesToImport() throws {
        let profilesDirectory = rootDirectory.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try Data("# blocker".utf8).write(to: profilesDirectory.appendingPathComponent("Blocker.hosts"))

        let workspace = Workspace(rootDirectory: rootDirectory)

        XCTAssertThrowsError(try workspace.open(systemHosts: { "127.0.0.1 localhost" })) { error in
            XCTAssertEqual(error as? WorkspaceError, .residualContentWithoutManifest)
        }
        XCTAssertEqual(try contentsOfWorkspaceFile("profiles/Blocker.hosts"), "# blocker")
    }

    func testOpeningAfterAnInterruptedFirstImportKeepsTheExistingOriginalBackup() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try Data("127.0.0.1 localhost".utf8).write(to: rootDirectory.appendingPathComponent("hosts.orig"))

        let workspace = Workspace(rootDirectory: rootDirectory)
        let model = try workspace.open(systemHosts: { "127.0.0.1 localhost\n# changed since" })

        XCTAssertEqual(model.baseHosts.content, "127.0.0.1 localhost\n# changed since")
        XCTAssertEqual(try contentsOfWorkspaceFile("hosts.orig"), "127.0.0.1 localhost")
    }

    func testSavingIntoAnUninitializedWorkspaceIsRejected() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        let model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost"),
            standaloneProfiles: [],
            groups: []
        )

        XCTAssertThrowsError(try workspace.save(model)) { error in
            XCTAssertEqual(error as? WorkspaceError, .notInitialized)
        }
        XCTAssertFalse(workspaceFileExists("manifest.json"))
        XCTAssertFalse(workspaceFileExists("base.hosts"))
    }

    func testCollidingProfileFileNamesStayStableWhenReordered() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        _ = try workspace.open(systemHosts: { "127.0.0.1 localhost" })
        let slashed = Profile(id: .init("slashed"), name: "Dev/Test", content: "# slashed")
        let colonned = Profile(id: .init("colonned"), name: "Dev:Test", content: "# colonned")
        var model = try ActivationModel(
            baseHosts: BaseHosts(content: "127.0.0.1 localhost"),
            standaloneProfiles: [slashed, colonned],
            groups: []
        )
        try workspace.save(model)

        try model.moveProfile(colonned.id, toIndex: 0)
        try workspace.save(model)

        XCTAssertEqual(try contentsOfWorkspaceFile("profiles/Dev-Test.hosts"), "# slashed")
        XCTAssertEqual(try contentsOfWorkspaceFile("profiles/Dev-Test 2.hosts"), "# colonned")
        XCTAssertEqual(try reopenWithoutImporting(workspace).standaloneProfiles, model.standaloneProfiles)
    }

    func testRenamingAProfileMovesItsContentToTheNewFileName() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        var model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })
        try model.addProfile(id: .init("blocker"), name: "Blocker", content: "# blocker")
        try workspace.save(model)

        try model.renameProfile(.init("blocker"), to: "Ad Block")
        try workspace.save(model)

        XCTAssertFalse(workspaceFileExists("profiles/Blocker.hosts"))
        XCTAssertEqual(try contentsOfWorkspaceFile("profiles/Ad Block.hosts"), "# blocker")
    }

    func testManagedProfilesGroupsOrderAndActivationSurviveReload() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        var model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })

        try model.addProfile(id: .init("blocker"), name: "Blocker", content: "# blocker")
        try model.addProfile(id: .init("adguard"), name: "AdGuard", content: "# adguard")
        try model.addProfile(id: .init("staging"), name: "Staging", content: "# staging")
        try model.addGroup(id: .init("environment"), name: "Environment")
        try model.addGroup(id: .init("network"), name: "Network")
        try model.moveProfile(.init("staging"), toGroup: .init("environment"))
        try model.toggleProfile(.init("staging"))
        try model.toggleProfile(.init("blocker"))
        try model.moveProfile(.init("adguard"), toIndex: 0)
        try model.moveGroup(.init("network"), toIndex: 0)
        try model.renameProfile(.init("blocker"), to: "Ad Block")
        model.setPaused(true)

        try workspace.save(model)
        let reloaded = try reopenWithoutImporting(workspace)

        XCTAssertEqual(reloaded.standaloneProfiles, model.standaloneProfiles)
        XCTAssertEqual(reloaded.groups, model.groups)
        XCTAssertEqual(reloaded.activeProfileIDs, model.activeProfileIDs)
        XCTAssertEqual(reloaded.isPaused, model.isPaused)
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.name), ["AdGuard", "Ad Block"])
        XCTAssertEqual(reloaded.groups.map(\.name), ["Network", "Environment"])
    }

    func testSwappingProfileNamesNeverReusesTheOtherProfilesFile() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        var model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })
        try model.addProfile(id: .init("a"), name: "Alpha", content: "# a")
        try model.addProfile(id: .init("b"), name: "Beta", content: "# b")
        try workspace.save(model)

        try model.renameProfile(.init("a"), to: "Beta")
        try model.renameProfile(.init("b"), to: "Alpha")
        try workspace.save(model)

        // Filenames referenced by the old manifest stay with their original owners: a swap rename lands in brand-new files,
        // so a save that fails midway never overwrites content the old manifest still references.
        XCTAssertEqual(try contentsOfWorkspaceFile("profiles/Beta 2.hosts"), "# a")
        XCTAssertEqual(try contentsOfWorkspaceFile("profiles/Alpha 2.hosts"), "# b")
        XCTAssertFalse(workspaceFileExists("profiles/Alpha.hosts"))
        XCTAssertFalse(workspaceFileExists("profiles/Beta.hosts"))
        XCTAssertEqual(try reopenWithoutImporting(workspace).standaloneProfiles, model.standaloneProfiles)
    }

    func testLastWrittenHashStartsNilAndSurvivesDomainResaves() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        var model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })
        XCTAssertNil(try workspace.lastWrittenHash())

        try workspace.recordLastWrittenHash("a249a12a2f3b5dd513ea921e2b02fa1f")
        XCTAssertEqual(try workspace.lastWrittenHash(), "a249a12a2f3b5dd513ea921e2b02fa1f")

        try model.addProfile(id: .init("blocker"), name: "Blocker", content: "# blocker")
        try workspace.save(model)

        XCTAssertEqual(try workspace.lastWrittenHash(), "a249a12a2f3b5dd513ea921e2b02fa1f")
        XCTAssertEqual(try reopenWithoutImporting(workspace).standaloneProfiles, model.standaloneProfiles)
    }

    func testExpectedSystemHostsHashUsesImportedSnapshotUntilFirstSuccessfulWrite() throws {
        let imported = "127.0.0.1 localhost\n"
        let workspace = Workspace(rootDirectory: rootDirectory)
        _ = try workspace.open(systemHosts: { imported })

        XCTAssertEqual(try workspace.expectedSystemHostsHash(), MergedHosts(content: imported).hash)

        let written = MergedHosts(content: "10.0.0.1 managed.local\n")
        try workspace.recordLastWrittenHash(written.hash)

        XCTAssertEqual(try workspace.expectedSystemHostsHash(), written.hash)
    }

    func testConcurrentSaveAndHashRecordingDoNotLoseTheRecordedHash() async throws {
        // Main-window edits persist on the MainActor while merge confirmation writes the hash back on a background task chain;
        // both read-modify-write the same manifest concurrently: save must not overwrite the value record just wrote
        // with the stale hash it read at the start (whatever order the two interleave in, the hash must be present after each round)
        let workspace = Workspace(rootDirectory: rootDirectory)
        let model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })

        for iteration in 1 ... 50 {
            let hash = "hash-\(iteration)"
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try workspace.save(model) }
                group.addTask { try workspace.recordLastWrittenHash(hash) }
                try await group.waitForAll()
            }
            XCTAssertEqual(try workspace.lastWrittenHash(), hash, "第 \(iteration) 轮丢失回写的哈希")
        }
    }

    func testSavingWithAnUnreadableManifestFailsBeforeWritingAnyContent() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        var model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })
        try model.addProfile(id: .init("blocker"), name: "Blocker", content: "# blocker")
        try workspace.save(model)
        try Data("not json".utf8).write(to: rootDirectory.appendingPathComponent("manifest.json"))

        model.baseHosts.content = "127.0.0.1 localhost\n# edited"
        try model.updateProfileContent(.init("blocker"), content: "# edited")

        // The save must fail before writing any content file: no partial update may be left on disk.
        XCTAssertThrowsError(try workspace.save(model))
        XCTAssertEqual(try contentsOfWorkspaceFile("manifest.json"), "not json")
        XCTAssertEqual(try contentsOfWorkspaceFile("base.hosts"), "127.0.0.1 localhost")
        XCTAssertEqual(try contentsOfWorkspaceFile("profiles/Blocker.hosts"), "# blocker")
    }

    func testAParentFormatManifestWithoutTheHashKeyRoundTripsLosslessly() throws {
        // Hand-build a workspace snapshot from before the lastWrittenHash field was added, proving the field addition
        // is a non-breaking change for old manifests.
        let profilesDirectory = rootDirectory.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try Data("127.0.0.1 localhost".utf8).write(to: rootDirectory.appendingPathComponent("hosts.orig"))
        try Data("127.0.0.1 localhost".utf8).write(to: rootDirectory.appendingPathComponent("base.hosts"))
        try Data("# blocker".utf8).write(to: profilesDirectory.appendingPathComponent("Blocker.hosts"))
        try Data("# staging".utf8).write(to: profilesDirectory.appendingPathComponent("Staging.hosts"))
        try Data("""
        {
          "activeProfileIDs" : [ "blocker", "staging" ],
          "standaloneProfiles" : [ { "file" : "Blocker.hosts", "id" : "blocker", "name" : "Blocker" } ],
          "groups" : [ { "id" : "environment", "name" : "Environment", "profiles" : [ { "file" : "Staging.hosts", "id" : "staging", "name" : "Staging" } ] } ],
          "isPaused" : true,
          "version" : 1
        }
        """.utf8).write(to: rootDirectory.appendingPathComponent("manifest.json"))
        let workspace = Workspace(rootDirectory: rootDirectory)

        let model = try reopenWithoutImporting(workspace)
        XCTAssertNil(try workspace.lastWrittenHash())

        try workspace.recordLastWrittenHash("a249a12a2f3b5dd513ea921e2b02fa1f")
        try workspace.save(model)
        let reloaded = try reopenWithoutImporting(workspace)

        XCTAssertEqual(reloaded.standaloneProfiles.map(\.name), ["Blocker"])
        XCTAssertEqual(reloaded.groups.map(\.name), ["Environment"])
        XCTAssertEqual(reloaded.groups.first?.profiles.map(\.name), ["Staging"])
        XCTAssertEqual(reloaded.activeProfileIDs, [.init("blocker"), .init("staging")])
        XCTAssertTrue(reloaded.isPaused)
        XCTAssertEqual(try contentsOfWorkspaceFile("profiles/Staging.hosts"), "# staging")
        XCTAssertEqual(try workspace.lastWrittenHash(), "a249a12a2f3b5dd513ea921e2b02fa1f")
    }

    func testHashOperationsOnAnUninitializedWorkspaceAreRejected() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)

        XCTAssertThrowsError(try workspace.lastWrittenHash()) { error in
            XCTAssertEqual(error as? WorkspaceError, .notInitialized)
        }
        XCTAssertThrowsError(try workspace.recordLastWrittenHash("a249a12a")) { error in
            XCTAssertEqual(error as? WorkspaceError, .notInitialized)
        }
        XCTAssertFalse(workspaceFileExists("manifest.json"))
    }

    func testOpenReadOnlyLoadsAnInitializedWorkspace() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        var model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })
        try model.addProfile(id: .init("dev"), name: "Dev", content: "# dev")
        try workspace.save(model)

        let reloaded = try workspace.openReadOnly()

        XCTAssertEqual(reloaded.baseHosts.content, "127.0.0.1 localhost")
        XCTAssertEqual(reloaded.standaloneProfiles.map(\.name), ["Dev"])
    }

    func testOpenReadOnlyOnAnUninitializedWorkspaceThrowsWithoutCapturing() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)

        XCTAssertThrowsError(try workspace.openReadOnly()) { error in
            XCTAssertEqual(error as? WorkspaceError, .notInitialized)
        }
        XCTAssertFalse(workspaceFileExists("manifest.json"))
        XCTAssertFalse(workspaceFileExists("hosts.orig"))
    }

    // MARK: - Cross-process manifest lock (#50, ADR-0010 ①)

    func testSaveWaitsForAForeignManifestLockHolder() throws {
        let workspace = Workspace(rootDirectory: rootDirectory)
        let model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })
        XCTAssertTrue(workspaceFileExists("manifest.lock"), "锁应落在专用 lock 文件上，与 manifest 本体分离")

        let foreign = try acquireForeignManifestLock()
        defer { close(foreign) }

        let finished = CompletionFlag()
        Thread.detachNewThread {
            do {
                try workspace.save(model)
            } catch {
                XCTFail("save 失败：\(error)")
            }
            finished.set()
        }

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(finished.isSet, "外部进程持锁期间 save 不应完成")

        XCTAssertEqual(flock(foreign, LOCK_UN), 0)
        XCTAssertTrue(finished.wait(timeout: 5), "外部锁释放后 save 应完成")
    }

    func testForeignReadModifyWriteUnderTheLockLosesNoUpdate() throws {
        // The CLI and the resident GUI are peer writers: a foreign holder reads then writes under
        // the lock, so this process's hash write-back must wait for the release and re-read the state
        // the foreign side wrote — both updates must land, neither side may overwrite the other.
        let workspace = Workspace(rootDirectory: rootDirectory)
        _ = try workspace.open(systemHosts: { "127.0.0.1 localhost" })

        let foreign = try acquireForeignManifestLock()
        defer { close(foreign) }
        // The foreign process's "read" step inside the lock
        let manifestURL = rootDirectory.appendingPathComponent("manifest.json")
        var foreignManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )

        let finished = CompletionFlag()
        Thread.detachNewThread {
            do {
                try workspace.recordLastWrittenHash("cross-process")
            } catch {
                XCTFail("recordLastWrittenHash 失败：\(error)")
            }
            finished.set()
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(finished.isSet, "外部进程持锁期间哈希回写不应完成")

        // The foreign process's "modify-write" step: atomically replace the manifest, then release the lock
        foreignManifest["isPaused"] = true
        try JSONSerialization.data(withJSONObject: foreignManifest).write(to: manifestURL, options: .atomic)
        XCTAssertEqual(flock(foreign, LOCK_UN), 0)

        XCTAssertTrue(finished.wait(timeout: 5), "外部锁释放后哈希回写应完成")
        XCTAssertEqual(try workspace.lastWrittenHash(), "cross-process")
        XCTAssertTrue(try reopenWithoutImporting(workspace).isPaused, "外部在锁内写入的更新不得被覆盖")
    }

    func testSaveUnderTheLockPreservesAForeignlyRecordedHash() throws {
        // The reverse direction of the lost-update pair: a foreign process records the last-written
        // hash under the lock, and a local save that was waiting must re-read and carry that hash
        // forward instead of resetting it to the value it knew before blocking.
        let workspace = Workspace(rootDirectory: rootDirectory)
        let model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })

        let foreign = try acquireForeignManifestLock()
        defer { close(foreign) }
        let manifestURL = rootDirectory.appendingPathComponent("manifest.json")
        var foreignManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )

        let finished = CompletionFlag()
        Thread.detachNewThread {
            do {
                try workspace.save(model)
            } catch {
                XCTFail("save 失败：\(error)")
            }
            finished.set()
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(finished.isSet, "外部进程持锁期间 save 不应完成")

        foreignManifest["lastWrittenHash"] = "foreign-hash"
        try JSONSerialization.data(withJSONObject: foreignManifest).write(to: manifestURL, options: .atomic)
        XCTAssertEqual(flock(foreign, LOCK_UN), 0)

        XCTAssertTrue(finished.wait(timeout: 5), "外部锁释放后 save 应完成")
        XCTAssertEqual(try workspace.lastWrittenHash(), "foreign-hash", "外部在锁内回写的哈希不得被 save 重置")
    }

    func testALeftoverLockFileFromACrashDoesNotBlockAnything() throws {
        // flock-style kernel locks die with their holder, so a crash leaves only the lock file
        // itself behind; an unheld leftover is neither a deadlock nor residual content — first
        // capture proceeds as usual.
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try Data().write(to: rootDirectory.appendingPathComponent("manifest.lock"))

        let workspace = Workspace(rootDirectory: rootDirectory)
        var model = try workspace.open(systemHosts: { "127.0.0.1 localhost" })
        try model.addProfile(id: .init("blocker"), name: "Blocker", content: "# blocker")
        try workspace.save(model)
        try workspace.recordLastWrittenHash("a249a12a2f3b5dd513ea921e2b02fa1f")

        XCTAssertEqual(try workspace.lastWrittenHash(), "a249a12a2f3b5dd513ea921e2b02fa1f")
    }

    /// Holds the kernel-exclusive flock on manifest.lock through an independently opened descriptor,
    /// simulating another process's holder: flock ownership follows the open file description, so an
    /// independent descriptor contends with Workspace's own exactly like a real foreign process would —
    /// an equivalent of a child-process test.
    private func acquireForeignManifestLock() throws -> Int32 {
        let path = rootDirectory.appendingPathComponent("manifest.lock").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        let locked = try XCTUnwrap(fd >= 0 ? fd : nil, "打开 manifest.lock 失败")
        XCTAssertEqual(flock(locked, LOCK_EX), 0)
        return locked
    }

    private func reopenWithoutImporting(_ workspace: Workspace) throws -> ActivationModel {
        try workspace.open(systemHosts: {
            XCTFail("已初始化的工作区不应再读取系统 hosts")
            return ""
        })
    }

    private func contentsOfWorkspaceFile(_ relativePath: String) throws -> String {
        try String(
            contentsOf: rootDirectory.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func workspaceFileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: rootDirectory.appendingPathComponent(relativePath).path
        )
    }
}

/// Cross-thread completion marker: a background thread sets it, the test thread polls it — used to
/// assert "not finished while the lock is held, finished after release".
private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }

    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !isSet {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}
