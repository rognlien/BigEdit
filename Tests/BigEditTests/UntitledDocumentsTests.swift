import XCTest
@testable import BigEdit

/// An untitled document is an empty placeholder file in a directory of its
/// own, named the way TextEdit names its untitled windows.
final class UntitledDocumentsTests: XCTestCase {

    private var untitled: UntitledDocuments!

    override func setUp() {
        super.setUp()
        untitled = TestHelpers.isolatedUntitledDocuments()
    }

    override func tearDown() {
        TestHelpers.remove(untitled.directory)
        super.tearDown()
    }

    func testAPlaceholderIsAnEmptyFileInTheDirectory() throws {
        let url = try XCTUnwrap(untitled.makePlaceholder())
        XCTAssertTrue(untitled.contains(url))
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testEachPlaceholderIsANewFile() throws {
        let first = try XCTUnwrap(untitled.makePlaceholder())
        let second = try XCTUnwrap(untitled.makePlaceholder())
        XCTAssertNotEqual(first, second)
    }

    func testAFileElsewhereIsNotAPlaceholder() {
        let url = TestHelpers.writeTempFile("")
        defer { TestHelpers.remove(url) }
        XCTAssertFalse(untitled.contains(url))
    }

    func testTheFirstIsUntitledAndTheRestAreNumbered() {
        XCTAssertEqual(UntitledDocuments.name(numbered: 1), "Untitled")
        XCTAssertEqual(UntitledDocuments.name(numbered: 2), "Untitled 2")
    }

    func testTheLowestNumberNotInUseIsTaken() {
        XCTAssertEqual(UntitledDocuments.lowestUnusedNumber(among: []), 1)
        XCTAssertEqual(UntitledDocuments.lowestUnusedNumber(among: [1, 2]), 3)
        XCTAssertEqual(UntitledDocuments.lowestUnusedNumber(among: [2, 3]), 1)
        XCTAssertEqual(UntitledDocuments.lowestUnusedNumber(among: [3, 1]), 2)
    }
}
