import AppKit
import XCTest
@testable import BigEdit

/// The Control-key line bindings: Control-A and Control-E move to the ends of
/// the logical line, Control-K kills to its end, and Control-Y yanks it back.
final class EmacsKeyBindingTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeViewport(_ text: String, caret: Int) -> (ViewportView, EditedDocument) {
        let url = TestHelpers.writeTempFile(text)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.isEditable = true
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.selection = TextSelection(anchorOffset: caret, activeOffset: caret)
        return (viewport, document)
    }

    private func text(of document: EditedDocument) -> String {
        String(decoding: document.bytes(in: 0..<document.length), as: UTF8.self)
    }

    func testControlAMovesToTheStartOfTheLine() {
        let (viewport, _) = makeViewport("one\ntwo three\n", caret: 7)

        viewport.moveToBeginningOfParagraph(nil)

        XCTAssertEqual(viewport.caretByteOffset, 4)
    }

    func testControlEStopsBeforeTheLineEnding() {
        let (viewport, _) = makeViewport("one\r\ntwo\r\n", caret: 1)

        viewport.moveToEndOfParagraph(nil)

        XCTAssertEqual(viewport.caretByteOffset, 3)
    }

    func testControlEOnTheLastLineWithoutANewline() {
        let (viewport, _) = makeViewport("one\ntwo", caret: 5)

        viewport.moveToEndOfParagraph(nil)

        XCTAssertEqual(viewport.caretByteOffset, 7)
    }

    func testShiftControlASelectsToTheStartOfTheLine() {
        let (viewport, _) = makeViewport("one\ntwo three\n", caret: 7)

        viewport.moveToBeginningOfParagraphAndModifySelection(nil)

        XCTAssertEqual(viewport.selectionByteRange, 4..<7)
    }

    func testAWrappedLineCountsAsOneLine() {
        let long = String(repeating: "x", count: 5000)
        let (viewport, _) = makeViewport("a\n" + long + "\nb\n", caret: 4000)

        viewport.moveToBeginningOfParagraph(nil)
        XCTAssertEqual(viewport.caretByteOffset, 2)

        viewport.moveToEndOfParagraph(nil)
        XCTAssertEqual(viewport.caretByteOffset, 5002)
    }

    func testControlKKillsToTheEndOfTheLine() {
        let (viewport, document) = makeViewport("one two\nthree\n", caret: 3)

        viewport.deleteToEndOfParagraph(nil)

        XCTAssertEqual(text(of: document), "one\nthree\n")
    }

    func testControlKAtTheLineEndJoinsTheNextLine() {
        let (viewport, document) = makeViewport("one\r\ntwo\r\n", caret: 3)

        viewport.deleteToEndOfParagraph(nil)

        XCTAssertEqual(text(of: document), "onetwo\r\n")
    }

    func testControlYYanksTheKilledText() {
        let (viewport, document) = makeViewport("one two\nthree\n", caret: 3)
        viewport.deleteToEndOfParagraph(nil)
        viewport.selection = TextSelection(anchorOffset: 9, activeOffset: 9)

        viewport.yank(nil)

        XCTAssertEqual(text(of: document), "one\nthree two\n")
    }
}
