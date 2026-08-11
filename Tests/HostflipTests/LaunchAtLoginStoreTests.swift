import AppKit
@testable import Hostflip
import XCTest

final class LaunchAtLoginStoreTests: XCTestCase {
    @MainActor
    func testEnableRegistersAndReflectsState() {
        let service = LoginItemServiceStub()
        let store = makeStore(service: service)

        store.setEnabled(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertTrue(store.isEnabled)
    }

    @MainActor
    func testDisableUnregistersAndReflectsState() {
        let service = LoginItemServiceStub()
        let store = makeStore(service: service, isEnabled: true)

        store.setEnabled(false)

        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(store.isEnabled)
    }

    @MainActor
    func testSettingSameValueDoesNotTouchTheService() {
        let service = LoginItemServiceStub()
        let store = makeStore(service: service)

        store.setEnabled(false)

        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    @MainActor
    func testRegistrationFailureKeepsToggleOff() {
        let service = LoginItemServiceStub(registerFails: true)
        let store = makeStore(service: service)

        store.setEnabled(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertFalse(store.isEnabled)
    }

    func testLoginItemLaunchRequiresOpenEventWithLoginItemTag() {
        XCTAssertTrue(LoginItemLaunch.isLoginItemLaunch(
            eventID: AEEventID(kAEOpenApplication),
            propDataEnumCode: OSType(keyAELaunchedAsLogInItem)
        ))
        // Finder / Spotlight / `open`: same event, no login-item tag.
        XCTAssertFalse(LoginItemLaunch.isLoginItemLaunch(
            eventID: AEEventID(kAEOpenApplication),
            propDataEnumCode: nil
        ))
        XCTAssertFalse(LoginItemLaunch.isLoginItemLaunch(
            eventID: AEEventID(kAEOpenDocuments),
            propDataEnumCode: OSType(keyAELaunchedAsLogInItem)
        ))
        XCTAssertFalse(LoginItemLaunch.isLoginItemLaunch(eventID: nil, propDataEnumCode: nil))
    }

    @MainActor
    private func makeStore(service: LoginItemServiceStub, isEnabled: Bool = false) -> LaunchAtLoginStore {
        LaunchAtLoginStore(
            isEnabled: isEnabled,
            register: { try service.register() },
            unregister: { try service.unregister() }
        )
    }
}

@MainActor
private final class LoginItemServiceStub {
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private let registerFails: Bool

    init(registerFails: Bool = false) {
        self.registerFails = registerFails
    }

    func register() throws {
        registerCalls += 1
        if registerFails { throw StubError() }
    }

    func unregister() throws {
        unregisterCalls += 1
    }
}

private struct StubError: Error {}
