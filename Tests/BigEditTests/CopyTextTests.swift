import XCTest
@testable import BigEdit

/// Copying text must match what the viewport shows. The viewport renders only
/// printable text plus tab and newline, so copy drops the control characters it
/// hides — stray Record Separators (U+001E), the CR of CRLF lines, etc. — which
/// would otherwise paste as characters that look inserted.
final class CopyTextTests: XCTestCase {

    private func copy(_ string: String) -> String {
        ViewportView.pasteboardText(fromUTF8: Array(string.utf8))
    }

    func testRecordSeparatorIsStripped() {
        // The real-world bug: a file with U+001E between JSON members.
        XCTAssertEqual(copy("{\"a\":\"x\", \u{1E}\"b\":\"y\"}"),
                       "{\"a\":\"x\", \"b\":\"y\"}")
    }

    func testCRLFLineEndingsBecomeLF() {
        XCTAssertEqual(copy("line one\r\nline two\r\nline three"),
                       "line one\nline two\nline three")
    }

    func testTrailingCarriageReturnIsStripped() {
        XCTAssertEqual(copy("a line\r"), "a line")
    }

    func testTabAndNewlineAreKept() {
        XCTAssertEqual(copy("col1\tcol2\nrow2\tend\n"), "col1\tcol2\nrow2\tend\n")
    }

    func testPlainTextIsUnchanged() {
        XCTAssertEqual(copy("{\"key\":\"value\"}"), "{\"key\":\"value\"}")
    }

    func testMultiByteContentSurvivesStripping() {
        // Multi-byte characters around stripped controls must be preserved.
        XCTAssertEqual(copy("Юн Фосэ\u{1E}ヨン・フォッセ\r\n乔恩·弗斯"),
                       "Юн Фосэヨン・フォッセ\n乔恩·弗斯")
    }

    func testAssortedControlCharactersAreStripped() {
        // NUL, vertical tab, form feed, and the file/group/unit separators.
        XCTAssertEqual(copy("a\u{00}b\u{0B}c\u{0C}d\u{1C}e\u{1D}f\u{1F}g"),
                       "abcdefg")
    }
}
