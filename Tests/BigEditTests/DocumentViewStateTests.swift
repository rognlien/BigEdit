import AppKit
import XCTest
@testable import BigEdit

/// Reopening a file shows it the way it was last shown: the view mode, the
/// CSV options, resized columns and the chosen language.
final class DocumentViewStateTests: XCTestCase {

    private var temporaryFiles: [URL] = []
    private var store: DocumentViewStateStore!

    override func setUp() {
        super.setUp()
        store = TestHelpers.isolatedViewStateStore()
    }

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeFile(_ text: String) -> MappedFile {
        let url = TestHelpers.writeTempFile(text)
        temporaryFiles.append(url)
        return MappedFile(path: url.path)!
    }

    private func open(_ file: MappedFile) -> DocumentView {
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.viewStateStore = store
        view.load(file: file, index: index)
        return view
    }

    private func showColumns(_ view: DocumentView, trimming: Bool) {
        view.formatBar.setMode(.csv)
        view.formatBar(view.formatBar, didSelect: .csv)
        var dialect = view.formatBar.dialect
        dialect.trimsFieldWhitespace = trimming
        view.formatBar.setDetectedDialect(dialect)
        view.formatBar(view.formatBar, didChange: dialect)
    }

    private func resize(_ view: DocumentView, column: Int, to width: Int) {
        view.viewport.applyCSVChosenColumnWidths([column: width])
        view.viewport.onCSVColumnResize?()
    }

    func testReopeningAFileRestoresItsColumnsAndOptions() {
        let file = makeFile("name;age\nbob;42\n")
        let first = open(file)
        showColumns(first, trimming: true)
        resize(first, column: 1, to: 9)

        let reopened = open(file)

        XCTAssertEqual(reopened.formatBar.mode, .csv)
        XCTAssertTrue(reopened.viewport.isCSVRenderingActive)
        XCTAssertEqual(reopened.formatBar.dialect.delimiter, ";")
        XCTAssertTrue(reopened.formatBar.dialect.trimsFieldWhitespace)
        XCTAssertEqual(reopened.viewport.csvColumnLayout?.columnWidths[1], 9)
    }

    func testReopeningAFileRestoresItsLanguage() {
        let file = makeFile("SELECT 1;")
        open(file).chooseLanguage(LanguageRegistry.sql)

        XCTAssertEqual(open(file).viewport.language, LanguageRegistry.sql)
    }

    func testAFileNeverShownBeforeStartsInText() {
        let view = open(makeFile("name,age\nbob,42\n"))

        XCTAssertEqual(view.formatBar.mode, .text)
        XCTAssertNil(view.chosenLanguage)
    }

    func testChangingAnOptionKeepsResizedColumns() {
        let view = open(makeFile("name,age\nbob,42\n"))
        showColumns(view, trimming: false)
        resize(view, column: 0, to: 12)

        var dialect = view.formatBar.dialect
        dialect.hasHeaderRow = false
        view.formatBar(view.formatBar, didChange: dialect)

        XCTAssertEqual(view.viewport.csvColumnLayout?.columnWidths[0], 12)
    }

    func testChangingTheDelimiterForgetsResizedColumns() {
        let view = open(makeFile("name,age\nbob,42\n"))
        showColumns(view, trimming: false)
        resize(view, column: 0, to: 12)

        var dialect = view.formatBar.dialect
        dialect.delimiter = ";"
        view.formatBar(view.formatBar, didChange: dialect)

        XCTAssertTrue(view.viewport.csvChosenColumnWidths.isEmpty)
    }

    func testTheStoreKeepsOnlyTheMostRecentFiles() {
        let state = DocumentViewState(mode: .text, dialect: CSVDialect(), columnWidths: [:], language: nil)
        for index in 0...DocumentViewStateStore.capacity {
            store.store(state, forPath: "/tmp/file-\(index)")
        }

        XCTAssertNil(store.state(forPath: "/tmp/file-0"))
        XCTAssertEqual(store.state(forPath: "/tmp/file-\(DocumentViewStateStore.capacity)"), state)
    }
}
