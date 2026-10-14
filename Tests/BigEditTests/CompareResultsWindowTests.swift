import AppKit
import XCTest
@testable import BigEdit

/// The result window shows one section at a time and exports exactly that
/// section's lines.
final class CompareResultsWindowTests: XCTestCase {

    private func makeWindow() -> CompareResultsWindow {
        CompareResultsWindow(title: "a compared with b", sections: [
            CompareSection(title: "Only in a", rows: [CompareRow("x"), CompareRow("y")],
                           suggestedFileName: "Only in a.txt"),
            CompareSection(title: "Only in b", rows: [], suggestedFileName: "Only in b.txt"),
            CompareSection(title: "In both", rows: [CompareRow("z")], suggestedFileName: "In both.txt")
        ])
    }

    func testStartsOnTheFirstSection() {
        let window = makeWindow()
        XCTAssertEqual(window.selectedSection.title, "Only in a")
        XCTAssertEqual(window.numberOfRows(in: NSTableView()), 2)
    }

    func testSelectingASectionChangesTheRows() {
        let window = makeWindow()
        window.selectSection(2)
        XCTAssertEqual(window.selectedSection.title, "In both")
        XCTAssertEqual(window.numberOfRows(in: NSTableView()), 1)
        window.selectSection(1)
        XCTAssertEqual(window.numberOfRows(in: NSTableView()), 0)
    }

    func testExportTextIsOneLinePerRow() {
        let window = makeWindow()
        XCTAssertEqual(window.selectedSection.exportText, "x\ny\n")
        window.selectSection(1)
        XCTAssertEqual(window.selectedSection.exportText, "")
    }

    func testRowKindsAreColoured() {
        let added = CompareResultsWindow.attributedText(for: CompareRow("+a", kind: .added))
        let removed = CompareResultsWindow.attributedText(for: CompareRow("-a", kind: .removed))
        let addedColour = added.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let removedColour = removed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(addedColour, removedColour)
    }
}
