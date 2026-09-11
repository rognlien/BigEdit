import XCTest
@testable import BigEdit

/// Sorting by a column keeps the header first, compares naturally, keeps
/// ties in their original order both ways, and respects quoting.
final class CSVSorterTests: XCTestCase {

    private let comma = CSVDialect(delimiter: ",", quote: "\"", hasHeaderRow: true,
                                   pinsHeaderRow: true, trimsFieldWhitespace: false)

    func testSortsByColumnNaturallyAndKeepsTheHeader() {
        let lines = ["name,age", "carol,10", "alice,9", "bob,100"]

        let sorted = CSVSorter.sorted(lines, byColumn: 1, dialect: comma, descending: false)

        XCTAssertEqual(sorted, ["name,age", "alice,9", "carol,10", "bob,100"])
    }

    func testDescendingReversesTheKeysButNotTheTies() {
        let lines = ["name,team", "alice,red", "bob,blue", "carol,red", "dave,blue"]

        let sorted = CSVSorter.sorted(lines, byColumn: 1, dialect: comma, descending: true)

        XCTAssertEqual(sorted, ["name,team", "alice,red", "carol,red", "bob,blue", "dave,blue"])
    }

    func testMissingFieldsSortAsEmpty() {
        let lines = ["a,b", "x,2", "y", "z,1"]

        let sorted = CSVSorter.sorted(lines, byColumn: 1, dialect: comma, descending: false)

        XCTAssertEqual(sorted, ["a,b", "y", "z,1", "x,2"])
    }

    func testQuotedDelimitersStayInsideTheirField() {
        let lines = ["name,city", "\"Smith, John\",Oslo", "Ann,Bergen"]

        let sorted = CSVSorter.sorted(lines, byColumn: 1, dialect: comma, descending: false)

        XCTAssertEqual(sorted, ["name,city", "Ann,Bergen", "\"Smith, John\",Oslo"])
    }

    func testWithoutAHeaderEveryLineIsData() {
        var headerless = comma
        headerless.hasHeaderRow = false
        let lines = ["b,2", "a,1"]

        let sorted = CSVSorter.sorted(lines, byColumn: 0, dialect: headerless, descending: false)

        XCTAssertEqual(sorted, ["a,1", "b,2"])
    }

    func testCancellationReturnsNil() {
        let lines = ["h", "3", "1", "2"]

        let sorted = CSVSorter.sorted(lines, byColumn: 0, dialect: comma, descending: false,
                                      isCancelled: { true })

        XCTAssertNil(sorted)
    }
}
