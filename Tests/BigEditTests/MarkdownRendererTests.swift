import XCTest
@testable import BigEdit

final class MarkdownRendererTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func html(_ markdown: String) -> String {
        MarkdownRenderer.html(from: Array(markdown.utf8))
    }

    private func mappedFile(named name: String, contents: String) -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + name)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        temporaryFiles.append(url)
        return MappedFile(path: url.path)!
    }

    func testHeadingAndEmphasis() {
        let output = html("# Title\n\nSome **bold** text.\n")

        XCTAssertTrue(output.contains(">Title</h1>"), output)
        XCTAssertTrue(output.contains("<strong>bold</strong>"), output)
    }

    func testBlocksCarryTheirSourceLines() {
        let output = html("# Title\n\nFirst paragraph.\n\nSecond paragraph.\n")

        XCTAssertTrue(output.contains("<h1 data-sourcepos=\"1:1-1:7\">"), output)
        XCTAssertTrue(output.contains("<p data-sourcepos=\"5:1-5:17\">"), output)
    }

    func testGitHubTablesTaskListsAndStrikethrough() {
        let output = html("| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n- [ ] open\n\n~~gone~~\n")

        XCTAssertTrue(output.contains("<table"), output)
        XCTAssertTrue(output.contains("<td data-sourcepos=\"3:2-3:4\">1</td>"), output)
        XCTAssertTrue(output.contains("type=\"checkbox\" checked=\"\" disabled=\"\""), output)
        XCTAssertTrue(output.contains("<del>gone</del>"), output)
    }

    func testRawHTMLIsLeftOut() {
        let output = html("<script>alert(1)</script>\n\nText <img src=x onerror=alert(1)> here.\n")

        XCTAssertFalse(output.contains("<script"), output)
        XCTAssertFalse(output.contains("onerror"), output)
    }

    func testPageForbidsScripts() {
        let page = MarkdownRenderer.page(from: Array("Hello".utf8))

        XCTAssertTrue(page.contains("default-src 'none'"), page)
        XCTAssertFalse(page.contains("script-src"), page)
    }

    func testEmptyDocumentRendersEmptyBody() {
        XCTAssertEqual(html(""), "")
    }

    func testMarkdownIsOfferedForMarkdownFilesOnly() {
        let markdown = mappedFile(named: "notes.md", contents: "# Notes\n")
        let text = mappedFile(named: "notes.txt", contents: "# Notes\n")

        XCTAssertNil(DocumentView.markdownUnavailableReason(for: markdown))
        XCTAssertNotNil(DocumentView.markdownUnavailableReason(for: text))
    }

    func testFormatBarFallsBackToTextWhenMarkdownIsUnavailable() {
        let bar = FormatBar(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        bar.setMarkdownAvailability(unavailableReason: nil)
        bar.setMode(.markdown)
        XCTAssertEqual(bar.mode, .markdown)

        bar.setMarkdownAvailability(unavailableReason: "This file is not Markdown")

        XCTAssertEqual(bar.mode, .text)
    }
}
