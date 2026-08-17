import AppKit
import XCTest
@testable import Hostflip

@MainActor
final class AppearancePreferenceStoreTests: XCTestCase {
    func testDefaultPreferenceIsAuto() {
        XCTAssertEqual(AppearancePreference.default, .auto)
    }

    func testAppearanceNameMapping() {
        XCTAssertNil(AppearancePreference.auto.appearanceName)
        XCTAssertEqual(AppearancePreference.light.appearanceName, .aqua)
        XCTAssertEqual(AppearancePreference.dark.appearanceName, .darkAqua)
    }

    func testStoreUsesDefaultPreferenceWhenNoPreferenceExists() {
        var appliedAppearances: [NSAppearance.Name?] = []

        let store = AppearancePreferenceStore(
            loadPreference: { nil },
            savePreference: { _ in },
            applyAppearance: { appliedAppearances.append($0) }
        )

        XCTAssertEqual(store.preference, .auto)
        XCTAssertEqual(appliedAppearances, [nil])
    }

    func testStoreRestoresPersistedPreference() {
        var appliedAppearances: [NSAppearance.Name?] = []

        let store = AppearancePreferenceStore(
            loadPreference: { AppearancePreference.dark.rawValue },
            savePreference: { _ in },
            applyAppearance: { appliedAppearances.append($0) }
        )

        XCTAssertEqual(store.preference, .dark)
        XCTAssertEqual(appliedAppearances, [.darkAqua])
    }

    func testStoreFallsBackToDefaultForUnknownPersistedValue() {
        let store = AppearancePreferenceStore(
            loadPreference: { "solarized" },
            savePreference: { _ in },
            applyAppearance: { _ in }
        )

        XCTAssertEqual(store.preference, .auto)
    }

    func testChangingPreferencePersistsAndAppliesAppearance() {
        var savedPreferences: [String] = []
        var appliedAppearances: [NSAppearance.Name?] = []
        let store = AppearancePreferenceStore(
            loadPreference: { nil },
            savePreference: { savedPreferences.append($0) },
            applyAppearance: { appliedAppearances.append($0) }
        )

        store.setPreference(.dark)

        XCTAssertEqual(store.preference, .dark)
        XCTAssertEqual(savedPreferences, [AppearancePreference.dark.rawValue])
        XCTAssertEqual(appliedAppearances, [nil, .darkAqua])
    }
}
