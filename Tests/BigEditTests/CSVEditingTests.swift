import AppKit
import XCTest
@testable import BigEdit

/// Typing under aligned CSV columns goes into the cell under the caret, and
/// a column widens to fit what was typed.
final class CSVEditingTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeViewport(_ text: String, dialect: CSVDialect = CSVDialect()) -> (ViewportView, EditedDocument) {
        let url = TestHelpers.writeTempFile(text)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.isEditable = true
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.setCSVRendering(dialect: dialect,
                                 columnLayout: CSVColumnLayout.measure(file: file, dialect: dialect, encoding: .utf8))
        return (viewport, document)
    }

    private func text(of document: EditedDocument) -> String {
        String(decoding: document.bytes(in: 0..<document.length), as: UTF8.self)
    }

    func testEditingIsAllowedUnderColumns() {
        let (viewport, _) = makeViewport("name,age\nbob,2\n")

        XCTAssertTrue(viewport.isEditingAllowed)
    }

    func testTypingLandsInTheCellUnderTheCaret() {
        let (viewport, document) = makeViewport("name,age\nbob,2\n")
        let secondRow = viewport.layout!.visualLines(forRows: 1..<2).first!
        // Click just after "bob" in the padded first cell of the second row.
        let afterBob = secondRow.byteRange.lowerBound
            + viewport.csvRowMap(for: secondRow)!.byteOffset(forDisplayColumn: 3)
        XCTAssertEqual(afterBob, "name,age\nbob".utf8.count)

        viewport.performEdit(replacing: afterBob..<afterBob, with: Array("by".utf8))

        XCTAssertEqual(text(of: document), "name,age\nbobby,2\n")
    }

    func testAColumnWidensToFitTypedText() {
        let (viewport, _) = makeViewport("name,age\nbob,2\n")
        XCTAssertEqual(viewport.csvColumnLayout?.columnWidths, [4, 3])
        let secondRow = viewport.layout!.visualLines(forRows: 1..<2).first!
        let afterBob = secondRow.byteRange.lowerBound + 3

        viewport.performEdit(replacing: afterBob..<afterBob, with: Array("erella".utf8))

        XCTAssertEqual(viewport.csvColumnLayout?.columnWidths, [9, 3], "the name column grew to fit")
    }

    func testTabSelectsTheNextCellAndShiftTabThePrevious() {
        let (viewport, document) = makeViewport("name,age\nbob,42\n")
        let secondRow = viewport.layout!.visualLines(forRows: 1..<2).first!
        let start = secondRow.byteRange.lowerBound
        viewport.selection = TextSelection(anchorOffset: start + 1, activeOffset: start + 1)

        viewport.insertTab(nil)
        XCTAssertEqual(viewport.selection?.range, (start + 4)..<(start + 6), "42 is selected")

        viewport.insertBacktab(nil)
        XCTAssertEqual(viewport.selection?.range, start..<(start + 3), "bob is selected")
        XCTAssertEqual(text(of: document), "name,age\nbob,42\n", "moving edits nothing")
    }

    func testOptionTabTypesATabInsideACell() {
        let (viewport, document) = makeViewport("name,age\nbob,42\n")
        let secondRow = viewport.layout!.visualLines(forRows: 1..<2).first!
        let insideBob = secondRow.byteRange.lowerBound + 1
        viewport.selection = TextSelection(anchorOffset: insideBob, activeOffset: insideBob)

        viewport.insertTabIgnoringFieldEditor(nil)

        XCTAssertEqual(text(of: document), "name,age\nb\tob,42\n")
    }

    func testTabPastTheLastColumnAddsOne() {
        let (viewport, document) = makeViewport("name,age\nbob,42\nann,7\n")
        let secondRow = viewport.layout!.visualLines(forRows: 1..<2).first!
        let inAge = secondRow.byteRange.lowerBound + 5
        viewport.selection = TextSelection(anchorOffset: inAge, activeOffset: inAge)

        viewport.insertTab(nil)

        XCTAssertEqual(text(of: document), "name,age\nbob,42,\nann,7\n")
        let lineEnd = secondRow.byteRange.lowerBound + 7
        XCTAssertEqual(viewport.selection?.range, lineEnd..<lineEnd, "the caret is in the new cell")
        XCTAssertEqual(viewport.csvColumnLayout?.columnWidths.count, 3)
    }

    func testTabPastTheLastColumnFillsAShortRow() {
        let (viewport, document) = makeViewport("name,age\nbob\n")
        let secondRow = viewport.layout!.visualLines(forRows: 1..<2).first!
        let lineEnd = secondRow.byteRange.lowerBound + 3
        viewport.selection = TextSelection(anchorOffset: lineEnd, activeOffset: lineEnd)
        viewport.csvCaretColumn = 1

        viewport.insertTab(nil)

        XCTAssertEqual(text(of: document), "name,age\nbob,,\n")
    }

    func testTypingIntoTheAddedColumnWidensIt() {
        let (viewport, document) = makeViewport("name,age\nbob,42\n")
        let secondRow = viewport.layout!.visualLines(forRows: 1..<2).first!
        let inAge = secondRow.byteRange.lowerBound + 5
        viewport.selection = TextSelection(anchorOffset: inAge, activeOffset: inAge)
        viewport.insertTab(nil)

        viewport.insertText("Oslo", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(text(of: document), "name,age\nbob,42,Oslo\n")
        XCTAssertEqual(viewport.csvColumnLayout?.columnWidths, [4, 3, 4])
    }

    func testTypingIntoAMissingCellCreatesIt() {
        let (viewport, document) = makeViewport("name,age,city\n\nbob,42,Oslo\n")
        let emptyRow = viewport.layout!.visualLines(forRows: 1..<2).first!
        let lineEnd = emptyRow.byteRange.lowerBound
        viewport.selection = TextSelection(anchorOffset: lineEnd, activeOffset: lineEnd)
        viewport.csvCaretColumn = 2                    // what a click in the city column records

        viewport.performEdit(replacing: lineEnd..<lineEnd, with: Array("Rome".utf8))

        XCTAssertEqual(text(of: document), "name,age,city\n,,Rome\nbob,42,Oslo\n")
        XCTAssertNil(viewport.csvCaretColumn, "the cell exists now")
    }

    func testTabIntoAMissingCellParksTheCaretThere() {
        let (viewport, document) = makeViewport("name,age,city\nbob\n")
        let secondRow = viewport.layout!.visualLines(forRows: 1..<2).first!
        let start = secondRow.byteRange.lowerBound
        viewport.selection = TextSelection(anchorOffset: start + 1, activeOffset: start + 1)

        viewport.insertTab(nil)
        XCTAssertEqual(viewport.csvCaretColumn, 1)
        XCTAssertEqual(viewport.selection?.range, (start + 3)..<(start + 3), "at the line's end")

        viewport.insertTab(nil)
        XCTAssertEqual(viewport.csvCaretColumn, 2)

        viewport.performEdit(replacing: (start + 3)..<(start + 3), with: Array("Oslo".utf8))
        XCTAssertEqual(text(of: document), "name,age,city\nbob,,Oslo\n")
    }

    func testClickBeyondTheLastCellReportsItsColumn() {
        let (viewport, _) = makeViewport("name,age,city\n\nbob,42,Oslo\n")
        let dividers = viewport.csvDividerPositions()
        let cityX = dividers[1] + 4
        let emptyRowY = 1.5 * viewport.lineHeight
        let bobRowY = 2.5 * viewport.lineHeight

        XCTAssertEqual(viewport.csvVirtualColumn(at: NSPoint(x: cityX, y: emptyRowY)), 2)
        XCTAssertNil(viewport.csvVirtualColumn(at: NSPoint(x: cityX, y: bobRowY)), "bob's row has that cell")
    }

    func testTheRowMapFollowsAnEdit() {
        let (viewport, _) = makeViewport("name,age\nbob,2\n")
        let secondRow = viewport.layout!.visualLines(forRows: 1..<2).first!
        _ = viewport.csvRowMap(for: secondRow)     // cached for the row as it was
        let afterBob = secondRow.byteRange.lowerBound + 3

        viewport.performEdit(replacing: afterBob..<afterBob, with: Array("by".utf8))

        let editedRow = viewport.layout!.visualLines(forRows: 1..<2).first!
        let map = viewport.csvRowMap(for: editedRow)!
        XCTAssertEqual(map.cells[0].byteRange, 0..<5, "bobby")
        XCTAssertEqual(map.cells[1].byteRange, 6..<7)
    }

    private func type(_ text: String, into viewport: ViewportView) {
        viewport.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func placeCaret(_ viewport: ViewportView, at offset: Int) {
        viewport.selection = TextSelection(anchorOffset: offset, activeOffset: offset)
    }

    func testATypedDelimiterQuotesItsCell() {
        let (viewport, document) = makeViewport("name,age\nbob,2\n")
        placeCaret(viewport, at: "name,age\nbo".utf8.count)

        type(",", into: viewport)

        XCTAssertEqual(text(of: document), "name,age\n\"bo,b\",2\n")
        XCTAssertEqual(viewport.selection?.range, 13..<13, "the caret follows the comma, inside the quotes")
        XCTAssertEqual(viewport.csvRowMap(for: viewport.layout!.visualLines(forRows: 1..<2).first!)!.cells.count, 2,
                       "the row still has two cells")
    }

    func testTypingAfterTheQuotingStaysInTheCell() {
        let (viewport, document) = makeViewport("name,age\nbob,2\n")
        placeCaret(viewport, at: "name,age\nbob".utf8.count)

        type(",", into: viewport)
        type(" jr", into: viewport)

        XCTAssertEqual(text(of: document), "name,age\n\"bob, jr\",2\n")
    }

    func testATypedQuoteIsDoubledInsideTheQuotedCell() {
        let (viewport, document) = makeViewport("name,age\nsay hi,2\n")
        placeCaret(viewport, at: "name,age\nsay ".utf8.count)

        type("\"", into: viewport)

        XCTAssertEqual(text(of: document), "name,age\n\"say \"\"hi\",2\n")
    }

    func testTypingIntoAQuotedCellOnlyInserts() {
        let (viewport, document) = makeViewport("name,age\n\"a,b\",2\n")
        placeCaret(viewport, at: "name,age\n\"a".utf8.count)

        type(";\",", into: viewport)

        XCTAssertEqual(text(of: document), "name,age\n\"a;\"\",,b\",2\n")
    }

    func testPastingADelimiterQuotesTheCell() {
        let (viewport, document) = makeViewport("name,age\nbob,2\n")
        placeCaret(viewport, at: "name,age\nbob,".utf8.count)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("1,5", forType: .string)

        viewport.paste(nil)

        XCTAssertEqual(text(of: document), "name,age\nbob,\"1,52\"\n")
    }

    func testQuotingUndoesAsOneStepWithTheTypedText() {
        let original = "name,age\nbob,2\n"
        let (viewport, document) = makeViewport(original)
        placeCaret(viewport, at: "name,age\nbob".utf8.count)

        type(",", into: viewport)
        viewport.undo(nil)

        XCTAssertEqual(text(of: document), original)
        viewport.redo(nil)
        XCTAssertEqual(text(of: document), "name,age\n\"bob,\",2\n")
    }

    func testADelimiterTypedIntoAMissingCellIsQuoted() {
        let (viewport, document) = makeViewport("name,age,city\n\n")
        let lineEnd = "name,age,city\n".utf8.count
        placeCaret(viewport, at: lineEnd)
        viewport.csvCaretColumn = 2

        type("a,b", into: viewport)

        XCTAssertEqual(text(of: document), "name,age,city\n,,\"a,b\"\n")
        XCTAssertEqual(viewport.selection?.range, (lineEnd + 6)..<(lineEnd + 6))
    }

    func testADelimiterBeepsWithoutAQuoteCharacter() {
        let original = "name,age\nbob,2\n"
        let (viewport, document) = makeViewport(original, dialect: CSVDialect(quote: nil))
        placeCaret(viewport, at: "name,age\nbob".utf8.count)

        type(",", into: viewport)

        XCTAssertEqual(text(of: document), original)
    }

    func testTextModeTypesTheDelimiterAsText() {
        let (viewport, document) = makeViewport("name,age\nbob,2\n")
        viewport.setCSVRendering(dialect: nil, columnLayout: nil)
        placeCaret(viewport, at: "name,age\nbob".utf8.count)

        type(",", into: viewport)

        XCTAssertEqual(text(of: document), "name,age\nbob,,2\n")
    }

    func testReturnSelectsTheSameColumnOnTheNextRow() {
        let (viewport, document) = makeViewport("name,age\nbob,42\nann,7\n")
        placeCaret(viewport, at: "name,age\nbob,4".utf8.count)

        viewport.insertNewline(nil)

        let seven = "name,age\nbob,42\nann,".utf8.count
        XCTAssertEqual(viewport.selection?.range, seven..<(seven + 1), "7 is selected")
        XCTAssertEqual(text(of: document), "name,age\nbob,42\nann,7\n", "moving edits nothing")
    }

    func testReturnIntoAShortRowParksTheCaretInTheColumn() {
        let (viewport, _) = makeViewport("name,age\nbob,42\nann\n")
        placeCaret(viewport, at: "name,age\nbob,4".utf8.count)

        viewport.insertNewline(nil)

        let annEnd = "name,age\nbob,42\nann".utf8.count
        XCTAssertEqual(viewport.selection?.range, annEnd..<annEnd)
        XCTAssertEqual(viewport.csvCaretColumn, 1)
    }

    func testReturnOnTheLastRowAddsARow() {
        let (viewport, document) = makeViewport("name,age\nbob,42")
        placeCaret(viewport, at: "name,age\nbob,4".utf8.count)

        viewport.insertNewline(nil)
        type("7", into: viewport)

        XCTAssertEqual(text(of: document), "name,age\nbob,42\n,7")
        viewport.undo(nil)
        viewport.undo(nil)
        XCTAssertEqual(text(of: document), "name,age\nbob,42", "the added row undoes on its own")
    }

    func testReturnInTextModeTypesALineEnding() {
        let (viewport, document) = makeViewport("name,age\nbob,42\n")
        viewport.setCSVRendering(dialect: nil, columnLayout: nil)
        placeCaret(viewport, at: "name,age\nbob".utf8.count)

        viewport.insertNewline(nil)

        XCTAssertEqual(text(of: document), "name,age\nbob\n,42\n")
    }
}
