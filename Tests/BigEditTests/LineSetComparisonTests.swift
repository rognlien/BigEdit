import XCTest
@testable import BigEdit

/// The three-way compare is `comm` with the order kept and repeats folded.
final class LineSetComparisonTests: XCTestCase {

    private func compare(_ first: [String], _ second: [String],
                         options: LineMatchOptions = LineMatchOptions()) throws -> LineSetComparison {
        try XCTUnwrap(LineSetComparison.compare(first, second, options: options))
    }

    func testSplitsLinesIntoTheThreeSets() throws {
        let result = try compare(["a", "b", "c"], ["b", "c", "d"])
        XCTAssertEqual(result.onlyInFirst, ["a"])
        XCTAssertEqual(result.onlyInSecond, ["d"])
        XCTAssertEqual(result.inBoth, ["b", "c"])
    }

    func testKeepsEachListsOrder() throws {
        let result = try compare(["z", "y", "x"], ["x", "w", "v"])
        XCTAssertEqual(result.onlyInFirst, ["z", "y"])
        XCTAssertEqual(result.onlyInSecond, ["w", "v"])
        XCTAssertEqual(result.inBoth, ["x"])
    }

    func testListsEachItemOnce() throws {
        let result = try compare(["a", "a", "b", "b"], ["b", "b", "c", "c"])
        XCTAssertEqual(result.onlyInFirst, ["a"])
        XCTAssertEqual(result.onlyInSecond, ["c"])
        XCTAssertEqual(result.inBoth, ["b"])
    }

    func testInBothShowsTheFirstListsSpelling() throws {
        let options = LineMatchOptions(ignoresCase: true)
        let result = try compare(["Apple"], ["APPLE"], options: options)
        XCTAssertEqual(result.inBoth, ["Apple"])
        XCTAssertTrue(result.onlyInSecond.isEmpty)
    }

    func testComparesByKeyPattern() throws {
        let options = LineMatchOptions(keyPattern: "^[^,]*")
        let result = try compare(["1,alice", "2,bob"], ["2,robert", "3,carol"], options: options)
        XCTAssertEqual(result.onlyInFirst, ["1,alice"])
        XCTAssertEqual(result.onlyInSecond, ["3,carol"])
        XCTAssertEqual(result.inBoth, ["2,bob"])
    }

    func testEmptyListsCompareToNothing() throws {
        let result = try compare([], [])
        XCTAssertEqual(result, LineSetComparison(onlyInFirst: [], onlyInSecond: [], inBoth: []))
    }

    func testCancellationReturnsNil() throws {
        XCTAssertNil(try LineSetComparison.compare(["a"], ["b"], isCancelled: { true }))
    }

    func testInvalidKeyPatternThrows() {
        XCTAssertThrowsError(try LineSetComparison.compare(["a"], ["b"],
                                                           options: LineMatchOptions(keyPattern: "[")))
    }
}
