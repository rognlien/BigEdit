import AppKit
import XCTest
@testable import BigEdit

/// Tabs stop every `ViewportView.tabWidth` characters, so a tab is never
/// narrower than a character wherever it is typed.
final class TabStopTests: XCTestCase {

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

    func testATabRunsToTheNextMultipleOfTheTabWidth() {
        let viewport = makeViewport("nam\te\n")
        let row = viewport.layout!.visualLines(forRows: 0..<1).first!

        let afterTab = viewport.xOffset(inRow: row, forByte: 4)

        XCTAssertEqual(afterTab, viewport.characterWidth * 4, accuracy: 0.01)
    }

    func testATabAtAStopTakesAWholeTabWidth() {
        let viewport = makeViewport("name\tx\n")
        let row = viewport.layout!.visualLines(forRows: 0..<1).first!

        let afterTab = viewport.xOffset(inRow: row, forByte: 5)

        XCTAssertEqual(afterTab, viewport.characterWidth * 8, accuracy: 0.01)
    }

    func testAClickAfterATabLandsAfterIt() {
        let viewport = makeViewport("nam\te\n")
        let row = viewport.layout!.visualLines(forRows: 0..<1).first!

        let offset = viewport.byteOffset(inRow: row, atX: viewport.characterWidth * 4.2)

        XCTAssertEqual(offset, 4)
    }
}
