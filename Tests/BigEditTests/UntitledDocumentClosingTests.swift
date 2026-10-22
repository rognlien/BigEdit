import AppKit
import XCTest
@testable import BigEdit

/// Closing an untitled document asks about saving only when there is text to
/// lose; a titled one asks only about unsaved edits. The views are never
/// loaded, so no journal is written.
final class UntitledDocumentClosingTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func document(containing text: String, untitledNumber: Int?) -> Document {
        let url = TestHelpers.writeTempFile(text)
        temporaryFiles.append(url)
        let document = Document(url: url, file: MappedFile(path: url.path)!, index: LineIndex(),
                                view: TestHelpers.isolatedDocumentView(width: 400, height: 300))
        document.untitledNumber = untitledNumber
        return document
    }

    func testAnEmptyUntitledDocumentClosesWithoutAsking() {
        XCTAssertFalse(document(containing: "", untitledNumber: 1).asksBeforeClosing)
    }

    func testAnUntitledDocumentWithTextAsks() {
        XCTAssertTrue(document(containing: "text\n", untitledNumber: 1).asksBeforeClosing)
    }

    func testAnUneditedFileClosesWithoutAsking() {
        XCTAssertFalse(document(containing: "text\n", untitledNumber: nil).asksBeforeClosing)
    }

    func testAnUntitledDocumentIsShownByItsNumber() {
        XCTAssertEqual(document(containing: "", untitledNumber: 1).fileName, "Untitled")
        XCTAssertEqual(document(containing: "", untitledNumber: 3).fileName, "Untitled 3")
        let titled = document(containing: "", untitledNumber: nil)
        XCTAssertEqual(titled.fileName, titled.url.lastPathComponent)
    }
}
