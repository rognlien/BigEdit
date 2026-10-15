import XCTest
@testable import BigEdit

/// The selection highlight fills to the viewport edge only when the
/// selection runs past the row's text.
final class SelectionHighlightTests: XCTestCase {

    func testASelectionEndingAtTheEndOfTheTextStopsThere() {
        XCTAssertFalse(ViewportView.selectionRunsPastRow(4..<13, rowEnd: 13))
    }

    func testASelectionIncludingTheLineEndingFillsToTheEdge() {
        XCTAssertTrue(ViewportView.selectionRunsPastRow(4..<14, rowEnd: 13))
    }

    func testASelectionEndingInsideTheRowStopsAtItsEnd() {
        XCTAssertFalse(ViewportView.selectionRunsPastRow(4..<8, rowEnd: 13))
    }
}
