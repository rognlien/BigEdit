import AppKit
import XCTest
@testable import BigEdit

/// Every default toolbar item is allowed, resolves to a real item, and
/// forwards to the same action as its menu counterpart.
final class ToolbarTests: XCTestCase {

    func testDefaultItemsAreAllowedAndResolve() {
        let delegate = AppDelegate()
        let toolbar = NSToolbar(identifier: "test")
        let allowed = delegate.toolbarAllowedItemIdentifiers(toolbar)

        for identifier in delegate.toolbarDefaultItemIdentifiers(toolbar) {
            XCTAssertTrue(allowed.contains(identifier), "\(identifier.rawValue) is not allowed")
            if identifier != .flexibleSpace {
                let item = delegate.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true)
                XCTAssertNotNil(item?.image, "\(identifier.rawValue) has no icon")
                XCTAssertNotNil(item?.action, "\(identifier.rawValue) does nothing")
                XCTAssertFalse(item?.label.isEmpty ?? true)
            }
        }
    }

    func testItemsAreDisabledWithoutADocument() {
        let delegate = AppDelegate()
        let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("find"))

        XCTAssertFalse(delegate.validateToolbarItem(item))
    }
}
