import HostflipCore
import XCTest
@testable import Hostflip

/// Global search results (#88): documents in sidebar order, only those with matches, one row
/// per matching line with the trimmed line text.
final class GlobalSearchResultsTests: XCTestCase {
    private let base = GlobalSearchResults.Document(
        item: .baseHosts, name: "Base Hosts", content: "127.0.0.1 localhost\n", isActive: nil
    )
    private let dev = GlobalSearchResults.Document(
        item: .profile(Profile.ID("dev")), name: "dev", content: "  10.0.0.1   api.test  \n# api down\n", isActive: true
    )
    private let prod = GlobalSearchResults.Document(
        item: .profile(Profile.ID("prod")), name: "prod", content: "1.2.3.4 www.test", isActive: false
    )

    func testKeepsOnlyMatchingDocumentsInOrderWithTrimmedLines() {
        let results = GlobalSearchResults(documents: [base, dev, prod], query: "api")
        XCTAssertEqual(results.results.map(\.document.name), ["dev"])
        XCTAssertEqual(results.results[0].matches.map(\.lineText), ["10.0.0.1   api.test", "# api down"])
        XCTAssertEqual(results.results[0].matches.map(\.hit.line), [1, 2])
    }

    func testBaseHostsTakesPartAndOrderFollowsTheSidebar() {
        let results = GlobalSearchResults(documents: [base, dev, prod], query: "test")
        XCTAssertEqual(results.results.map(\.document.name), ["dev", "prod"])
        XCTAssertEqual(GlobalSearchResults(documents: [base, dev, prod], query: "localhost").results.map(\.document.name), ["Base Hosts"])
    }

    func testLongPrefixBeforeTheMatchFoldsIntoContext() {
        let doc = GlobalSearchResults.Document(
            item: .profile(Profile.ID("x")), name: "x",
            content: "   185.199.109.133 avatars.githubusercontent.com\n0.0.0.0 github.com", isActive: false
        )
        let matches = GlobalSearchResults(documents: [doc], query: "github").results[0].matches
        XCTAssertEqual(matches[0].lineText, "185.199.109.133 avatars.githubusercontent.com")
        XCTAssertEqual(matches[0].displayText, "…rs.githubusercontent.com")
        XCTAssertEqual(matches[1].displayText, "0.0.0.0 github.com")
    }

    func testDisplayTextCollapsesAlignmentWhitespace() {
        let doc = GlobalSearchResults.Document(
            item: .profile(Profile.ID("x")), name: "x", content: "10.0.0.1\t\t  api.test   # dev", isActive: false
        )
        let match = GlobalSearchResults(documents: [doc], query: "api").results[0].matches[0]
        XCTAssertEqual(match.displayText, "10.0.0.1 api.test # dev")
        XCTAssertEqual(match.lineText, "10.0.0.1\t\t  api.test   # dev")
    }

    func testFoldingNeverSplitsASurrogatePair() {
        let doc = GlobalSearchResults.Document(
            item: .profile(Profile.ID("x")), name: "x", content: "# 🚀🚀🚀🚀🚀🚀🚀🚀 launch api.test", isActive: false
        )
        let match = GlobalSearchResults(documents: [doc], query: "api").results[0].matches[0]
        XCTAssertTrue(match.displayText.hasPrefix("…"))
        XCTAssertFalse(match.displayText.unicodeScalars.contains { $0.value == 0xFFFD })
        XCTAssertTrue(match.displayText.hasSuffix("api.test"))
    }

    func testMatchesAreCappedPerDocumentWithTheRestCounted() {
        let content = (1...250).map { "0.0.0.0 host\($0).example" }.joined(separator: "\n")
        let doc = GlobalSearchResults.Document(item: .profile(Profile.ID("x")), name: "x", content: content, isActive: false)
        let result = GlobalSearchResults(documents: [doc], query: "host").results[0]
        XCTAssertEqual(result.matches.count, GlobalSearchResults.matchLimit)
        XCTAssertEqual(result.matches.last?.hit.line, GlobalSearchResults.matchLimit)
        XCTAssertEqual(result.hiddenMatchCount, 250 - GlobalSearchResults.matchLimit)
    }

    func testBlankQueryYieldsNothing() {
        XCTAssertTrue(GlobalSearchResults(documents: [base, dev], query: "  ").results.isEmpty)
    }
}
