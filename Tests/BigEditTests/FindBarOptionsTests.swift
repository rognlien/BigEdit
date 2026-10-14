import AppKit
import XCTest
@testable import BigEdit

/// The search options live in the field's magnifier menu; choosing one flips
/// it and re-runs the query, and the results-list item mirrors the panel.
final class FindBarOptionsTests: XCTestCase {

    private final class Recorder: FindBarDelegate {
        var submitted: [String] = []
        var resultsToggles = 0
        func findBar(_ bar: FindBar, didSubmitQuery query: String) { submitted.append(query) }
        func findBarRequestedNext(_ bar: FindBar) {}
        func findBarRequestedPrevious(_ bar: FindBar) {}
        func findBarRequestedClose(_ bar: FindBar) {}
        func findBarRequestedResultsToggle(_ bar: FindBar) { resultsToggles += 1 }
        func findBar(_ bar: FindBar, didRequestReplaceAll pattern: String, with replacement: String) {}
        func findBarRequestedRevert(_ bar: FindBar) {}
    }

    func testDefaultsAreCaseSensitiveAndLiteral() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 600, height: 34))

        XCTAssertTrue(bar.isCaseSensitive)
        XCTAssertFalse(bar.isRegularExpression)
        XCTAssertNotNil(bar.searchField.searchMenuTemplate, "the options hang off the magnifier")
    }

    func testChoosingAnOptionFlipsItAndResubmitsTheQuery() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 600, height: 34))
        let recorder = Recorder()
        bar.delegate = recorder
        bar.searchField.stringValue = "needle"

        bar.toggleOption(matchCase: true)
        bar.toggleOption(regularExpression: true)

        XCTAssertFalse(bar.isCaseSensitive)
        XCTAssertTrue(bar.isRegularExpression)
        XCTAssertEqual(recorder.submitted, ["needle", "needle"])
    }

    func testShowAllMatchesOnlyAsksForTheList() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 600, height: 34))
        let recorder = Recorder()
        bar.delegate = recorder

        bar.toggleOption(showAllMatches: true)

        XCTAssertEqual(recorder.resultsToggles, 1)
        XCTAssertTrue(recorder.submitted.isEmpty)
    }

    func testDotMatchesNewlineIsOffByDefaultAndResubmits() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 600, height: 34))
        let recorder = Recorder()
        bar.delegate = recorder
        bar.searchField.stringValue = "a.b"

        XCTAssertFalse(bar.isDotMatchingNewline)
        XCTAssertFalse(bar.regularExpressionOptions.contains(.dotMatchesLineSeparators))
        bar.toggleOption(dotMatchesNewline: true)

        XCTAssertTrue(bar.isDotMatchingNewline)
        XCTAssertTrue(bar.regularExpressionOptions.contains(.dotMatchesLineSeparators))
        XCTAssertTrue(bar.regularExpressionOptions.contains(.anchorsMatchLines))
        XCTAssertEqual(recorder.submitted, ["a.b"])
    }

    func testTheReferenceCardListsEveryEntry() {
        let card = RegexReferencePopover.makeCard()
        let labels = card.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains("(abc)"))
        XCTAssertEqual(labels.count, RegexReferencePopover.entries.count * 2 + 1)
    }

    func testReplaceFieldLinesUpUnderTheSearchField() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 800, height: 68))
        bar.mode = .findAndReplace

        XCTAssertEqual(bar.searchField.frame.minX, bar.replacementField.frame.minX)
        XCTAssertEqual(bar.searchField.frame.width, bar.replacementField.frame.width)
        XCTAssertGreaterThan(bar.searchField.frame.minY, bar.replacementField.frame.minY)
    }
}
