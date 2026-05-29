import XCTest
@testable import BigEdit

final class LineIndexTests: XCTestCase {

    func testLineCountMatchesExpected() {
        let cases: [(String, Int)] = [
            ("abc\ndef", 2),         // No trailing newline; trailing partial counts.
            ("abc\ndef\n", 2),       // Trailing newline; same line count.
            ("", 0),                 // Empty file.
            ("a\n\n\nb\n", 4),       // Blank lines included.
            ("single line", 1)       // One unterminated line.
        ]
        for (content, expected) in cases {
            let url = TestHelpers.writeTempFile(content)
            defer { TestHelpers.remove(url) }
            guard let file = MappedFile(path: url.path) else {
                XCTFail("Could not map file for content: \(content)")
                continue
            }
            let index = LineIndex()
            index.buildSynchronously(from: file)
            XCTAssertEqual(index.count, expected, "Wrong line count for \(content.debugDescription)")
            XCTAssertTrue(index.isComplete)
        }
    }

    func testVisualRowForDocumentLine() {
        let content = "alpha\nbeta\ngamma\ndelta\n"
        let url = TestHelpers.writeTempFile(content)
        defer { TestHelpers.remove(url) }
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        // No long lines → visual row equals document line.
        XCTAssertEqual(index.visualRow(forDocumentLine: 0, file: file), 0)
        XCTAssertEqual(index.visualRow(forDocumentLine: 1, file: file), 1)
        XCTAssertEqual(index.visualRow(forDocumentLine: 2, file: file), 2)
        XCTAssertEqual(index.visualRow(forDocumentLine: 3, file: file), 3)
        // Beyond range clamps to last.
        XCTAssertEqual(index.visualRow(forDocumentLine: 999, file: file), 3)
    }

    func testVisualLineByteRangesCoverWholeLines() {
        let content = "first\nsecond\nthird"  // No trailing newline.
        let url = TestHelpers.writeTempFile(content)
        defer { TestHelpers.remove(url) }
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)

        let rows = index.visualLines(forRows: 0..<3, file: file)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].byteRange, 0..<5)        // "first"
        XCTAssertEqual(rows[1].byteRange, 6..<12)       // "second"
        XCTAssertEqual(rows[2].byteRange, 13..<18)      // "third"
    }
}
