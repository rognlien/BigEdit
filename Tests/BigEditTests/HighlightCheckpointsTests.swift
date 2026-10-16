import AppKit
import XCTest
@testable import BigEdit

final class HighlightCheckpointsTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private let inComment = HighlightState(JSONHighlighter.State.blockComment, of: JSONHighlighter.self)

    func testTheTopOfTheDocumentIsAlwaysKnown() {
        let checkpoints = HighlightCheckpoints()

        let nearest = checkpoints.nearest(atOrAbove: 10_000)

        XCTAssertEqual(nearest.row, 0)
        XCTAssertEqual(nearest.state, .normal)
    }

    func testOnlyARowThatExtendsTheChainIsRemembered() {
        var checkpoints = HighlightCheckpoints()
        let interval = HighlightCheckpoints.interval

        checkpoints.record(inComment, atRow: 2 * interval)
        XCTAssertEqual(checkpoints.nearest(atOrAbove: 3 * interval).row, 0)

        checkpoints.record(inComment, atRow: interval)
        let nearest = checkpoints.nearest(atOrAbove: 3 * interval)
        XCTAssertEqual(nearest.row, interval)
        XCTAssertEqual(nearest.state, inComment)
    }

    func testInvalidatingForgetsCheckpointsAtAndBelowTheRow() {
        var checkpoints = HighlightCheckpoints()
        let interval = HighlightCheckpoints.interval
        checkpoints.record(inComment, atRow: interval)
        checkpoints.record(inComment, atRow: 2 * interval)

        checkpoints.invalidate(fromRow: 2 * interval)
        XCTAssertEqual(checkpoints.nearest(atOrAbove: 3 * interval).row, interval)

        checkpoints.invalidate(fromRow: interval - 1)
        XCTAssertEqual(checkpoints.nearest(atOrAbove: 3 * interval).row, 0)
    }

    // MARK: - In the viewport

    private func makeViewport(_ text: String) -> ViewportView {
        let url = TestHelpers.writeTempFile(text)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.isEditable = true
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.setLanguage(LanguageRegistry.json)
        return viewport
    }

    /// A comment opened 1,000 rows above the viewport, beyond the replay
    /// window, scrolled down to a page at a time.
    private let longComment = "/*\n" + String(repeating: "inside\n", count: 1_000) + "*/\n{}\n"

    private func scrollDown(_ viewport: ViewportView, to row: Int) -> HighlightState {
        var state = HighlightState.normal
        for firstRow in stride(from: 0, through: row, by: 50) {
            state = viewport.seedState(forFirstRow: firstRow, layout: viewport.layout!)
        }
        return state
    }

    func testAConstructOpenedFarAboveIsSeenWhenScrolledTo() {
        let viewport = makeViewport(longComment)

        XCTAssertEqual(scrollDown(viewport, to: 1_000), inComment)
    }

    func testAJumpPastTheReplayWindowStillGuesses() {
        let viewport = makeViewport(longComment)

        XCTAssertEqual(viewport.seedState(forFirstRow: 1_000, layout: viewport.layout!), .normal)
    }

    func testAnEditAboveTheViewportIsTakenIntoAccount() {
        let viewport = makeViewport(longComment)
        _ = scrollDown(viewport, to: 1_000)

        viewport.document!.replace(0..<2, with: Array("//".utf8))

        XCTAssertEqual(viewport.seedState(forFirstRow: 1_000, layout: viewport.layout!), .normal)
    }
}
