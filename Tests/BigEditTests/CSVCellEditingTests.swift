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

    private func delete(backward: Bool, at caret: Int, in field: String) -> Range<Int>? {
        CSVCellEditing.deletion(backward: backward, at: caret, inField: Array(field.utf8),
                                dialect: CSVDialect(), encoding: .utf8)
    }

    func testDeletesStopAtTheFieldEdges() {
        XCTAssertNil(delete(backward: true, at: 0, in: "ab"))
        XCTAssertNil(delete(backward: false, at: 2, in: "ab"))
        XCTAssertEqual(delete(backward: true, at: 2, in: "ab"), 1..<2)
        XCTAssertEqual(delete(backward: false, at: 0, in: "ab"), 0..<1)
    }

    func testDeletesStopInsideTheQuotes() {
        XCTAssertNil(delete(backward: true, at: 1, in: "\"ab\""), "after the opening quote")
        XCTAssertNil(delete(backward: false, at: 3, in: "\"ab\""), "before the closing quote")
        XCTAssertEqual(delete(backward: true, at: 4, in: "\"ab\""), 2..<3, "past the closing quote")
    }

    func testADoubledQuoteDeletesAsOne() {
        XCTAssertEqual(delete(backward: true, at: 4, in: "\"a\"\"b\""), 2..<4)
        XCTAssertEqual(delete(backward: false, at: 2, in: "\"a\"\"b\""), 2..<4)
    }

    func testAMultiByteCharacterDeletesAsOne() {
        XCTAssertEqual(delete(backward: true, at: 3, in: "aé"), 1..<3)
        XCTAssertEqual(delete(backward: false, at: 1, in: "aé"), 1..<3)
    }

    func testAnEmptyFieldHasNothingToDelete() {
        XCTAssertNil(delete(backward: true, at: 0, in: ""))
        XCTAssertNil(delete(backward: false, at: 0, in: ""))
    }

    private func clear(_ range: Range<Int>, in text: String) -> CSVCellEdit? {
        CSVCellEditing.clearing(range, in: Array(text.utf8), dialect: CSVDialect(), encoding: .utf8)
    }

    func testClearingInsideOneValueIsAPlainDelete() {
        XCTAssertEqual(clear(1..<3, in: "abcd,e"), CSVCellEdit(range: 1..<3, bytes: [], bytesAfterCaret: 0))
    }

    func testClearingSeveralCellsKeepsTheDelimiters() {
        XCTAssertEqual(clear(1..<8, in: "ab,cd,ef"),
                       CSVCellEdit(range: 1..<8, bytes: Array(",,".utf8), bytesAfterCaret: 2))
    }

    func testClearingKeepsQuotesAndLineEndings() {
        XCTAssertEqual(clear(0..<12, in: "\"a,b\",c\r\nd,e"),
                       CSVCellEdit(range: 1..<12, bytes: Array("\",\r\n,".utf8), bytesAfterCaret: 5),
                       "from inside the opening quote to the end")
    }

    func testClearingOnlyDelimitersHasNothingToDo() {
        XCTAssertNil(clear(2..<4, in: "ab,,cd"))
    }
}
