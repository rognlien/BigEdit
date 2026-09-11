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

    private func makeViewport(_ text: String) -> (ViewportView, EditedDocument) {
        let url = TestHelpers.writeTempFile(text)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.isEditable = true
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        let dialect = CSVDialect()
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
}
