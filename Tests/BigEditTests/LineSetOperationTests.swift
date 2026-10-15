import XCTest
@testable import BigEdit

/// Set operations between two lists: what `comm`, `grep -Fxf` and
/// `grep -vFxf` do, with the document's order kept.
final class LineSetOperationTests: XCTestCase {

    private func apply(_ kind: SetOperationKind, _ lines: [String], _ other: [String],
                       options: LineMatchOptions = LineMatchOptions()) throws -> [String] {
        try XCTUnwrap(LineProcessor.apply(
            .setOperation(kind, other: other, options: options), to: lines))
    }

    // MARK: - Subtract

    func testSubtractRemovesEveryLineInTheOtherList() throws {
        XCTAssertEqual(try apply(.subtract, ["a", "b", "c", "d"], ["b", "d"]), ["a", "c"])
    }

    func testSubtractKeepsDuplicatesTheOtherListDoesNotName() throws {
        XCTAssertEqual(try apply(.subtract, ["a", "a", "b"], ["b"]), ["a", "a"])
    }

    func testSubtractKeepsTheDocumentOrder() throws {
        XCTAssertEqual(try apply(.subtract, ["z", "y", "x"], ["y"]), ["z", "x"])
    }

    func testSubtractingAnEmptyListChangesNothing() throws {
        XCTAssertEqual(try apply(.subtract, ["a", "b"], []), ["a", "b"])
    }

    // MARK: - Intersect

    func testIntersectKeepsOnlyLinesInBothLists() throws {
        XCTAssertEqual(try apply(.intersect, ["a", "b", "c"], ["c", "a", "q"]), ["a", "c"])
    }

    func testIntersectKeepsDuplicatesOfTheDocument() throws {
        XCTAssertEqual(try apply(.intersect, ["a", "a", "b"], ["a"]), ["a", "a"])
    }

    // MARK: - Union

    func testUnionAppendsOnlyWhatTheDocumentLacks() throws {
        XCTAssertEqual(try apply(.union, ["a", "b"], ["b", "c", "a", "d"]), ["a", "b", "c", "d"])
    }

    func testUnionAppendsEachMissingLineOnce() throws {
        XCTAssertEqual(try apply(.union, ["a"], ["c", "c"]), ["a", "c"])
    }

    // MARK: - Symmetric difference

    func testSymmetricDifferenceKeepsLinesInOnlyOneList() throws {
        XCTAssertEqual(try apply(.symmetricDifference, ["a", "b", "c"], ["b", "d"]),
                       ["a", "c", "d"])
    }

    // MARK: - Matching options

    func testTrimmingIgnoresSurroundingWhitespace() throws {
        let options = LineMatchOptions(trimsWhitespace: true)
        XCTAssertEqual(try apply(.subtract, ["  a ", "b"], ["a"], options: options), ["b"])
        XCTAssertEqual(try apply(.subtract, ["  a ", "b"], ["a"]), ["  a ", "b"])
    }

    func testIgnoringCaseFoldsBothSides() throws {
        let options = LineMatchOptions(ignoresCase: true)
        XCTAssertEqual(try apply(.intersect, ["Apple", "pear"], ["APPLE"], options: options),
                       ["Apple"])
    }

    func testKeyPatternComparesByTheFirstMatch() throws {
        let options = LineMatchOptions(keyPattern: "[0-9]+")
        let lines = ["id 10 alice", "id 20 bob", "id 30 carol"]
        XCTAssertEqual(try apply(.subtract, lines, ["20", "x 30 y"], options: options),
                       ["id 10 alice"])
    }

    func testKeyPatternUsesTheFirstCaptureGroupWhenThereIsOne() throws {
        let options = LineMatchOptions(keyPattern: "^[^,]*,([^,]*)")
        let lines = ["1,alice,x", "2,bob,y"]
        XCTAssertEqual(try apply(.intersect, lines, ["9,bob,z"], options: options), ["2,bob,y"])
    }

    func testALineThePatternDoesNotMatchHasAnEmptyKey() throws {
        let options = LineMatchOptions(keyPattern: "[0-9]+")
        // Both unmatched lines share the empty key, so they count as the same item.
        XCTAssertEqual(try apply(.intersect, ["alpha"], ["beta"], options: options), ["alpha"])
    }

    func testAnInvalidKeyPatternIsReported() {
        let options = LineMatchOptions(keyPattern: "(")
        XCTAssertThrowsError(try LineProcessor.apply(
            .setOperation(.subtract, other: [], options: options), to: ["a"])) { error in
            XCTAssertEqual(error as? LineProcessor.ProcessingError, .invalidPattern("("))
        }
    }

    func testCancellationDiscardsTheResult() throws {
        let result = try LineProcessor.apply(
            .setOperation(.subtract, other: ["a"], options: LineMatchOptions()),
            to: ["a", "b"], isCancelled: { true })
        XCTAssertNil(result)
    }

    // MARK: - The streaming filter

    func testFilterAgreesWithApplyForSubtractAndIntersect() throws {
        let lines = ["a", "b", "c", "b"]
        let other = ["b", "z"]
        for kind in [SetOperationKind.subtract, .intersect] {
            let keep = try XCTUnwrap(LineSetOperation.filter(for: kind, other: other,
                                                              options: LineMatchOptions()))
            XCTAssertEqual(lines.filter(keep), try apply(kind, lines, other))
        }
    }

    func testOnlyTheFilteringKindsStream() throws {
        XCTAssertNil(try LineSetOperation.filter(for: .union, other: [], options: LineMatchOptions()))
        XCTAssertNil(try LineSetOperation.filter(for: .symmetricDifference, other: [],
                                                 options: LineMatchOptions()))
        XCTAssertTrue(SetOperationKind.subtract.isFilter)
        XCTAssertFalse(SetOperationKind.union.isFilter)
    }
}
