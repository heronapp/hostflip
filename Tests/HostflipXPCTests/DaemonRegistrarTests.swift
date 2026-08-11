import XCTest
@testable import HostflipXPC

final class DaemonRegistrarTests: XCTestCase {
    private func makeRegistrar(
        manager: FakeDaemonManager,
        currentBuildVersion: String = "1",
        record: VersionRecord = VersionRecord()
    ) -> DaemonRegistrar {
        DaemonRegistrar(
            manager: manager,
            currentBuildVersion: currentBuildVersion,
            recordedVersion: { record.current },
            recordVersion: { record.set($0) },
            wait: { _ in }
        )
    }

    // MARK: - ensureReadyForSwitch: lazy registration

    func testEnsureReadyProceedsWithoutRegisteringWhenEnabled() async {
        let manager = FakeDaemonManager(status: .enabled)

        let readiness = await makeRegistrar(manager: manager).ensureReadyForSwitch()

        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(manager.recordedCalls, [])
    }

    func testEnsureReadyRegistersOnFirstSwitchAndProceedsWhenApproved() async {
        let manager = FakeDaemonManager(status: .notRegistered, afterRegister: .enabled)
        let record = VersionRecord()

        let readiness = await makeRegistrar(
            manager: manager, currentBuildVersion: "3", record: record
        ).ensureReadyForSwitch()

        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(manager.recordedCalls, ["register"])
        XCTAssertEqual(record.current, "3")
    }

    func testEnsureReadyBlocksForApprovalWhenRegistrationAwaitsUser() async {
        // When SMAppService is not yet approved, register() throws and the status lands on requiresApproval —
        // the verdict comes from the actual status afterwards, not from the thrown error
        let manager = FakeDaemonManager(
            status: .notRegistered,
            afterRegister: .requiresApproval,
            registerError: NSError(domain: "SMAppServiceErrorDomain", code: 1)
        )
        let record = VersionRecord()

        let readiness = await makeRegistrar(
            manager: manager, currentBuildVersion: "3", record: record
        ).ensureReadyForSwitch()

        XCTAssertEqual(readiness, .needsApproval)
        XCTAssertEqual(record.current, "3")
    }

    func testEnsureReadyDoesNotReRegisterWhileAwaitingApproval() async {
        let manager = FakeDaemonManager(status: .requiresApproval)

        let readiness = await makeRegistrar(manager: manager).ensureReadyForSwitch()

        XCTAssertEqual(readiness, .needsApproval)
        XCTAssertEqual(manager.recordedCalls, [])
    }

    func testEnsureReadyRetriesRegisterAcrossBTMSettleWindow() async {
        // For a few seconds after unregister, register is rejected (the BTM settle window): the switch path likewise
        // backs off and retries; the transient window must not be misread as "unavailable, guide the user to reinstall"
        let manager = FakeDaemonManager(
            status: .notRegistered, afterRegister: .enabled, failingRegisterAttempts: 2
        )

        let readiness = await makeRegistrar(manager: manager).ensureReadyForSwitch()

        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(manager.recordedCalls, ["register", "register", "register"])
    }

    func testEnsureReadyReportsUnavailableWhenRegistrationDoesNotTakeEffect() async {
        let manager = FakeDaemonManager(
            status: .notFound,
            afterRegister: .notFound,
            registerError: NSError(domain: "SMAppServiceErrorDomain", code: 2)
        )
        let record = VersionRecord()

        let readiness = await makeRegistrar(manager: manager, record: record).ensureReadyForSwitch()

        XCTAssertEqual(readiness, .unavailable)
        let registerAttempts = manager.recordedCalls.filter { $0 == "register" }.count
        XCTAssertLessThanOrEqual(registerAttempts, 12)
        XCTAssertGreaterThanOrEqual(registerAttempts, 1)
        XCTAssertNil(record.current)
    }

    // MARK: - healOnLaunch: launch-time recheck + re-registration on version change

    func testHealOnLaunchReRegistersRegisteredHelperWhenBuildVersionChanged() async {
        let manager = FakeDaemonManager(status: .enabled, afterRegister: .enabled)
        let record = VersionRecord("1")

        let status = await makeRegistrar(
            manager: manager, currentBuildVersion: "2", record: record
        ).healOnLaunch()

        XCTAssertEqual(manager.recordedCalls, ["unregister", "register"])
        XCTAssertEqual(record.current, "2")
        XCTAssertEqual(status, .enabled)
    }

    func testHealOnLaunchReRegistersEvenWhileAwaitingApproval() async {
        let manager = FakeDaemonManager(status: .requiresApproval, afterRegister: .requiresApproval)
        let record = VersionRecord("1")

        let status = await makeRegistrar(
            manager: manager, currentBuildVersion: "2", record: record
        ).healOnLaunch()

        XCTAssertEqual(manager.recordedCalls, ["unregister", "register"])
        XCTAssertEqual(status, .requiresApproval)
    }

    func testHealOnLaunchRetriesRegisterUntilUnregisterSettles() async {
        // Observed in practice: BTM applies unregister asynchronously, so the register that follows immediately is rejected;
        // we must back off and retry, or the helper drops to notRegistered
        let manager = FakeDaemonManager(
            status: .enabled, afterRegister: .enabled, failingRegisterAttempts: 2
        )
        let record = VersionRecord("1")

        let status = await makeRegistrar(
            manager: manager, currentBuildVersion: "2", record: record
        ).healOnLaunch()

        XCTAssertEqual(status, .enabled)
        XCTAssertEqual(manager.recordedCalls, ["unregister", "register", "register", "register"])
        XCTAssertEqual(record.current, "2")
    }

    func testHealOnLaunchGivesUpAfterBoundedRetriesAndDefersToLazyRegistration() async {
        // Retries are bounded: give up on persistent failure and let lazy registration on the next switch pick it up (approval is preserved)
        let manager = FakeDaemonManager(
            status: .enabled, afterRegister: .enabled, failingRegisterAttempts: .max
        )
        let record = VersionRecord("1")

        let status = await makeRegistrar(
            manager: manager, currentBuildVersion: "2", record: record
        ).healOnLaunch()

        XCTAssertEqual(status, .notRegistered)
        let registerAttempts = manager.recordedCalls.filter { $0 == "register" }.count
        XCTAssertLessThanOrEqual(registerAttempts, 12)
        XCTAssertEqual(record.current, "2")
    }

    func testHealOnLaunchKeepsRecordedVersionWhenUnregisterFails() async {
        // Unregister failed (the helper is still on the old registration): the new version must not be recorded —
        // otherwise the migration would be misjudged as complete and later launches would never retry
        let manager = FakeDaemonManager(
            status: .enabled,
            unregisterError: NSError(domain: "SMAppServiceErrorDomain", code: 3)
        )
        let record = VersionRecord("1")

        let status = await makeRegistrar(
            manager: manager, currentBuildVersion: "2", record: record
        ).healOnLaunch()

        XCTAssertEqual(status, .enabled)
        XCTAssertEqual(record.current, "1")
        XCTAssertEqual(manager.recordedCalls, ["unregister"])
    }

    func testHealOnLaunchLeavesHelperUntouchedWhenVersionUnchanged() async {
        let manager = FakeDaemonManager(status: .enabled)
        let record = VersionRecord("2")

        let status = await makeRegistrar(
            manager: manager, currentBuildVersion: "2", record: record
        ).healOnLaunch()

        XCTAssertEqual(manager.recordedCalls, [])
        XCTAssertEqual(status, .enabled)
    }

    func testHealOnLaunchAdoptsCurrentVersionForPreexistingRegistration() async {
        // Version recording was introduced with this state machine: an existing install that is registered but has no record adopts the current version without re-registering
        let manager = FakeDaemonManager(status: .enabled)
        let record = VersionRecord(nil)

        _ = await makeRegistrar(
            manager: manager, currentBuildVersion: "2", record: record
        ).healOnLaunch()

        XCTAssertEqual(manager.recordedCalls, [])
        XCTAssertEqual(record.current, "2")
    }

    func testHealOnLaunchDoesNotRegisterUnregisteredHelper() async {
        // Lazy trigger: the launch-time recheck never registers on its own; registration only happens on the first switch
        let manager = FakeDaemonManager(status: .notRegistered)
        let record = VersionRecord("1")

        let status = await makeRegistrar(
            manager: manager, currentBuildVersion: "2", record: record
        ).healOnLaunch()

        XCTAssertEqual(manager.recordedCalls, [])
        XCTAssertEqual(status, .notRegistered)
    }

    // MARK: - unregister

    func testUnregisterRemovesHelperAndClearsRecordedVersion() async throws {
        let manager = FakeDaemonManager(status: .enabled)
        let record = VersionRecord("2")
        let registrar = makeRegistrar(manager: manager, record: record)

        try await registrar.unregister()

        XCTAssertEqual(manager.recordedCalls, ["unregister"])
        XCTAssertNil(record.current)
        let status = await registrar.refreshStatus()
        XCTAssertEqual(status, .notRegistered)
    }
}
