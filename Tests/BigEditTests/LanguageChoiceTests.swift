import AppKit
import XCTest
@testable import BigEdit

/// The language a document is coloured as can be chosen in place of the
/// detected one, from the View menu or the status bar.
final class LanguageChoiceTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeView(_ text: String, extension fileExtension: String) -> (DocumentView, MappedFile) {
        let url = TestHelpers.writeTempFile(text).appendingPathExtension(fileExtension)
        try? Data(text.utf8).write(to: url)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.load(file: file, index: index)
        return (view, file)
    }

    private func reload(_ view: DocumentView, _ file: MappedFile, keepingViewMode: Bool) {
        let index = LineIndex()
        index.buildSynchronously(from: file)
        view.load(file: file, index: index, inheritingHistory: true, keepingViewMode: keepingViewMode)
    }

    private func choose(_ title: String, in view: DocumentView) {
        let item = view.languageMenuItems().first { $0.title == title }!
        _ = item.target!.perform(item.action!, with: item)
    }

    func testTheMenuOffersAutomaticPlainTextAndEveryLanguage() {
        let (view, _) = makeView("SELECT 1;", extension: "txt")

        let titles = view.languageMenuItems().filter { !$0.isSeparatorItem }.map(\.title)

        XCTAssertEqual(titles.first, "Automatic (Plain Text)")
        XCTAssertEqual(titles.count, 2 + LanguageRegistry.all.count)
        XCTAssertTrue(titles.contains("SQL"))
        XCTAssertEqual(view.languageMenuItems().first?.state, .on)
    }

    func testChoosingALanguageColoursTheDocumentAsIt() {
        let (view, _) = makeView("SELECT 1;", extension: "txt")

        choose("SQL", in: view)

        XCTAssertEqual(view.viewport.language, LanguageRegistry.sql)
        XCTAssertEqual(view.languageMenuItems().first { $0.title == "SQL" }?.state, .on)
    }

    func testAutomaticGoesBackToTheDetectedLanguage() {
        let (view, _) = makeView("{}", extension: "json")
        choose("Plain Text", in: view)
        XCTAssertEqual(view.viewport.language, .plain)

        choose("Automatic (JSON)", in: view)

        XCTAssertEqual(view.viewport.language, LanguageRegistry.json)
    }

    func testAReloadKeepsTheChoiceAndOpeningAFileDoesNot() {
        let (view, file) = makeView("SELECT 1;", extension: "txt")
        choose("SQL", in: view)

        reload(view, file, keepingViewMode: true)
        XCTAssertEqual(view.viewport.language, LanguageRegistry.sql)

        reload(view, file, keepingViewMode: false)
        XCTAssertEqual(view.viewport.language, .plain)
    }

    func testChoosingMarkdownMakesTheRenderedViewAvailable() {
        let (view, file) = makeView("# Title", extension: "txt")
        XCTAssertNotNil(DocumentView.markdownUnavailableReason(for: file, language: view.language))

        choose("Markdown", in: view)

        XCTAssertNil(DocumentView.markdownUnavailableReason(for: file, language: view.language))
    }
}
