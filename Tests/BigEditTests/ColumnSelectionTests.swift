import AppKit
import XCTest
@testable import BigEdit

/// Rectangular selection: ⌃⇧↑/↓ grow it from the caret, ⇧ + arrows resize
/// it, and copying takes each row's slice.
final class ColumnSelectionTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeViewport(_ text: String, caret: Int) -> ViewportView {
        let url = TestHelpers.writeTempFile(text)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.selection = TextSelection(anchorOffset: caret, activeOffset: caret)
        return viewport
    }

    private func arrowKey(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union(.function),
                         timestamp: 0, windowNumber: 0, context: nil, characters: "",
                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
    }

    func testRowsAndWidthSelectTheSameColumnsOnEachRow() {
        let viewport = makeViewport("abcd\nefgh\nijkl\n", caret: 1)

        viewport.extendColumnSelection(byRows: 2)
        viewport.widenColumnSelection(byCharacters: 2)

        XCTAssertEqual(viewport.columnSelectionText(cap: 1024), "bc\nfg\njk")
    }

    func testAShortRowContributesWhatItHas() {
        let viewport = makeViewport("abcd\ne\nijkl\n", caret: 1)

        viewport.extendColumnSelection(byRows: 2)
        viewport.widenColumnSelection(byCharacters: 2)

        XCTAssertEqual(viewport.columnSelectionText(cap: 1024), "bc\n\njk")
    }

    func testGrowingUpwardsKeepsTheAnchorRow() {
        let viewport = makeViewport("abcd\nefgh\nijkl\n", caret: 11)

        viewport.extendColumnSelection(byRows: -1)
        viewport.widenColumnSelection(byCharacters: 1)

        XCTAssertEqual(viewport.columnSelectionText(cap: 1024), "f\nj")
    }

    func testTheCaretSitsAtTheActiveCorner() {
        let viewport = makeViewport("abcd\nefgh\nijkl\n", caret: 1)

        viewport.extendColumnSelection(byRows: 1)
        viewport.widenColumnSelection(byCharacters: 2)

        XCTAssertEqual(viewport.caretByteOffset, 8)
    }

    func testControlShiftDownStartsAColumnSelection() {
        let viewport = makeViewport("abcd\nefgh\n", caret: 1)

        XCTAssertTrue(viewport.handleColumnSelectionKey(arrowKey(125, [.control, .shift])))

        XCTAssertEqual(viewport.columnSelection?.rows, 0...1)
    }

    func testShiftArrowsAreLeftAloneWithoutAColumnSelection() {
        let viewport = makeViewport("abcd\nefgh\n", caret: 1)

        XCTAssertFalse(viewport.handleColumnSelectionKey(arrowKey(125, .shift)))
        XCTAssertFalse(viewport.handleColumnSelectionKey(arrowKey(124, .shift)))
    }

    func testShiftRightWidensAnActiveColumnSelection() {
        let viewport = makeViewport("abcd\nefgh\n", caret: 1)
        viewport.extendColumnSelection(byRows: 1)

        XCTAssertTrue(viewport.handleColumnSelectionKey(arrowKey(124, .shift)))

        XCTAssertEqual(viewport.columnSelectionText(cap: 1024), "b\nf")
    }

    func testMovingTheCaretEndsTheColumnSelection() {
        let viewport = makeViewport("abcd\nefgh\n", caret: 1)
        viewport.extendColumnSelection(byRows: 1)

        viewport.moveCaretHorizontally(forward: true, extend: false)

        XCTAssertNil(viewport.columnSelection)
    }

    func testCopyRefusesAColumnSelectionOverTheCap() {
        let viewport = makeViewport("abcd\nefgh\n", caret: 0)
        viewport.extendColumnSelection(byRows: 1)
        viewport.widenColumnSelection(byCharacters: 4)

        XCTAssertNil(viewport.columnSelectionText(cap: 4))
    }
}
