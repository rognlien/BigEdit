import AppKit
import XCTest
@testable import BigEdit

/// A carriage return, form feed or line separator inside a line is drawn and
/// measured on that line's row instead of breaking it onto the row below.
final class LineBreakingCharacterTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeViewport(_ text: String) -> ViewportView {
        let url = TestHelpers.writeTempFile(text)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        return viewport
    }

    func testTextAfterACarriageReturnKeepsItsColumn() {
        let viewport = makeViewport("ab\rcd\n")
        let row = viewport.layout!.visualLines(forRows: 0..<1).first!

        let end = viewport.xOffset(inRow: row, forByte: 5)

        XCTAssertEqual(end, viewport.characterWidth * 4, accuracy: 0.01)
    }

    func testARowWithALineSeparatorIsDrawnOnOneLine() {
        let viewport = makeViewport("ab\u{2028}cd\u{0C}e\n")
        let row = viewport.layout!.visualLines(forRows: 0..<1).first!

        let drawn = viewport.attributedRow(viewport.decodeChunk(row))

        XCTAssertEqual(drawn.size().height, viewport.attributedRow("abcde").size().height, accuracy: 0.01)
        XCTAssertEqual(drawn.size().width, viewport.characterWidth * 5, accuracy: 0.01)
    }

    func testAClickAfterACarriageReturnLandsAfterIt() {
        let viewport = makeViewport("ab\rcd\n")
        let row = viewport.layout!.visualLines(forRows: 0..<1).first!

        let offset = viewport.byteOffset(inRow: row, atX: viewport.characterWidth * 3.9)

        XCTAssertEqual(offset, 5)
    }

    func testSingleLineTextKeepsEveryOffset() {
        let text = "a\rb\u{85}c\u{2029}d🙂"

        let single = ViewportView.singleLineText(text)

        XCTAssertEqual(single.utf16.count, text.utf16.count)
        XCTAssertEqual(single, "a\u{200B}b\u{200B}c\u{200B}d🙂")
    }
}
