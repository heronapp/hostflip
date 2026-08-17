import XCTest
@testable import Hostflip

final class LanguagePreferenceTests: XCTestCase {
    func testNoOverrideMeansSystem() {
        XCTAssertEqual(LanguagePreference(override: nil), .system)
        XCTAssertEqual(LanguagePreference(override: []), .system)
        XCTAssertEqual(LanguagePreference(override: [""]), .system)
    }

    func testOverrideResolvesToCanonicalSelection() {
        XCTAssertEqual(LanguagePreference(override: ["en"]), .english)
        XCTAssertEqual(LanguagePreference(override: ["en-US", "ja"]), .english)
        XCTAssertEqual(LanguagePreference(override: ["zh-Hans"]), .simplifiedChinese)
        XCTAssertEqual(LanguagePreference(override: ["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(LanguagePreference(override: ["zh"]), .simplifiedChinese)
        XCTAssertEqual(LanguagePreference(override: ["zh-Hant"]), .traditionalChinese)
        XCTAssertEqual(LanguagePreference(override: ["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(LanguagePreference(override: ["zh-Hant-HK"]), .traditionalChinese)
        XCTAssertEqual(LanguagePreference(override: ["ja-JP"]), .japanese)
    }

    func testUnsupportedOverrideFallsBackToEnglish() {
        XCTAssertEqual(LanguagePreference(override: ["fr"]), .english)
        XCTAssertEqual(LanguagePreference(override: ["ko-KR"]), .english)
    }

    func testOverrideLanguagesRoundTrip() {
        XCTAssertNil(LanguagePreference.system.overrideLanguages)
        XCTAssertEqual(LanguagePreference.english.overrideLanguages, ["en"])
        XCTAssertEqual(LanguagePreference.simplifiedChinese.overrideLanguages, ["zh-Hans"])
        XCTAssertEqual(LanguagePreference.traditionalChinese.overrideLanguages, ["zh-Hant"])
        XCTAssertEqual(LanguagePreference.japanese.overrideLanguages, ["ja"])
    }

    func testEffectiveLanguageForExplicitSelectionIsItself() {
        XCTAssertEqual(LanguagePreference.japanese.effectiveLanguage(systemLanguages: ["zh-Hans-CN"]), "ja")
        XCTAssertEqual(LanguagePreference.english.effectiveLanguage(systemLanguages: []), "en")
    }

    func testEffectiveLanguageForSystemWalksThePreferenceList() {
        XCTAssertEqual(
            LanguagePreference.system.effectiveLanguage(systemLanguages: ["fr-FR", "ja-JP", "en"]),
            "ja"
        )
        XCTAssertEqual(
            LanguagePreference.system.effectiveLanguage(systemLanguages: ["zh-Hant-TW", "zh-Hans-CN"]),
            "zh-Hant"
        )
        XCTAssertEqual(
            LanguagePreference.system.effectiveLanguage(systemLanguages: ["fr-FR", "ko-KR"]),
            "en"
        )
    }

    func testSupportedLanguagesMatchTheSelectableCases() {
        XCTAssertEqual(
            Set(LanguagePreference.allCases.compactMap { $0.overrideLanguages?.first }),
            Set(LanguagePreference.supportedLanguages)
        )
    }
}
