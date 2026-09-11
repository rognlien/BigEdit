import XCTest
@testable import BigEdit

/// The view-level half of following a file: after the index is extended, the
/// view swaps to the grown mapping without losing its place, and stays pinned
/// to the end only if it was there.
final class FollowFileTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func append(_ text: String, to url: URL) {
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try! handle.close()
    }

    /// A document view over a file of `lineCount` short lines, sized so that
    /// only `visibleRows` rows fit.
    private func makeView(lineCount: Int, visibleRows: Int)
        -> (view: DocumentView, url: URL, file: MappedFile, index: LineIndex) {
        let content = (0..<lineCount).map { "line \($0)\n" }.joined()
        let url = TestHelpers.writeTempFile(content)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.load(file: file, index: index)
        // Shrink the viewport so the document is taller than the window.
        let rowHeight = view.viewport.bounds.height / CGFloat(max(1, view.viewport.rowsPerPage))
        view.frame = NSRect(x: 0, y: 0, width: 600,
                            height: rowHeight * CGFloat(visibleRows) + 120)
        return (view, url, file, index)
    }

    func testGrownFileShowsTheNewLinesAndKeepsAScrolledPosition() {
        let (view, url, file, index) = makeView(lineCount: 200, visibleRows: 10)
        view.viewport.setScrollRow(50)
        XCTAssertEqual(view.viewport.scrollRow, 50, accuracy: 0.01)
        let rowsBefore = view.viewport.layout!.visualRowCount

        append("line 200\nline 201\n", to: url)
        let grown = MappedFile(path: url.path)!
        let wasAtEnd = view.viewport.isScrolledToEnd      // judged before the index grows
        index.extendSynchronously(with: grown, previousSize: file.size)
        view.adoptGrownFile(grown, index: index, pinToEnd: wasAtEnd)

        XCTAssertEqual(view.viewport.layout!.visualRowCount, rowsBefore + 2)
        XCTAssertEqual(view.viewport.scrollRow, 50, accuracy: 0.01,
                       "a reader part-way up the file is not yanked to the end")
        XCTAssertTrue(view.viewport.document?.file === grown)
    }

    func testViewPinnedToTheEndStaysAtTheEnd() {
        let (view, url, file, index) = makeView(lineCount: 200, visibleRows: 10)
        view.viewport.setScrollRow(view.viewport.maxScrollRow)
        XCTAssertTrue(view.viewport.isScrolledToEnd)

        append(String(repeating: "more\n", count: 30), to: url)
        let grown = MappedFile(path: url.path)!
        let wasAtEnd = view.viewport.isScrolledToEnd
        XCTAssertTrue(wasAtEnd)
        index.extendSynchronously(with: grown, previousSize: file.size)
        XCTAssertFalse(view.viewport.isScrolledToEnd,
                       "once the shared index has grown, the old layout already reports the new rows — "
                       + "which is exactly why the decision has to be made first")
        view.adoptGrownFile(grown, index: index, pinToEnd: wasAtEnd)

        XCTAssertTrue(view.viewport.isScrolledToEnd, "still pinned after the append")
        XCTAssertEqual(view.viewport.scrollRow, view.viewport.maxScrollRow, accuracy: 0.01)
    }

    func testFollowingIsRefusedWithUnsavedEdits() {
        let (view, _, _, _) = makeView(lineCount: 5, visibleRows: 10)
        XCTAssertTrue(view.canFollow)
        view.viewport.document?.replace(0..<0, with: Array("typed ".utf8))
        XCTAssertFalse(view.canFollow, "the piece table addresses the old mapping")
    }
}
