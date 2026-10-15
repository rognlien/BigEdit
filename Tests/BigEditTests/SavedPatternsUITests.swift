import AppKit
import XCTest
@testable import BigEdit

/// Choosing a saved pattern fills the find bar and the Process Lines sheet
/// the way typing it would, and the find bar's menu follows the library.
final class SavedPatternsUITests: XCTestCase {

    private final class Recorder: FindBarDelegate {
        var submitted: [String] = []
        var manageRequests = 0
        func findBar(_ bar: FindBar, didSubmitQuery query: String) { submitted.append(query) }
        func findBarRequestedNext(_ bar: FindBar) {}
        func findBarRequestedPrevious(_ bar: FindBar) {}
        func findBarRequestedClose(_ bar: FindBar) {}
        func findBarRequestedResultsToggle(_ bar: FindBar) {}
        func findBar(_ bar: FindBar, didRequestReplaceAll pattern: String, with replacement: String) {}
        func findBarRequestedRevert(_ bar: FindBar) {}
        func findBarRequestedManagePatterns(_ bar: FindBar) { manageRequests += 1 }
    }

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditPatternsUI-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func library() -> PatternLibrary {
        PatternLibrary(fileURL: directory.appendingPathComponent(PatternLibrary.fileName))
    }

    func testApplyingAPatternFillsTheFieldsAndSearches() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 800, height: 68))
        bar.patternLibrary = library()
        let recorder = Recorder()
        bar.delegate = recorder
        bar.mode = .findAndReplace

        bar.apply(SavedPattern(name: "n", pattern: "[0-9]+", replacement: "#",
                               isRegularExpression: true, isCaseSensitive: false))

        XCTAssertEqual(bar.query, "[0-9]+")
        XCTAssertEqual(bar.replacementField.stringValue, "#")
        XCTAssertTrue(bar.isRegularExpression)
        XCTAssertFalse(bar.isCaseSensitive)
        XCTAssertEqual(recorder.submitted, ["[0-9]+"])
    }

    func testTheMenuListsTheLibrary() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 800, height: 34))
        let patterns = library()
        bar.patternLibrary = patterns
        XCTAssertNil(bar.savedPattern(at: 0))

        patterns.add(SavedPattern(name: "first", pattern: "a"))
        patterns.add(SavedPattern(name: "second", pattern: "b"))

        XCTAssertEqual(bar.savedPattern(at: 1)?.name, "second")
        let submenu = bar.searchField.searchMenuTemplate?.items
            .first { $0.title == "Saved Patterns" }?.submenu
        XCTAssertEqual(submenu?.items.map(\.title), ["first", "second"])
    }

    func testCurrentPatternCapturesTheFields() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 800, height: 68))
        bar.patternLibrary = library()
        XCTAssertNil(bar.currentPattern, "nothing to save while the query is empty")

        bar.searchField.stringValue = "needle"
        bar.replacementField.stringValue = "thread"
        bar.toggleOption(regularExpression: true)
        let pattern = bar.currentPattern

        XCTAssertEqual(pattern?.pattern, "needle")
        XCTAssertEqual(pattern?.replacement, "thread")
        XCTAssertEqual(pattern?.isRegularExpression, true)
        XCTAssertEqual(pattern?.name, "needle")
    }

    func testProcessLinesSheetTakesAPattern() {
        let sheet = ProcessLinesSheet()
        sheet.patternLibrary = library()
        sheet.apply(SavedPattern(name: "n", pattern: "x+", replacement: "y"))
        XCTAssertEqual(sheet.enteredPattern, "x+")
        XCTAssertEqual(sheet.enteredReplacement, "y")
    }
}
