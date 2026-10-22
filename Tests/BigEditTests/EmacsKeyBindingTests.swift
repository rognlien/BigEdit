import AppKit
import XCTest
@testable import BigEdit

/// The emacs bindings in the standard key bindings: Control-F, B, N and P
/// move by character and line, Control-A and Control-E move to the ends of
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

    /// Presses `key` with Control, and Shift when `key` is upper case, so the
    /// standard key bindings pick the action.
    private func pressControl(_ key: Character, option: Bool = false, in viewport: ViewportView) {
        var flags: NSEvent.ModifierFlags = [.control]
        if key.isUppercase { flags.insert(.shift) }
        if option { flags.insert(.option) }
        let control = String(UnicodeScalar(key.asciiValue! & 0x1F))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: control, charactersIgnoringModifiers: String(key),
                                     isARepeat: false, keyCode: 0)!
        viewport.keyDown(with: event)
    }

    func testControlFAndControlBStepOverWholeCharacters() {
        let (viewport, _) = makeViewport("a👍🏽b", caret: 1)

        pressControl("f", in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 9)
        pressControl("b", in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 1)
    }

    func testShiftControlFAndShiftControlBExtendTheSelection() {
        let (viewport, _) = makeViewport("one two", caret: 4)

        pressControl("F", in: viewport)
        pressControl("F", in: viewport)
        XCTAssertEqual(viewport.selectionByteRange, 4..<6)
        pressControl("B", in: viewport)
        XCTAssertEqual(viewport.selectionByteRange, 4..<5)
    }

    func testControlFCollapsesASelectionToItsEnd() {
        let (viewport, _) = makeViewport("one two", caret: 0)
        viewport.selection = TextSelection(anchorOffset: 4, activeOffset: 1)

        viewport.moveForward(nil)

        XCTAssertNil(viewport.selectionByteRange)
        XCTAssertEqual(viewport.caretByteOffset, 4)
    }

    func testOptionControlFAndBMoveByWord() {
        let (viewport, _) = makeViewport("one, two three", caret: 0)

        pressControl("f", option: true, in: viewport)
        pressControl("f", option: true, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 8)
        pressControl("b", option: true, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 5)
        pressControl("F", option: true, in: viewport)
        XCTAssertEqual(viewport.selectionByteRange, 5..<8)
    }

    func testControlNAndControlPMoveBetweenLines() {
        let (viewport, _) = makeViewport("one\ntwo\n", caret: 1)

        pressControl("n", in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 5)
        pressControl("p", in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 1)
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

    func testCommandBackspaceDeletesToTheStartOfTheLineAndKeepsIt() {
        let (viewport, document) = makeViewport("one two\nthree four\n", caret: 14)

        viewport.deleteToBeginningOfLine(nil)
        XCTAssertEqual(text(of: document), "one two\nfour\n")
        viewport.selection = TextSelection(anchorOffset: 0, activeOffset: 0)
        viewport.yank(nil)

        XCTAssertEqual(text(of: document), "three one two\nfour\n")
    }

    func testCommandBackspaceAtTheStartOfALineLeavesItAlone() {
        let (viewport, document) = makeViewport("one\r\ntwo\r\n", caret: 5)

        viewport.deleteToBeginningOfLine(nil)

        XCTAssertEqual(text(of: document), "one\r\ntwo\r\n")
    }

    func testCommandBackspaceDeletesASelection() {
        let (viewport, document) = makeViewport("one two\nthree four\n", caret: 0)
        viewport.selection = TextSelection(anchorOffset: 9, activeOffset: 13)

        viewport.deleteToBeginningOfLine(nil)

        XCTAssertEqual(text(of: document), "one two\nt four\n")
    }

    func testCommandBackspaceInACSVRowKeepsTheDelimiters() {
        let (viewport, document) = makeViewport("ab,cd,ef\n", caret: 7)
        let dialect = CSVDialect()
        viewport.setCSVRendering(dialect: dialect,
                                 columnLayout: CSVColumnLayout.measure(file: document.file, dialect: dialect,
                                                                       encoding: .utf8))

        viewport.deleteToBeginningOfLine(nil)

        XCTAssertEqual(text(of: document), ",,f\n")
    }

    func testControlTTransposesAsNSTextViewDoes() {
        let samples = ["abcd\nef", "a👍🏽b\ncafe\u{301}!", "x", "ab\n\ncd"]
        for sample in samples {
            var index = sample.startIndex
            while true {
                let (viewport, document) = makeViewport(sample, caret: sample[..<index].utf8.count)
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
                view.string = sample
                view.setSelectedRange(NSRange(location: sample[..<index].utf16.count, length: 0))

                viewport.transpose(nil)
                view.transpose(nil)

                let caret = String(view.string.utf16.prefix(view.selectedRange().location))!.utf8.count
                XCTAssertEqual(text(of: document), view.string, "at \(sample[..<index].debugDescription)")
                XCTAssertEqual(viewport.caretByteOffset, caret, "at \(sample[..<index].debugDescription)")
                if index == sample.endIndex { break }
                index = sample.index(after: index)
            }
        }
    }

    func testControlTKeepsACRLFPairTogether() {
        let (viewport, document) = makeViewport("ab\r\ncd", caret: 4)

        pressControl("t", in: viewport)

        XCTAssertEqual(text(of: document), "abc\r\nd")
        XCTAssertEqual(viewport.caretByteOffset, 5)
    }

    func testControlTLeavesASelectionAlone() {
        let (viewport, document) = makeViewport("abcd", caret: 0)
        viewport.selection = TextSelection(anchorOffset: 1, activeOffset: 3)

        viewport.transpose(nil)

        XCTAssertEqual(text(of: document), "abcd")
    }

    func testControlTInACSVCellNeverMovesADelimiter() {
        let (viewport, document) = makeViewport("ab,cd\n", caret: 2)
        let dialect = CSVDialect()
        viewport.setCSVRendering(dialect: dialect,
                                 columnLayout: CSVColumnLayout.measure(file: document.file, dialect: dialect,
                                                                       encoding: .utf8))

        viewport.transpose(nil)
        XCTAssertEqual(text(of: document), "ab,cd\n")
        viewport.selection = TextSelection(anchorOffset: 4, activeOffset: 4)
        viewport.transpose(nil)

        XCTAssertEqual(text(of: document), "ab,dc\n")
    }

    func testControlOOpensALineAfterTheCaret() {
        let (viewport, document) = makeViewport("abc\n", caret: 1)

        pressControl("o", in: viewport)

        XCTAssertEqual(text(of: document), "a\nbc\n")
        XCTAssertEqual(viewport.caretByteOffset, 1)
    }

    func testOptionReturnTypesALineBreakIntoACSVCell() {
        let (viewport, document) = makeViewport("ab,cd\n", caret: 1)
        let dialect = CSVDialect()
        viewport.setCSVRendering(dialect: dialect,
                                 columnLayout: CSVColumnLayout.measure(file: document.file, dialect: dialect,
                                                                       encoding: .utf8))

        viewport.insertNewlineIgnoringFieldEditor(nil)

        XCTAssertEqual(text(of: document), "\"a\nb\",cd\n")
        XCTAssertEqual(viewport.caretByteOffset, 3)
    }

    func testOptionShiftUpAndDownSelectByParagraphAsNSTextViewDoes() {
        let sample = "one\ntwo\n\nthree"
        for caret in 0...sample.utf8.count {
            for forward in [true, false] {
                let (viewport, _) = makeViewport(sample, caret: caret)
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
                view.string = sample
                view.setSelectedRange(NSRange(location: caret, length: 0))
                for _ in 0..<2 {
                    if forward {
                        viewport.moveParagraphForwardAndModifySelection(nil)
                        view.moveParagraphForwardAndModifySelection(nil)
                    } else {
                        viewport.moveParagraphBackwardAndModifySelection(nil)
                        view.moveParagraphBackwardAndModifySelection(nil)
                    }
                }

                let expected = Range(view.selectedRange())!
                XCTAssertEqual(viewport.selectionByteRange ?? caret..<caret, expected, "from \(caret)")
            }
        }
    }

    private func numberedLines(_ count: Int) -> String {
        (0..<count).map { String(format: "%03d\n", $0) }.joined()
    }

    func testControlVMovesTheCaretAndTheViewDownAPage() {
        let (viewport, _) = makeViewport(numberedLines(200), caret: 4 * 2)
        let page = viewport.rowsPerPage - 1

        pressControl("v", in: viewport)

        XCTAssertEqual(viewport.caretByteOffset, 4 * (2 + page))
        XCTAssertEqual(viewport.scrollRow, Double(page), accuracy: 0.01)
    }

    func testShiftControlVSelectsAPageDown() {
        let (viewport, _) = makeViewport(numberedLines(200), caret: 4)
        let page = viewport.rowsPerPage - 1

        pressControl("V", in: viewport)

        XCTAssertEqual(viewport.selectionByteRange, 4..<(4 * (1 + page)))
    }

    func testPageUpMovesTheCaretBackAndStopsAtTheTop() {
        let (viewport, _) = makeViewport(numberedLines(200), caret: 4 * 3)

        viewport.pageDown(nil)
        viewport.pageUp(nil)
        XCTAssertEqual(viewport.caretByteOffset, 4 * 3)
        viewport.pageUpAndModifySelection(nil)

        XCTAssertEqual(viewport.selectionByteRange, 0..<(4 * 3))
        XCTAssertEqual(viewport.scrollRow, 0, accuracy: 0.01)
    }

    func testControlYYanksTheKilledText() {
        let (viewport, document) = makeViewport("one two\nthree\n", caret: 3)
        viewport.deleteToEndOfParagraph(nil)
        viewport.selection = TextSelection(anchorOffset: 9, activeOffset: 9)

        viewport.yank(nil)

        XCTAssertEqual(text(of: document), "one\nthree two\n")
    }
}
