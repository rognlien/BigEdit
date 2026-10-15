import AppKit
import XCTest
@testable import BigEdit

/// Command-arrows move to the ends of the line and the document, and
/// Shift-Command-arrows select to them, as in every other Mac text view.
final class CommandArrowKeyTests: XCTestCase {

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

    private func press(_ keyCode: UInt16, shift: Bool = false, in viewport: ViewportView) {
        let arrows: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
                                     125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey]
        let character = String(UnicodeScalar(UInt32(arrows[keyCode]!))!)
        let flags: NSEvent.ModifierFlags = shift ? [.command, .shift, .function] : [.command, .function]
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: character, charactersIgnoringModifiers: character,
                                     isARepeat: false, keyCode: keyCode)!
        viewport.keyDown(with: event)
    }

    func testCommandLeftAndRightMoveToTheEndsOfTheLine() {
        let viewport = makeViewport("one\ntwo three\nfour\n", caret: 7)

        press(124, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 13)

        press(123, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 4)
    }

    func testCommandUpAndDownMoveToTheEndsOfTheDocument() {
        let viewport = makeViewport("one\ntwo\nthree\n", caret: 5)

        press(125, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 14)

        press(126, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 0)
    }

    func testShiftCommandRightFromTheStartSelectsTheWholeLine() {
        let viewport = makeViewport("one\ntwo three\nfour\n", caret: 4)

        press(124, shift: true, in: viewport)

        XCTAssertEqual(viewport.selectionByteRange, 4..<13)
    }

    func testShiftCommandLeftSelectsBackToTheStartOfTheLine() {
        let viewport = makeViewport("one\ntwo three\n", caret: 8)

        press(123, shift: true, in: viewport)

        XCTAssertEqual(viewport.selectionByteRange, 4..<8)
    }

    func testShiftCommandUpAndDownSelectToTheEndsOfTheDocument() {
        let viewport = makeViewport("one\ntwo\nthree\n", caret: 5)

        press(125, shift: true, in: viewport)
        XCTAssertEqual(viewport.selectionByteRange, 5..<14)

        press(126, shift: true, in: viewport)
        XCTAssertEqual(viewport.selectionByteRange, 0..<5)
    }

    func testCommandArrowsWorkInAReadOnlyDocument() {
        let viewport = makeViewport("one\ntwo\n", caret: 5)
        XCTAssertFalse(viewport.document?.isEditable ?? true)

        press(124, in: viewport)

        XCTAssertEqual(viewport.caretByteOffset, 7)
    }

    func testCommandDownWithoutACaretStillReachesTheEnd() {
        let viewport = makeViewport((0..<200).map { "line \($0)\n" }.joined(), caret: 0)
        viewport.selection = nil

        press(125, in: viewport)

        XCTAssertEqual(viewport.caretByteOffset, viewport.document?.length)
        XCTAssertEqual(viewport.scrollRow, viewport.maxScrollRow, accuracy: 0.01)
    }
}
