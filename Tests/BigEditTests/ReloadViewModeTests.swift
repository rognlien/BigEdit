import AppKit
import XCTest
@testable import BigEdit

/// Saving reloads the document from disk; the view mode and the CSV options
/// it was shown with survive that, while opening a file starts in text.
final class ReloadViewModeTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeColumnsView() -> (DocumentView, MappedFile) {
        let url = TestHelpers.writeTempFile("name,age\nbob,42\n")
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.load(file: file, index: index)
        view.formatBar.setMode(.csv)
        view.formatBar(view.formatBar, didSelect: .csv)
        var dialect = view.formatBar.dialect
        dialect.trimsFieldWhitespace = true
        view.formatBar.setDetectedDialect(dialect)
        view.formatBar(view.formatBar, didChange: dialect)
        return (view, file)
    }

    private func reload(_ view: DocumentView, _ file: MappedFile, keepingViewMode: Bool) {
        let index = LineIndex()
        index.buildSynchronously(from: file)
        view.load(file: file, index: index, inheritingHistory: true, keepingViewMode: keepingViewMode)
    }

    func testAReloadKeepsTheColumnsAndTheirOptions() {
        let (view, file) = makeColumnsView()

        reload(view, file, keepingViewMode: true)

        XCTAssertEqual(view.formatBar.mode, .csv)
        XCTAssertTrue(view.viewport.isCSVRenderingActive)
        XCTAssertEqual(view.formatBar.dialect.trimsFieldWhitespace, true)
    }

    func testLoadingAFileStartsInText() {
        let (view, file) = makeColumnsView()

        reload(view, file, keepingViewMode: false)

        XCTAssertEqual(view.formatBar.mode, .text)
        XCTAssertFalse(view.viewport.isCSVRenderingActive)
    }
}
