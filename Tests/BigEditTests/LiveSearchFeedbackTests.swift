import AppKit
import XCTest
@testable import BigEdit

/// Typing into the find bar gets an answer before Enter: a broken pattern
/// is explained, a sound one is run on a small document after a pause, and
/// the replacement field shows what `$1` will expand to.
final class LiveSearchFeedbackTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeView(_ content: String) -> DocumentView {
        let url = TestHelpers.writeTempFile(content)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let view = TestHelpers.isolatedDocumentView()
        view.load(file: file, index: index)
        view.showFindBar(replace: true)
        return view
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    private func wait(_ timeout: TimeInterval = 2, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testABrokenPatternIsExplainedAsItIsTyped() {
        let view = makeView("alpha\nbeta\n")
        view.findBar.toggleOption(regularExpression: true)

        view.findBar.simulateTyping(query: "(al")

        XCTAssertEqual(view.findBar.statusText, "Unclosed “(” group")
        XCTAssertTrue(view.findBar.statusShowsProblem)
        XCTAssertNil(view.searchScan)
    }

    func testASoundQueryRunsAfterAPauseWithoutMovingTheViewport() {
        let view = makeView((0..<300).map { "line \($0)\n" }.joined())
        view.viewport.setScrollRow(0)

        view.findBar.simulateTyping(query: "line 2")

        XCTAssertNil(view.searchScan, "nothing runs on the keystroke itself")
        XCTAssertTrue(wait { view.searchScan?.isComplete == true }, "the search ran after the pause")
        XCTAssertEqual(view.currentQuery, "line 2")
        XCTAssertEqual(view.currentMatchIndex, -1, "typing does not jump to a match")
        XCTAssertEqual(view.viewport.scrollRow, 0, accuracy: 0.01)
    }

    func testReplacementPreviewExpandsGroupsForTheCurrentMatch() {
        let view = makeView("id 42\nid 7\n")
        view.findBar.toggleOption(regularExpression: true)
        view.findBar(view.findBar, didSubmitQuery: "id (\\d+)")
        XCTAssertTrue(wait { view.currentMatchIndex == 0 })

        view.findBar.simulateTyping(replacement: "number $1")

        XCTAssertTrue(wait { view.findBar.replaceStatusText == "→ number 42" })
    }

    func testAnEmptyQueryClearsTheSearch() {
        let view = makeView("alpha\n")
        view.findBar(view.findBar, didSubmitQuery: "alpha")
        view.findBar.simulateTyping(query: "")
        XCTAssertNil(view.searchScan)
        XCTAssertEqual(view.findBar.statusText, "")
    }
}
