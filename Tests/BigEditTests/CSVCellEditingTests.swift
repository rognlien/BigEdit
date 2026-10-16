import XCTest
@testable import BigEdit

/// Text typed into a field stays in it: the field is quoted when the text
/// would otherwise split it, and quotes inside are doubled.
final class CSVCellEditingTests: XCTestCase {

    private func insert(_ text: String, at range: Range<Int>, in field: String,
                        dialect: CSVDialect = CSVDialect()) -> CSVCellEdit? {
        CSVCellEditing.insertion(of: Array(text.utf8), replacing: range, inField: Array(field.utf8),
                                 dialect: dialect, encoding: .utf8)
    }

    func testPlainTextIsInsertedAsIs() {
        XCTAssertEqual(insert("x", at: 1..<1, in: "ab"),
                       CSVCellEdit(range: 1..<1, bytes: Array("x".utf8), bytesAfterCaret: 0))
    }

    func testADelimiterQuotesTheField() {
        XCTAssertEqual(insert(",", at: 1..<1, in: "ab"),
                       CSVCellEdit(range: 0..<2, bytes: Array("\"a,b\"".utf8), bytesAfterCaret: 2))
    }

    func testANewlineQuotesTheField() {
        XCTAssertEqual(insert("\n", at: 2..<2, in: "ab")?.bytes, Array("\"ab\n\"".utf8))
    }

    func testQuotingDoublesQuotesAlreadyInTheField() {
        XCTAssertEqual(insert(",", at: 4..<4, in: "5\" x"),
                       CSVCellEdit(range: 0..<4, bytes: Array("\"5\"\" x,\"".utf8), bytesAfterCaret: 1))
    }

    func testATypedQuoteQuotesTheFieldAndIsDoubled() {
        XCTAssertEqual(insert("\"", at: 0..<0, in: "ab")?.bytes, Array("\"\"\"ab\"".utf8))
    }

    func testAQuotedFieldOnlyGetsTheTextWithQuotesDoubled() {
        XCTAssertEqual(insert("\",", at: 2..<2, in: "\"ab\""),
                       CSVCellEdit(range: 2..<2, bytes: Array("\"\",".utf8), bytesAfterCaret: 0))
    }

    func testAnInsertionIsKeptInsideTheQuotes() {
        XCTAssertEqual(insert("x", at: 4..<4, in: "\"ab\"")?.range, 3..<3, "before the closing quote")
        XCTAssertEqual(insert("x", at: 0..<0, in: "\"ab\"")?.range, 1..<1, "after the opening quote")
    }

    func testReplacingPartOfTheFieldKeepsTheRest() {
        XCTAssertEqual(insert(";", at: 1..<3, in: "abcd", dialect: CSVDialect(delimiter: ";"))?.bytes,
                       Array("\"a;d\"".utf8))
    }

    func testWithoutAQuoteCharacterADelimiterIsRefused() {
        XCTAssertNil(insert(",", at: 1..<1, in: "ab", dialect: CSVDialect(quote: nil)))
        XCTAssertNotNil(insert("\"", at: 1..<1, in: "ab", dialect: CSVDialect(quote: nil)),
                        "a quote is plain text when the dialect has none")
    }

    func testAMultiByteDelimiterIsRecognised() {
        XCTAssertEqual(insert("§", at: 1..<1, in: "ab", dialect: CSVDialect(delimiter: "§"))?.bytes,
                       Array("\"a§b\"".utf8))
    }
}
