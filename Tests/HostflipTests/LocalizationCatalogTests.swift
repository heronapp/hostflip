import Foundation
import XCTest

/// Guards the shipped .strings catalogs (ADR-0011): the three languages must
/// agree on keys, every value must keep the key's format specifiers, and every
/// non-interpolated String(localized:) literal in the GUI sources must have a
/// row in each catalog. SwiftUI literal keys are covered by release visual QA.
final class LocalizationCatalogTests: XCTestCase {
    private static let languages = ["zh-Hans", "zh-Hant", "ja"]
    private static let semanticKeys: Set<String> = [
        "PROFILE_DEFAULT_NAME", "PROFILE_DEFAULT_NAME_NUMBERED",
        "GROUP_DEFAULT_NAME", "GROUP_DEFAULT_NAME_NUMBERED",
        "PROFILE_COPY_NAME",
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func catalog(for language: String) throws -> [String: String] {
        let url = repoRoot.appendingPathComponent(
            "Packaging/Localization/\(language).lproj/Localizable.strings"
        )
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String], "\(language) is not a string table")
    }

    private func specifierCounts(_ text: String) -> [String: Int] {
        [
            "%@": text.components(separatedBy: "%@").count - 1,
            "%lld": text.components(separatedBy: "%lld").count - 1,
        ]
    }

    func testKeySetsMatchAcrossLanguages() throws {
        let catalogs = try Self.languages.map { try Self.catalog(for: $0) }
        let reference = Set(catalogs[0].keys)
        for (language, catalog) in zip(Self.languages.dropFirst(), catalogs.dropFirst()) {
            let keys = Set(catalog.keys)
            XCTAssertEqual(
                keys.symmetricDifference(reference), [],
                "\(language) key set differs from \(Self.languages[0])"
            )
        }
    }

    func testValuesKeepTheKeysFormatSpecifiers() throws {
        for language in Self.languages {
            for (key, value) in try Self.catalog(for: language)
            where !Self.semanticKeys.contains(key) {
                XCTAssertEqual(
                    specifierCounts(value), specifierCounts(key),
                    "\(language): format specifiers of “\(key)” diverge"
                )
            }
        }
    }

    func testSemanticDefaultNameKeysCarryTheCounter() throws {
        for language in Self.languages {
            let catalog = try Self.catalog(for: language)
            for key in Self.semanticKeys {
                let value = try XCTUnwrap(catalog[key], "\(language) misses \(key)")
                let expectsCounter = key.hasSuffix("_NUMBERED")
                XCTAssertEqual(
                    value.contains("%lld"), expectsCounter,
                    "\(language): \(key) placeholder mismatch"
                )
            }
        }
    }

    /// Every plain (non-interpolated) String(localized:) literal in the GUI target
    /// must exist in all catalogs — a missing row silently falls back to English.
    func testSourceLocalizedLiteralsHaveTranslations() throws {
        let sourcesDirectory = Self.repoRoot.appendingPathComponent("Sources/Hostflip")
        let sourceFiles = try FileManager.default
            .contentsOfDirectory(at: sourcesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(sourceFiles.isEmpty)

        let pattern = #"String\(\s*localized:\s*"((?:[^"\\]|\\.)*)""#
        let regex = try NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators]
        )
        var keys: Set<String> = []
        for file in sourceFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[keyRange])
                guard !key.contains(#"\("#) else { continue }
                keys.insert(key)
            }
        }
        XCTAssertGreaterThan(keys.count, 40, "extraction regex looks broken")

        for language in Self.languages {
            let catalog = try Self.catalog(for: language)
            for key in keys.sorted() {
                XCTAssertNotNil(catalog[key], "\(language) misses “\(key)”")
            }
        }
    }
}
