import AppKit
import XCTest
@testable import BigEdit

/// Add Column Before / After and Delete Column, from the caret's cell to
/// the rewritten table and its widths.
final class CSVColumnCommandTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func open(_ text: String, encoding: TextEncoding = .utf8) -> DocumentView {
        let url = TestHelpers.writeTempFile(Data(encoding.encode(text)!))
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.viewStateStore = TestHelpers.isolatedViewStateStore()
        view.load(file: file, index: index)
        view.setFileFormat(FileFormat(scanning: file))
        view.formatBar.setMode(.csv)
        view.formatBar(view.formatBar, didSelect: .csv)
        return view
    }

    private func placeCaret(_ view: DocumentView, at offset: Int) {
        view.viewport.selection = TextSelection(anchorOffset: offset, activeOffset: offset)
    }

    private func text(of view: DocumentView, encoding: TextEncoding = .utf8) -> String {
        let document = view.viewport.document!
        return encoding.decode(document.bytes(in: 0..<document.length))
    }

    /// Waits for the rewrite, which runs off the main thread.
    private func waitForText(_ expected: String, in view: DocumentView, encoding: TextEncoding = .utf8) {
        let deadline = Date().addingTimeInterval(5)
        while text(of: view, encoding: encoding) != expected && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(text(of: view, encoding: encoding), expected)
    }

    func testAddColumnBeforeTheCaretsColumn() {
        let view = open("name,age\nbob,42\n")
        placeCaret(view, at: "name,age\nbob,4".utf8.count)

        view.viewport.addColumnBefore(nil)

        waitForText("name,,age\nbob,,42\n", in: view)
        XCTAssertEqual(view.viewport.csvColumnLayout?.columnWidths.count, 3)
        let caret = "name,,age\nbob,".utf8.count
        XCTAssertEqual(view.viewport.selection?.range, caret..<caret, "the caret is in the new column")
    }

    func testAddColumnAfterTheLastColumn() {
        let view = open("name,age\r\nbob,42\r\n")
        placeCaret(view, at: "name,age\r\nbob,4".utf8.count)

        view.viewport.addColumnAfter(nil)

        waitForText("name,age,\r\nbob,42,\r\n", in: view)
    }

    func testDeleteColumnRemovesItFromEveryRow() {
        let view = open("id,name,age\n1,\"Smith, John\",42\n")
        placeCaret(view, at: "id,name,age\n1,\"Sm".utf8.count)

        view.viewport.deleteColumn(nil)

        waitForText("id,age\n1,42\n", in: view)
        XCTAssertEqual(view.viewport.csvColumnLayout?.columnWidths.count, 2)
    }

    func testAColumnChangeUndoesAsOneStep() {
        let view = open("name,age\nbob,42\n")
        placeCaret(view, at: 1)
        view.viewport.addColumnAfter(nil)
        waitForText("name,,age\nbob,,42\n", in: view)

        view.viewport.undo(nil)

        XCTAssertEqual(text(of: view), "name,age\nbob,42\n")
    }

    func testUndoAndRedoPutTheWidthsBackExactly() {
        let view = open("a,b,c\n1,2,3\n")
        view.viewport.applyCSVChosenColumnWidths([0: 6, 2: 15])
        let before = view.viewport.csvColumnWidths
        placeCaret(view, at: 0)
        view.viewport.addColumnAfter(nil)
        waitForText("a,,b,c\n1,,2,3\n", in: view)
        let after = view.viewport.csvColumnWidths
        XCTAssertEqual(after?.working.columnWidths, [6, 6, 1, 15])

        view.viewport.undo(nil)
        XCTAssertEqual(view.viewport.csvColumnWidths, before)
        XCTAssertEqual(view.viewport.csvChosenColumnWidths, [0: 6, 2: 15])

        view.viewport.redo(nil)
        XCTAssertEqual(view.viewport.csvColumnWidths, after)
    }

    func testUndoingADeletedColumnBringsItsWidthBack() {
        let view = open("a,b,c\n1,2,3\n")
        view.viewport.applyCSVChosenColumnWidths([1: 11])
        placeCaret(view, at: "a,".utf8.count)
        view.viewport.deleteColumn(nil)
        waitForText("a,c\n1,3\n", in: view)

        view.viewport.undo(nil)

        XCTAssertEqual(text(of: view), "a,b,c\n1,2,3\n")
        XCTAssertEqual(view.viewport.csvColumnLayout?.columnWidths, [1, 11, 1])
    }

    private func storedWidths(of view: DocumentView) -> [Int: Int]? {
        view.viewStateStore.state(forPath: view.mappedFile!.path)?.columnWidths
    }

    func testUnsavedColumnChangesRememberTheWidthsThatFitTheFileOnDisk() {
        let view = open("a,b,c\n1,2,3\n")
        view.viewport.applyCSVChosenColumnWidths([2: 15])
        view.viewport.onCSVColumnResize?()
        placeCaret(view, at: 0)

        view.viewport.addColumnBefore(nil)
        waitForText(",a,b,c\n,1,2,3\n", in: view)
        XCTAssertEqual(view.viewport.csvChosenColumnWidths[3], 15, "on screen the width moved with c")
        XCTAssertEqual(storedWidths(of: view), [2: 15], "on disk c is still the third column")

        view.viewport.applyCSVChosenColumnWidths([0: 4])
        view.viewport.onCSVColumnResize?()
        XCTAssertEqual(storedWidths(of: view), [2: 15], "a resize waits for the change to be saved")
    }

    func testUndoingTheChangeRemembersWidthsAgain() {
        let view = open("a,b,c\n1,2,3\n")
        placeCaret(view, at: 0)
        view.viewport.deleteColumn(nil)
        waitForText("b,c\n2,3\n", in: view)

        view.viewport.undo(nil)
        view.viewport.applyCSVChosenColumnWidths([1: 9])
        view.viewport.onCSVColumnResize?()

        XCTAssertEqual(view.unsavedColumnChanges, 0)
        XCTAssertEqual(storedWidths(of: view), [1: 9])
    }

    func testSavingMakesTheChangedColumnsTheOnesOnDisk() {
        let view = open("a,b\n1,2\n")
        placeCaret(view, at: 0)
        view.viewport.addColumnAfter(nil)
        waitForText("a,,b\n1,,2\n", in: view)
        let document = view.viewport.document!
        let path = view.mappedFile!.path
        try? Data(document.bytes(in: 0..<document.length))
            .write(to: URL(fileURLWithPath: path), options: .atomic)
        let saved = MappedFile(path: path)!
        let index = LineIndex()
        index.buildSynchronously(from: saved)

        view.load(file: saved, index: index, inheritingHistory: true, keepingViewMode: true)
        view.viewport.applyCSVChosenColumnWidths([2: 7])
        view.viewport.onCSVColumnResize?()

        XCTAssertEqual(storedWidths(of: view), [2: 7])
    }

    func testColumnsChangeInWindows1252() {
        let view = open("navn,by\nÅse,Ørsta\n", encoding: .windows1252)
        placeCaret(view, at: 1)

        view.viewport.deleteColumn(nil)

        waitForText("by\nØrsta\n", in: view, encoding: .windows1252)
    }

    func testTheLastColumnCannotBeDeleted() {
        let view = open("name\nbob\n")
        placeCaret(view, at: 1)

        XCTAssertFalse(view.viewport.canDeleteCSVColumn)
    }

    func testResizedWidthsMoveWithTheirColumns() {
        let widths = DocumentView.chosenWidths([0: 9, 2: 12], after: .insertion(before: 1, widthOf: 0),
                                               current: [9, 3, 12])
        XCTAssertEqual(widths, [0: 9, 1: 9, 3: 12], "the new column is as wide as the one it was added beside")

        let removed = DocumentView.chosenWidths([0: 9, 1: 5, 2: 12], after: .removal(of: 1), current: [9, 5, 12])
        XCTAssertEqual(removed, [0: 9, 1: 12])
    }

    func testAnAddedColumnKeepsTheResizedWidthsBesideIt() {
        let view = open("a,b,c\n1,2,3\n")
        view.viewport.applyCSVChosenColumnWidths([2: 15])
        placeCaret(view, at: 0)

        view.viewport.addColumnAfter(nil)

        waitForText("a,,b,c\n1,,2,3\n", in: view)
        XCTAssertEqual(view.viewport.csvColumnLayout?.columnWidths[3], 15, "column c moved and kept its width")
        XCTAssertEqual(view.viewport.csvColumnLayout?.columnWidths[1], 1, "the new column is as wide as a")
    }
}
