import XCTest
@testable import BigEdit

/// The line operations are whole-document transformations, so they are pure
/// functions of the lines and testable directly. scripts/verify-process-lines.sh
/// additionally diffs them against sort, grep, sed and awk; these cover the
/// edges those tools do not reach.
final class LineProcessorTests: XCTestCase {

    private func apply(_ operation: LineOperation, _ lines: [String]) throws -> [String] {
        try XCTUnwrap(LineProcessor.apply(operation, to: lines))
    }

    // MARK: - Duplicates

    func testRemoveDuplicatesKeepsTheFirstOccurrence() throws {
        let result = try apply(.removeDuplicateLines, ["b", "a", "b", "c", "a"])
        XCTAssertEqual(result, ["b", "a", "c"])
    }

    func testRemoveDuplicatesOnDistinctLinesChangesNothing() throws {
        XCTAssertEqual(try apply(.removeDuplicateLines, ["a", "b"]), ["a", "b"])
    }

    func testRemoveDuplicatesTreatsBlankLinesAsDuplicates() throws {
        XCTAssertEqual(try apply(.removeDuplicateLines, ["", "a", ""]), ["", "a"])
    }

    // MARK: - Filtering

    func testRemoveLinesContaining() throws {
        let operation = LineOperation.removeLinesContaining(pattern: "an", caseSensitive: true)
        XCTAssertEqual(try apply(operation, ["banana", "apple"]), ["apple"])
    }

    func testKeepLinesContaining() throws {
        let operation = LineOperation.keepLinesContaining(pattern: "an", caseSensitive: true)
        XCTAssertEqual(try apply(operation, ["banana", "apple"]), ["banana"])
    }

    func testFilteringCanIgnoreCase() throws {
        let sensitive = LineOperation.removeLinesContaining(pattern: "AN", caseSensitive: true)
        XCTAssertEqual(try apply(sensitive, ["banana"]), ["banana"])
        let insensitive = LineOperation.removeLinesContaining(pattern: "AN", caseSensitive: false)
        XCTAssertEqual(try apply(insensitive, ["banana"]), [])
    }

    func testAnEmptyPatternMatchesEveryLine() throws {
        let operation = LineOperation.removeLinesContaining(pattern: "", caseSensitive: true)
        XCTAssertEqual(try apply(operation, ["a", "b"]), [])
    }

    // MARK: - Sorting

    func testPlainSortIsByCharacter() throws {
        let result = try apply(.sortLines(natural: false, keyPattern: nil), ["b", "A", "a"])
        XCTAssertEqual(result, ["A", "a", "b"])
    }

    func testSortIsStableForEqualKeys() throws {
        // Swift's sort is not stable, so this only holds because ties fall back
        // to the original position. Enough lines to defeat the insertion-sort
        // path a short array would take.
        let operation = LineOperation.sortLines(natural: false, keyPattern: "^[a-z]+")
        let lines = (0..<200).map { "x \($0)" }
        XCTAssertEqual(try apply(operation, lines), lines)
    }

    func testNaturalSortIsAlsoStableForEqualKeys() throws {
        let operation = LineOperation.sortLines(natural: true, keyPattern: "^[a-z]+")
        let lines = (0..<200).map { "x \($0)" }
        XCTAssertEqual(try apply(operation, lines), lines)
    }

    func testSortByRegexKey() throws {
        let operation = LineOperation.sortLines(natural: false, keyPattern: "[0-9]+")
        let result = try apply(operation, ["item 30", "item 10", "item 20"])
        XCTAssertEqual(result, ["item 10", "item 20", "item 30"])
    }

    func testSortByCaptureGroupWhenThereIsOne() throws {
        let operation = LineOperation.sortLines(natural: false, keyPattern: "name=([a-z]+)")
        let result = try apply(operation, ["id=9 name=zoe", "id=1 name=amy"])
        XCTAssertEqual(result, ["id=1 name=amy", "id=9 name=zoe"])
    }

    func testLinesWithoutTheKeySortFirst() throws {
        let operation = LineOperation.sortLines(natural: false, keyPattern: "[0-9]+")
        let result = try apply(operation, ["b 2", "no digits", "a 1"])
        XCTAssertEqual(result.first, "no digits")
    }

    func testInvalidSortKeyIsReported() {
        let operation = LineOperation.sortLines(natural: false, keyPattern: "[unclosed")
        XCTAssertThrowsError(try LineProcessor.apply(operation, to: ["a"])) { error in
            XCTAssertEqual(error as? LineProcessor.ProcessingError,
                           .invalidPattern("[unclosed"))
        }
    }

    // MARK: - Natural order

    func testNaturalOrderComparesDigitRunsByValue() {
        XCTAssertTrue(LineProcessor.naturalPrecedes("file9", "file10"))
        XCTAssertFalse(LineProcessor.naturalPrecedes("file10", "file9"))
    }

    func testNaturalOrderFallsBackToCharacters() {
        XCTAssertTrue(LineProcessor.naturalPrecedes("apple", "banana"))
    }

    func testNaturalOrderPutsAPrefixFirst() {
        XCTAssertTrue(LineProcessor.naturalPrecedes("file", "file1"))
        XCTAssertFalse(LineProcessor.naturalPrecedes("file1", "file"))
    }

    func testNaturalOrderHandlesLeadingZeros() {
        // Equal values, so neither precedes the other.
        XCTAssertFalse(LineProcessor.naturalPrecedes("a007", "a7"))
        XCTAssertFalse(LineProcessor.naturalPrecedes("a7", "a007"))
    }

    func testNaturalOrderSurvivesNumbersTooBigForAnInt() {
        let huge = "x" + String(repeating: "9", count: 40)
        let bigger = "x" + String(repeating: "9", count: 41)
        XCTAssertTrue(LineProcessor.naturalPrecedes(huge, bigger))
    }

    func testNaturalSortOrdersAWholeList() throws {
        let result = try apply(.sortLines(natural: true, keyPattern: nil),
                               ["file10", "file9", "file1", "file20", "file2"])
        XCTAssertEqual(result, ["file1", "file2", "file9", "file10", "file20"])
    }

    // MARK: - Regular expression replacement

    func testReplaceWithinLines() throws {
        let operation = LineOperation.replaceWithinLines(pattern: "a+", replacement: "-")
        XCTAssertEqual(try apply(operation, ["banana", "bbb"]), ["b-n-n-", "bbb"])
    }

    func testReplacementCanReferenceGroups() throws {
        let operation = LineOperation.replaceWithinLines(pattern: "([a-z]+)=([0-9]+)",
                                                         replacement: "$2:$1")
        XCTAssertEqual(try apply(operation, ["width=20"]), ["20:width"])
    }

    func testInvalidReplacementPatternIsReported() {
        let operation = LineOperation.replaceWithinLines(pattern: "(unclosed", replacement: "x")
        XCTAssertThrowsError(try LineProcessor.apply(operation, to: ["a"])) { error in
            XCTAssertEqual(error as? LineProcessor.ProcessingError,
                           .invalidPattern("(unclosed"))
        }
    }

    // MARK: - Empty input and cancellation

    func testEveryOperationHandlesNoLines() throws {
        let operations: [LineOperation] = [
            .removeDuplicateLines,
            .removeLinesContaining(pattern: "a", caseSensitive: true),
            .keepLinesContaining(pattern: "a", caseSensitive: true),
            .sortLines(natural: true, keyPattern: nil),
            .replaceWithinLines(pattern: "a", replacement: "b")
        ]
        for operation in operations {
            XCTAssertEqual(try apply(operation, []), [], "\(operation)")
        }
    }

    func testCancellingDiscardsThePartialResult() throws {
        let lines = (0..<100).map { "line \($0)" }
        let result = try LineProcessor.apply(.removeDuplicateLines, to: lines,
                                             isCancelled: { true })
        XCTAssertNil(result, "a cancelled run must not return half a document")
    }
}
