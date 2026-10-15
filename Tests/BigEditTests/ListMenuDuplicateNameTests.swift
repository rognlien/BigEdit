import AppKit
import XCTest
@testable import BigEdit

/// Open documents can share a name — the same file opened twice, or two
/// files called the same in different folders. Every document keeps its own
/// menu item, and choosing an item picks that document, not one shifted by
/// the repeats before it.
final class ListMenuDuplicateNameTests: XCTestCase {

    private func lists(_ names: [String]) -> [OtherLineList] {
        names.map { name in OtherLineList(name: name, byteCount: 0) { [name] } }
    }

    func testTheOtherListMenuKeepsRepeatedNames() {
        let sheet = ProcessLinesSheet()
        sheet.load(otherLists: lists(["a.sql", "a.sql", "b.md", "b.md", "target.txt"]))

        XCTAssertEqual(sheet.otherListTitles, ["a.sql", "a.sql", "b.md", "b.md", "target.txt", "Choose File…"])
    }

    func testChoosingAnItemAfterRepeatsPicksThatDocument() {
        let sheet = ProcessLinesSheet()
        let names = ["a.sql", "a.sql", "b.md", "b.md", "target.txt", "other.txt"]
        sheet.load(otherLists: lists(names))

        sheet.chooseOtherList(atMenuPosition: 4)

        XCTAssertEqual(sheet.selectedOtherListName, "target.txt")
        XCTAssertTrue(sheet.isSelectedOtherList(at: 4))
    }

    func testTheCompareMenusKeepRepeatedNamesAndPickTheRightDocument() {
        let sheet = CompareDocumentsSheet()
        sheet.load(lists: lists(["x.txt", "x.txt", "y.txt", "z.txt"]), activeIndex: 2)

        XCTAssertEqual(sheet.menuItemCounts.first, 4)
        XCTAssertEqual(sheet.menuItemCounts.second, 4)
        XCTAssertEqual(sheet.selectedIndexes.first, 2)
        XCTAssertEqual(sheet.selectedIndexes.second, 3)

        sheet.choose(firstAtMenuPosition: 3, secondAtMenuPosition: 1)

        XCTAssertEqual(sheet.selectedIndexes.first, 3)
        XCTAssertEqual(sheet.selectedIndexes.second, 1)
    }
}
