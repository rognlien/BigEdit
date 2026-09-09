import XCTest
@testable import BigEdit

final class RowScannerTests: XCTestCase {

    private let quote = unichar(UInt8(ascii: "\""))

    func testPeekingOutsideTheRowIsSafe() {
        let scanner = RowScanner("ab")
        XCTAssertEqual(scanner.character(at: 1), unichar(UInt8(ascii: "b")))
        XCTAssertEqual(scanner.character(at: 2), 0)
        XCTAssertEqual(scanner.character(at: -1), 0)
        XCTAssertTrue(scanner.has(unichar(UInt8(ascii: "a")), at: 0))
        XCTAssertFalse(scanner.has(0, at: 2))
    }

    func testLiteralMatching() {
        let scanner = RowScanner("<!-- x -->")
        XCTAssertTrue(scanner.matches("<!--", at: 0))
        XCTAssertFalse(scanner.matches("<!--", at: 1))
        XCTAssertFalse(scanner.matches("-->>", at: 7))
        XCTAssertEqual(scanner.indexAfter("-->", from: 0), 10)
        XCTAssertNil(scanner.indexAfter("-->", from: 8))
        XCTAssertNil(scanner.indexAfter("-->", from: 11))
    }

    func testRunsAndWhitespace() {
        let scanner = RowScanner("  \tabc  ")
        XCTAssertEqual(scanner.leadingSpaceCount, 2)
        XCTAssertEqual(scanner.skipWhitespace(from: 0), 3)
        XCTAssertEqual(scanner.endOfRun(from: 3, while: RowScanner.isLowercaseLetter), 6)
        XCTAssertTrue(scanner.isBlank(from: 6))
        XCTAssertFalse(scanner.isBlank())
        XCTAssertTrue(RowScanner("").isBlank())
    }

    func testQuotedStringStopsAtCloseQuoteOrRowEnd() {
        XCTAssertEqual(RowScanner("\"ab\" c").endOfQuotedString(from: 0, quote: quote, escaping: true), 4)
        XCTAssertEqual(RowScanner("\"a\\\"b\"").endOfQuotedString(from: 0, quote: quote, escaping: true), 6)
        XCTAssertEqual(RowScanner("\"a\\\"b\"").endOfQuotedString(from: 0, quote: quote, escaping: false), 4)
        XCTAssertEqual(RowScanner("\"open").endOfQuotedString(from: 0, quote: quote, escaping: true), 5)
        XCTAssertEqual(RowScanner("\"trailing\\").endOfQuotedString(from: 0, quote: quote, escaping: true), 10)
    }

    func testNumberSweep() {
        XCTAssertEqual(RowScanner("-1.5e+3,").endOfNumber(from: 0), 7)
        XCTAssertEqual(RowScanner("x").endOfNumber(from: 0), 0)
    }

    func testLiteralRequiresBoundary() {
        let candidates = ["true", "false", "null", "no"]
        let boundary: (unichar) -> Bool = { !RowScanner.isIdentifierCharacter($0) }
        XCTAssertEqual(RowScanner("true,").endOfLiteral(in: candidates, at: 0, isBoundary: boundary), 4)
        XCTAssertEqual(RowScanner("null").endOfLiteral(in: candidates, at: 0, isBoundary: boundary), 4)
        XCTAssertNil(RowScanner("truer").endOfLiteral(in: candidates, at: 0, isBoundary: boundary))
        XCTAssertNil(RowScanner("nope").endOfLiteral(in: candidates, at: 0, isBoundary: boundary))
    }
}
