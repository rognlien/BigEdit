import XCTest
@testable import BigEdit

final class SearchScanTests: XCTestCase {

    func testCaseSensitiveMatchesArePreciseAndNonOverlapping() {
        let content = "foofoo foo bar Foo"   // "Foo" should NOT match in case-sensitive mode.
        let url = TestHelpers.writeTempFile(content)
        defer { TestHelpers.remove(url) }
        let file = MappedFile(path: url.path)!
        let scan = SearchScan(query: "foo", caseSensitive: true)!
        scan.runSynchronously(in: file)
        XCTAssertEqual(scan.matchCount, 3)
        XCTAssertEqual(scan.matchOffset(at: 0), 0)
        XCTAssertEqual(scan.matchOffset(at: 1), 3)   // Non-overlapping: next match starts after the first.
        XCTAssertEqual(scan.matchOffset(at: 2), 7)
    }

    func testCaseInsensitiveMatchesAdditionalCases() {
        let content = "foofoo foo bar Foo FOO"
        let url = TestHelpers.writeTempFile(content)
        defer { TestHelpers.remove(url) }
        let file = MappedFile(path: url.path)!
        let scan = SearchScan(query: "foo", caseSensitive: false)!
        scan.runSynchronously(in: file)
        XCTAssertEqual(scan.matchCount, 5)
        XCTAssertEqual(scan.matchOffset(at: 3), 15)  // "Foo"
        XCTAssertEqual(scan.matchOffset(at: 4), 19)  // "FOO"
    }

    func testNoMatchesReturnsZero() {
        let content = "the quick brown fox"
        let url = TestHelpers.writeTempFile(content)
        defer { TestHelpers.remove(url) }
        let file = MappedFile(path: url.path)!
        let scan = SearchScan(query: "zzz", caseSensitive: true)!
        scan.runSynchronously(in: file)
        XCTAssertEqual(scan.matchCount, 0)
        XCTAssertTrue(scan.isComplete)
    }

    func testEmptyQueryFailsInit() {
        XCTAssertNil(SearchScan(query: ""))
    }
}
