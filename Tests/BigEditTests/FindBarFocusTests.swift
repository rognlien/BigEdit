import AppKit
import XCTest
@testable import BigEdit

/// Tab moves between the find and replace fields when both are showing.
final class FindBarFocusTests: XCTestCase {

    private func makeBar() -> (window: NSWindow, bar: FindBar) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let bar = FindBar(frame: window.contentView!.bounds)
        window.contentView!.addSubview(bar)
        return (window, bar)
    }

    private func send(_ selector: Selector, from field: NSControl, in bar: FindBar) -> Bool {
        bar.control(field, textView: NSTextView(), doCommandBy: selector)
    }

    func testTabMovesFromFindToReplace() {
        let (_, bar) = makeBar()
        bar.mode = .findAndReplace
        bar.focusSearchField()

        let handled = send(#selector(NSResponder.insertTab(_:)), from: bar.searchField, in: bar)

        XCTAssertTrue(handled)
        XCTAssertNotNil(bar.replacementField.currentEditor())
        XCTAssertNil(bar.searchField.currentEditor())
    }

    func testShiftTabMovesFromReplaceBackToFind() {
        let (window, bar) = makeBar()
        bar.mode = .findAndReplace
        window.makeFirstResponder(bar.replacementField)

        let handled = send(#selector(NSResponder.insertBacktab(_:)), from: bar.replacementField, in: bar)

        XCTAssertTrue(handled)
        XCTAssertNotNil(bar.searchField.currentEditor())
        XCTAssertNil(bar.replacementField.currentEditor())
    }

    func testTabIsLeftToAppKitWithoutAReplaceRow() {
        let (_, bar) = makeBar()
        bar.mode = .find
        bar.focusSearchField()

        let handled = send(#selector(NSResponder.insertTab(_:)), from: bar.searchField, in: bar)

        XCTAssertFalse(handled)
        XCTAssertNotNil(bar.searchField.currentEditor())
    }
}
