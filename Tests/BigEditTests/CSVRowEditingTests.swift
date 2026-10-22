import AppKit
import XCTest
@testable import BigEdit

/// Adding and deleting rows under aligned CSV columns, as Numbers' Table
/// menu does.
final class CSVRowEditingTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeViewport(_ text: String, caret: Int, encoding: TextEncoding = .utf8,
                              dialect: CSVDialect = CSVDialect()) -> (ViewportView, EditedDocument) {
        let url = TestHelpers.writeTempFile(Data(encoding.encode(text)!))
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.isEditable = true
        document.newlineBytes = text.contains("\r\n") ? [0x0D, 0x0A] : [0x0A]
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.setTextEncoding(encoding)
        viewport.setCSVRendering(dialect: dialect,
                                 columnLayout: CSVColumnLayout.measure(file: file, dialect: dialect, encoding: encoding))
        viewport.selection = TextSelection(anchorOffset: caret, activeOffset: caret)
        return (viewport, document)
    }

    private func text(of document: EditedDocument, encoding: TextEncoding = .utf8) -> String {
        encoding.decode(document.bytes(in: 0..<document.length))
    }

    private func offset(of prefix: String) -> Int {
        prefix.utf8.count
    }

    func testAddRowAboveInsertsAnEmptyRowWithTheTablesCells() {
        let (viewport, document) = makeViewport("name,age,city\nbob,2,Oslo\n", caret: offset(of: "name,age,city\nbo"))

        viewport.addRowAbove(nil)

        XCTAssertEqual(text(of: document), "name,age,city\n,,\nbob,2,Oslo\n")
        let start = offset(of: "name,age,city\n")
        XCTAssertEqual(viewport.selection?.range, start..<start, "the caret is in the new row's first cell")
    }

    func testAddRowBelowInsertsAfterTheCaretsRow() {
        let (viewport, document) = makeViewport("name,age\nbob,2\nann,3\n", caret: offset(of: "name,age\nbob,"))

        viewport.addRowBelow(nil)

        XCTAssertEqual(text(of: document), "name,age\nbob,2\n,\nann,3\n")
        let start = offset(of: "name,age\nbob,2\n")
        XCTAssertEqual(viewport.selection?.range, start..<start)
    }

    func testAddRowBelowTheLastRowWithoutALineEnding() {
        let (viewport, document) = makeViewport("name,age\nbob,2", caret: offset(of: "name,age\nb"))

        viewport.addRowBelow(nil)

        XCTAssertEqual(text(of: document), "name,age\nbob,2\n,")
        let start = offset(of: "name,age\nbob,2\n")
        XCTAssertEqual(viewport.selection?.range, start..<start)
    }

    func testAddRowBelowTheLastRowKeepsTheTrailingLineEnding() {
        let (viewport, document) = makeViewport("name,age\nbob,2\n", caret: offset(of: "name,age\nb"))

        viewport.addRowBelow(nil)

        XCTAssertEqual(text(of: document), "name,age\nbob,2\n,\n")
    }

    func testAddedRowsUseTheFilesLineEnding() {
        let (viewport, document) = makeViewport("name,age\r\nbob,2\r\n", caret: offset(of: "name,age\r\nb"))

        viewport.addRowBelow(nil)
        viewport.addRowAbove(nil)

        XCTAssertEqual(text(of: document), "name,age\r\nbob,2\r\n,\r\n,\r\n")
    }

    func testAddRowAboveIsNotOfferedOnTheHeader() {
        let (viewport, document) = makeViewport("name,age\nbob,2\n", caret: 2)

        XCTAssertFalse(viewport.canAddCSVRowAbove)
        viewport.addRowAbove(nil)

        XCTAssertEqual(text(of: document), "name,age\nbob,2\n", "the header stays the first line")
    }

    func testAddRowAboveTheFirstLineWithoutAHeader() {
        let (viewport, document) = makeViewport("bob,2\nann,3\n", caret: 2,
                                                dialect: CSVDialect(hasHeaderRow: false))

        XCTAssertTrue(viewport.canAddCSVRowAbove)
        viewport.addRowAbove(nil)

        XCTAssertEqual(text(of: document), ",\nbob,2\nann,3\n")
    }

    func testAddRowBelowTheHeaderAddsTheFirstDataRow() {
        let (viewport, document) = makeViewport("name,age\nbob,2\n", caret: 2)

        viewport.addRowBelow(nil)

        XCTAssertEqual(text(of: document), "name,age\n,\nbob,2\n")
    }

    func testAnAddedRowUndoesAsOneStep() {
        let (viewport, document) = makeViewport("name,age\nbob,2\n", caret: offset(of: "name,age\nb"))

        viewport.addRowBelow(nil)
        viewport.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(text(of: document), "name,age\nbob,2\nx,\n")

        viewport.undo(nil)
        XCTAssertEqual(text(of: document), "name,age\nbob,2\n,\n", "typing undoes apart from the row")
        viewport.undo(nil)
        XCTAssertEqual(text(of: document), "name,age\nbob,2\n")
    }

    func testAddedRowsAreEncodedInWindows1252() {
        let (viewport, document) = makeViewport("navn;by\nÅse;Ørsta\n", caret: 12, encoding: .windows1252,
                                                dialect: CSVDialect(delimiter: ";"))

        viewport.addRowAbove(nil)

        XCTAssertEqual(text(of: document, encoding: .windows1252), "navn;by\n;\nÅse;Ørsta\n")
    }

    func testAnAddedRowHasTheTablesCellsBesideQuotedDelimiters() {
        let (viewport, document) = makeViewport("a,b,c\n\"x,y\",2,3\n", caret: offset(of: "a,b,c\n\"x"))

        viewport.addRowBelow(nil)

        XCTAssertEqual(text(of: document), "a,b,c\n\"x,y\",2,3\n,,\n")
    }

    func testRowCommandsNeedColumns() {
        let (viewport, _) = makeViewport("name,age\nbob,2\n", caret: offset(of: "name,age\nb"))
        viewport.setCSVRendering(dialect: nil, columnLayout: nil)

        XCTAssertFalse(viewport.canEditCSVRows)
    }

    func testDeleteRowRemovesTheCaretsRow() {
        let (viewport, document) = makeViewport("name,age\nbob,2\nann,3\n", caret: offset(of: "name,age\nbo"))

        viewport.deleteRow(nil)

        XCTAssertEqual(text(of: document), "name,age\nann,3\n")
        let start = offset(of: "name,age\n")
        XCTAssertEqual(viewport.selection?.range, start..<start, "the caret starts the row that moved up")
    }

    func testDeleteRowRemovesEveryRowTheSelectionTouches() {
        let (viewport, document) = makeViewport("name,age\nbob,2\nann,3\neve,4\n", caret: 0)
        viewport.selection = TextSelection(anchorOffset: offset(of: "name,age\nbob,"),
                                           activeOffset: offset(of: "name,age\nbob,2\nan"))

        XCTAssertEqual(viewport.selectionSpansCSVRows, true)
        viewport.deleteRow(nil)

        XCTAssertEqual(text(of: document), "name,age\neve,4\n")
    }

    func testASelectionEndingAtALineStartDoesNotTouchThatLine() {
        let (viewport, document) = makeViewport("name,age\nbob,2\nann,3\n", caret: 0)
        viewport.selection = TextSelection(anchorOffset: offset(of: "name,age\n"),
                                           activeOffset: offset(of: "name,age\nbob,2\n"))

        XCTAssertFalse(viewport.selectionSpansCSVRows)
        viewport.deleteRow(nil)

        XCTAssertEqual(text(of: document), "name,age\nann,3\n")
    }

    func testDeletingTheLastRowWithoutALineEndingTakesThePreviousEnding() {
        let (viewport, document) = makeViewport("name,age\nbob,2\nann,3", caret: offset(of: "name,age\nbob,2\nan"))

        viewport.deleteRow(nil)

        XCTAssertEqual(text(of: document), "name,age\nbob,2")
        let start = offset(of: "name,age\n")
        XCTAssertEqual(viewport.selection?.range, start..<start)
    }

    func testDeletingACRLFRowTakesBothBytesOfItsEnding() {
        let (viewport, document) = makeViewport("name,age\r\nbob,2\r\nann,3\r\n", caret: offset(of: "name,age\r\nb"))

        viewport.deleteRow(nil)

        XCTAssertEqual(text(of: document), "name,age\r\nann,3\r\n")
    }

    func testDeletingARowWithAQuotedFieldTakesTheWholeLine() {
        let (viewport, document) = makeViewport("a,b\n\"x,y\",2\nz,3\n", caret: offset(of: "a,b\n\"x,"))

        viewport.deleteRow(nil)

        XCTAssertEqual(text(of: document), "a,b\nz,3\n")
    }

    func testDeleteRowIsNotOfferedOnTheHeader() {
        let (viewport, document) = makeViewport("name,age\nbob,2\n", caret: 2)

        XCTAssertFalse(viewport.canDeleteCSVRows)
        viewport.deleteRow(nil)

        XCTAssertEqual(text(of: document), "name,age\nbob,2\n")
    }

    func testDeleteRowIsNotOfferedOnTheEmptyRowAfterTheLastLineEnding() {
        let (viewport, document) = makeViewport("name,age\nbob,2\n", caret: offset(of: "name,age\nbob,2\n"))

        XCTAssertFalse(viewport.canDeleteCSVRows)
        viewport.deleteRow(nil)

        XCTAssertEqual(text(of: document), "name,age\nbob,2\n")
    }

    func testDeletedRowsUndoAsOneStep() {
        let (viewport, document) = makeViewport("name,age\nbob,2\nann,3\n", caret: 0)
        viewport.selection = TextSelection(anchorOffset: offset(of: "name,age\nb"),
                                           activeOffset: offset(of: "name,age\nbob,2\na"))

        viewport.deleteRow(nil)
        viewport.undo(nil)

        XCTAssertEqual(text(of: document), "name,age\nbob,2\nann,3\n")
    }

    func testDeletingRowsInWindows1252() {
        let (viewport, document) = makeViewport("navn;by\nÅse;Ørsta\nÆgir;Bø\n", caret: 9, encoding: .windows1252,
                                                dialect: CSVDialect(delimiter: ";"))

        viewport.deleteRow(nil)

        XCTAssertEqual(text(of: document, encoding: .windows1252), "navn;by\nÆgir;Bø\n")
    }

    func testTheTableMenuFollowsNumbers() {
        let items = ViewportView.csvTableItems(includingShortcuts: true)

        XCTAssertEqual(items.map(\.title), ["Add Row Above", "Add Row Below", "Add Column Before",
                                            "Add Column After", "", "Delete Row", "Delete Column"])
        let deleteRow = items[5]
        XCTAssertEqual(deleteRow.keyEquivalent, "\u{8}")
        XCTAssertEqual(deleteRow.keyEquivalentModifierMask, [.command, .option], "Numbers' Option-Command-Delete")
        let deleteColumn = items[6]
        XCTAssertEqual(deleteColumn.keyEquivalent, "\u{8}")
        XCTAssertEqual(deleteColumn.keyEquivalentModifierMask, [.command, .control],
                       "Numbers' Control-Command-Delete")
        XCTAssertTrue(items.prefix(4).allSatisfy { $0.keyEquivalent.isEmpty },
                      "Option-arrows stay the system's paragraph and word moves")
    }

    func testTheContextMenuOffersTheTableItemsOnlyUnderColumns() {
        let (viewport, _) = makeViewport("name,age\nbob,2\n", caret: 0)
        let csvMenu = NSMenu()
        viewport.addCSVTableItems(to: csvMenu)
        viewport.setCSVRendering(dialect: nil, columnLayout: nil)
        let textMenu = NSMenu()
        viewport.addCSVTableItems(to: textMenu)

        XCTAssertTrue(csvMenu.items.contains { $0.action == #selector(ViewportView.addRowBelow(_:)) })
        XCTAssertEqual(csvMenu.items.first { $0.action == #selector(ViewportView.deleteRow(_:)) }?.keyEquivalent, "")
        XCTAssertTrue(textMenu.items.isEmpty)
    }

    func testARightClickOutsideTheSelectionPutsTheCaretInTheClickedRow() {
        let (viewport, _) = makeViewport("name,age\nbob,2\nann,3\n", caret: 2)
        let annRow = NSPoint(x: viewport.csvDividerPositions()[0] - 4, y: 2.5 * viewport.lineHeight)

        viewport.placeCaretForCSVContextMenu(at: annRow)

        let caret = viewport.selection!.activeOffset
        XCTAssertEqual(viewport.layout?.visualRow(forLogicalByteOffset: caret), 2)
        XCTAssertTrue(viewport.selection!.isEmpty)
    }

    func testARightClickInsideTheSelectionKeepsIt() {
        let (viewport, _) = makeViewport("name,age\nbob,2\nann,3\n", caret: 0)
        let selected = offset(of: "name,age\n")..<offset(of: "name,age\nbob,2\nann")
        viewport.selection = TextSelection(anchorOffset: selected.lowerBound, activeOffset: selected.upperBound)
        let bobRow = NSPoint(x: viewport.csvDividerPositions()[0] - 4, y: 1.5 * viewport.lineHeight)

        viewport.placeCaretForCSVContextMenu(at: bobRow)

        XCTAssertEqual(viewport.selection?.range, selected)
    }
}
