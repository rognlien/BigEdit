import XCTest
@testable import BigEdit

/// A column added to or removed from every row, byte for byte.
final class CSVColumnEditingTests: XCTestCase {

    private func applying(_ change: CSVColumnChange, to text: String, dialect: CSVDialect = CSVDialect(),
                          encoding: TextEncoding = .utf8) -> String? {
        CSVColumnEditing.applying(change, to: encoding.encode(text)!, dialect: dialect, encoding: encoding)
            .map(encoding.decode)
    }

    func testInsertingAColumnBeforeTheFirst() {
        XCTAssertEqual(applying(.insertion(before: 0, widthOf: 0), to: "a,b\n1,2\n"), ",a,b\n,1,2\n")
    }

    func testInsertingAColumnInTheMiddle() {
        XCTAssertEqual(applying(.insertion(before: 1, widthOf: 0), to: "a,b\n1,2\n"), "a,,b\n1,,2\n")
    }

    func testInsertingAColumnAfterTheLast() {
        XCTAssertEqual(applying(.insertion(before: 2, widthOf: 1), to: "a,b\n1,2"), "a,b,\n1,2,")
    }

    func testAShortRowIsLeftAloneWhenTheColumnIsBeyondIt() {
        XCTAssertEqual(applying(.insertion(before: 2, widthOf: 1), to: "a,b,c\n1\n"), "a,b,,c\n1\n")
    }

    func testEmptyLinesAreLeftAlone() {
        XCTAssertEqual(applying(.insertion(before: 0, widthOf: 0), to: "a,b\n\n1,2\n"), ",a,b\n\n,1,2\n")
        XCTAssertEqual(applying(.removal(of: 0), to: "a,b\n\n1,2\n"), "b\n\n2\n")
    }

    func testQuotedDelimitersStayInTheirField() {
        XCTAssertEqual(applying(.insertion(before: 1, widthOf: 0), to: "\"x,y\",2\n"), "\"x,y\",,2\n")
        XCTAssertEqual(applying(.removal(of: 0), to: "\"x,y\",2\n\"say \"\"hi\"\"\",3\n"), "2\n3\n")
        XCTAssertEqual(applying(.removal(of: 1), to: "1,\"x,y\",2\n"), "1,2\n")
    }

    func testCRLFEndingsAreKept() {
        XCTAssertEqual(applying(.insertion(before: 2, widthOf: 0), to: "a,b\r\n1,2\r\n"), "a,b,\r\n1,2,\r\n")
        XCTAssertEqual(applying(.removal(of: 1), to: "a,b\r\n1,2\r\n"), "a\r\n1\r\n")
    }

    func testRemovingTheFirstColumnTakesTheDelimiterAfterIt() {
        XCTAssertEqual(applying(.removal(of: 0), to: "a,b,c\n1,2,3\n"), "b,c\n2,3\n")
    }

    func testRemovingTheLastColumnTakesTheDelimiterBeforeIt() {
        XCTAssertEqual(applying(.removal(of: 2), to: "a,b,c\n1,2,3"), "a,b\n1,2")
    }

    func testRemovingTheOnlyColumnEmptiesTheRow() {
        XCTAssertEqual(applying(.removal(of: 0), to: "a\nb\n"), "\n\n")
    }

    func testRemovingAColumnAShortRowLacks() {
        XCTAssertEqual(applying(.removal(of: 2), to: "a,b,c\n1,2\n"), "a,b\n1,2\n")
    }

    func testWindows1252BytesPassThrough() {
        let dialect = CSVDialect(delimiter: ";")
        XCTAssertEqual(applying(.insertion(before: 1, widthOf: 0), to: "navn;by\nÅse;Ørsta\n", dialect: dialect,
                                encoding: .windows1252), "navn;;by\nÅse;;Ørsta\n")
        XCTAssertEqual(applying(.removal(of: 0), to: "navn;by\nÅse;Ørsta\n", dialect: dialect,
                                encoding: .windows1252), "by\nØrsta\n")
    }

    func testTabSeparatedColumns() {
        XCTAssertEqual(applying(.insertion(before: 1, widthOf: 0), to: "a\tb\n", dialect: CSVDialect(delimiter: "\t")),
                       "a\t\tb\n")
    }

    func testCancellingReturnsNil() {
        let text = String(repeating: "a,b\n", count: 10_000)
        XCTAssertNil(CSVColumnEditing.applying(.removal(of: 0), to: Array(text.utf8), dialect: CSVDialect(),
                                               encoding: .utf8, isCancelled: { true }))
    }
}
