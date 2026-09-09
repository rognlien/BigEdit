import XCTest
@testable import BigEdit

/// Sorting a file must not also rewrite its line endings, so splitting and
/// rejoining has to be exactly lossless when nothing changes.
final class LineDocumentTests: XCTestCase {

    private let unix: [UInt8] = [0x0A]
    private let windows: [UInt8] = [0x0D, 0x0A]

    private func roundTrip(_ text: String, newline: [UInt8]) -> String {
        let document = LineDocument(bytes: Array(text.utf8), newline: newline)
        return String(decoding: document.bytes(from: document.lines), as: UTF8.self)
    }

    func testUnixRoundTripIsLossless() {
        for text in ["a\nb\n", "a\nb", "", "\n", "one line", "a\n\nb\n"] {
            XCTAssertEqual(roundTrip(text, newline: unix), text, text.debugDescription)
        }
    }

    func testWindowsRoundTripIsLossless() {
        for text in ["a\r\nb\r\n", "a\r\nb", "\r\n"] {
            XCTAssertEqual(roundTrip(text, newline: windows), text, text.debugDescription)
        }
    }

    func testLinesExcludeTheirTerminators() {
        let document = LineDocument(bytes: Array("alpha\r\nbeta\r\n".utf8), newline: windows)
        XCTAssertEqual(document.lines, ["alpha", "beta"])
        XCTAssertTrue(document.endedWithNewline)
    }

    func testAFileWithoutATrailingNewlineKeepsNotHavingOne() {
        let document = LineDocument(bytes: Array("alpha\nbeta".utf8), newline: unix)
        XCTAssertFalse(document.endedWithNewline)
        XCTAssertEqual(String(decoding: document.bytes(from: ["x", "y"]), as: UTF8.self), "x\ny")
    }

    func testAFileWithATrailingNewlineKeepsHavingOne() {
        let document = LineDocument(bytes: Array("alpha\nbeta\n".utf8), newline: unix)
        XCTAssertEqual(String(decoding: document.bytes(from: ["x", "y"]), as: UTF8.self), "x\ny\n")
    }

    func testEmptyDocument() {
        let document = LineDocument(bytes: [], newline: unix)
        XCTAssertEqual(document.lines, [])
        XCTAssertFalse(document.endedWithNewline)
        XCTAssertEqual(document.bytes(from: []), [])
    }

    func testRemovingEveryLineLeavesNothing() {
        let document = LineDocument(bytes: Array("a\nb\n".utf8), newline: unix)
        XCTAssertEqual(document.bytes(from: []), [])
    }

    func testACRThatIsNotPartOfACRLFPairSurvives() {
        // A lone CR is content, not a terminator.
        let document = LineDocument(bytes: Array("a\rb\n".utf8), newline: unix)
        XCTAssertEqual(document.lines, ["a\rb"])
    }
}
