import XCTest
@testable import Hostflip

@MainActor
final class DockIconVisibilityStoreTests: XCTestCase {
    func testDefaultDockIconVisibilityUsesMainWindowPresence() {
        XCTAssertEqual(DockIconVisibilityPolicy.default, .whenMainWindowIsOpen)
    }

    func testWhenMainWindowIsOpenFollowsMainWindowPresence() {
        XCTAssertTrue(
            DockIconVisibilityPolicy.whenMainWindowIsOpen.showsDockIcon(mainWindowIsOpen: true)
        )
        XCTAssertFalse(
            DockIconVisibilityPolicy.whenMainWindowIsOpen.showsDockIcon(mainWindowIsOpen: false)
        )
    }

    func testAlwaysShowsDockAfterMainWindowCloses() {
        XCTAssertTrue(DockIconVisibilityPolicy.always.showsDockIcon(mainWindowIsOpen: false))
    }

    func testNeverHidesDockWhileMainWindowIsOpen() {
        XCTAssertFalse(DockIconVisibilityPolicy.never.showsDockIcon(mainWindowIsOpen: true))
    }

    func testStoreUsesDefaultPolicyWhenNoPreferenceExists() {
        var appliedVisibility: [Bool] = []

        let store = DockIconVisibilityStore(
            mainWindowIsOpen: true,
            loadPolicy: { nil },
            savePolicy: { _ in },
            applyDockIconVisibility: { appliedVisibility.append($0) }
        )

        XCTAssertEqual(store.policy, .whenMainWindowIsOpen)
        XCTAssertEqual(appliedVisibility, [true])
    }

    func testStoreRestoresPersistedPolicy() {
        var appliedVisibility: [Bool] = []

        let store = DockIconVisibilityStore(
            mainWindowIsOpen: true,
            loadPolicy: { DockIconVisibilityPolicy.never.rawValue },
            savePolicy: { _ in },
            applyDockIconVisibility: { appliedVisibility.append($0) }
        )

        XCTAssertEqual(store.policy, .never)
        XCTAssertEqual(appliedVisibility, [false])
    }

    func testChangingPolicyPersistsAndUpdatesDockVisibility() {
        var savedPolicies: [String] = []
        var appliedVisibility: [Bool] = []
        let store = DockIconVisibilityStore(
            mainWindowIsOpen: true,
            loadPolicy: { nil },
            savePolicy: { savedPolicies.append($0) },
            applyDockIconVisibility: { appliedVisibility.append($0) }
        )

        store.setPolicy(.never)

        XCTAssertEqual(store.policy, .never)
        XCTAssertEqual(savedPolicies, [DockIconVisibilityPolicy.never.rawValue])
        XCTAssertEqual(appliedVisibility, [true, false])
    }

    func testClosingMainWindowHidesDockForDefaultPolicy() {
        var appliedVisibility: [Bool] = []
        let store = DockIconVisibilityStore(
            mainWindowIsOpen: true,
            loadPolicy: { nil },
            savePolicy: { _ in },
            applyDockIconVisibility: { appliedVisibility.append($0) }
        )

        store.mainWindowDidClose()

        XCTAssertFalse(store.mainWindowIsOpen)
        XCTAssertEqual(appliedVisibility, [true, false])
    }

    func testOpeningMainWindowShowsDockForDefaultPolicy() {
        var appliedVisibility: [Bool] = []
        let store = DockIconVisibilityStore(
            mainWindowIsOpen: false,
            loadPolicy: { nil },
            savePolicy: { _ in },
            applyDockIconVisibility: { appliedVisibility.append($0) }
        )

        store.mainWindowDidOpen()

        XCTAssertTrue(store.mainWindowIsOpen)
        XCTAssertEqual(appliedVisibility, [false, true])
    }
}
