import AppKit
import XCTest
@testable import BigEdit

/// Under aligned CSV columns the caret cannot be placed, so typing is off —
/// but a rewrite of the whole document needs no caret, and sorting relies
/// on that. A click on a header column reports that column.
final class CSVSortViewportTests: XCTestCase {

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

    func testWholeDocumentRewriteIsAllowedUnderColumnsWhileTypingIsNot() {
        let (viewport, document) = makeViewport("name,age\nbob,2\nann,1\n")

        XCTAssertFalse(viewport.isEditingAllowed)
        XCTAssertTrue(viewport.isWholeDocumentReplacementAllowed)

        viewport.replaceEntireDocument(with: Array("name,age\nann,1\nbob,2\n".utf8))

        XCTAssertEqual(String(decoding: document.bytes(in: 0..<document.length), as: UTF8.self),
                       "name,age\nann,1\nbob,2\n")
        XCTAssertTrue(document.undoStack.canUndo)
    }

    func testHeaderClickReportsTheColumnUnderThePoint() {
        let (viewport, _) = makeViewport("name,age\nbob,2\nann,1\n")
        let dividers = viewport.csvDividerPositions()
        XCTAssertEqual(dividers.count, 2)

        let firstColumnX = dividers[0] - 2
        let secondColumnX = dividers[0] + 4
        let headerY: CGFloat = 5
        let dataRowY: CGFloat = 40

        XCTAssertEqual(viewport.csvHeaderColumn(at: NSPoint(x: firstColumnX, y: headerY)), 0)
        XCTAssertEqual(viewport.csvHeaderColumn(at: NSPoint(x: secondColumnX, y: headerY)), 1)
        XCTAssertNil(viewport.csvHeaderColumn(at: NSPoint(x: firstColumnX, y: dataRowY)))
        XCTAssertEqual(viewport.csvColumnTitle(1), "age")
    }
}
