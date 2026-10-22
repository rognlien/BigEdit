import AppKit
import XCTest
@testable import BigEdit

/// The arrows, Page Up, Page Down, Home and End reach the actions the
/// standard key bindings name for them with each modifier, and before
/// there is a caret the plain arrows still scroll.
final class NavigationKeyTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private enum Key {
        case left, right, down, up, pageUp, pageDown, home, end

        var code: UInt16 {
            switch self {
            case .left: return 123
            case .right: return 124
            case .down: return 125
            case .up: return 126
            case .pageUp: return 116
            case .pageDown: return 121
            case .home: return 115
            case .end: return 119
            }
        }

        var character: Int {
            switch self {
            case .left: return NSLeftArrowFunctionKey
            case .right: return NSRightArrowFunctionKey
            case .down: return NSDownArrowFunctionKey
            case .up: return NSUpArrowFunctionKey
            case .pageUp: return NSPageUpFunctionKey
            case .pageDown: return NSPageDownFunctionKey
            case .home: return NSHomeFunctionKey
            case .end: return NSEndFunctionKey
            }
        }
    }

    private func makeViewport(_ text: String, caret: Int?) -> ViewportView {
        let url = TestHelpers.writeTempFile(text)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.selection = caret.map { TextSelection(anchorOffset: $0, activeOffset: $0) }
        return viewport
    }

    private func press(_ key: Key, _ modifiers: NSEvent.ModifierFlags = [], in viewport: ViewportView) {
        let character = String(UnicodeScalar(UInt32(key.character))!)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers.union(.function),
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: character, charactersIgnoringModifiers: character,
                                     isARepeat: false, keyCode: key.code)!
        viewport.keyDown(with: event)
    }

    private func numberedLines(_ count: Int) -> String {
        (0..<count).map { String(format: "%03d\n", $0) }.joined()
    }

    func testOptionLeftAndRightMoveByWord() {
        let viewport = makeViewport("one, two three", caret: 0)

        press(.right, .option, in: viewport)
        press(.right, .option, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 8)
        press(.left, .option, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 5)
    }

    func testShiftOptionRightSelectsByWord() {
        let viewport = makeViewport("one two three", caret: 4)

        press(.right, [.option, .shift], in: viewport)

        XCTAssertEqual(viewport.selectionByteRange, 4..<7)
    }

    func testOptionUpAndDownMoveToTheEndsOfTheLineThenOn() {
        let viewport = makeViewport("one\ntwo three\nfour\n", caret: 6)

        press(.up, .option, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 4)
        press(.up, .option, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 0)
        press(.down, .option, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 3)
        press(.down, .option, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 13)
    }

    func testShiftOptionDownSelectsToTheEndOfTheLine() {
        let viewport = makeViewport("one\ntwo three\nfour\n", caret: 6)

        press(.down, [.option, .shift], in: viewport)

        XCTAssertEqual(viewport.selectionByteRange, 6..<13)
    }

    func testControlLeftAndRightMoveToTheEndsOfTheLine() {
        let viewport = makeViewport("one\ntwo three\n", caret: 6)

        press(.right, .control, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 13)
        press(.left, .control, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 4)
    }

    func testPageDownAndHomeScrollWithoutMovingTheCaret() {
        let viewport = makeViewport(numberedLines(200), caret: 8)

        press(.pageDown, in: viewport)
        XCTAssertEqual(viewport.scrollRow, Double(viewport.rowsPerPage - 1), accuracy: 0.01)
        press(.end, in: viewport)
        XCTAssertEqual(viewport.scrollRow, viewport.maxScrollRow, accuracy: 0.01)
        press(.pageUp, in: viewport)
        press(.home, in: viewport)
        XCTAssertEqual(viewport.scrollRow, 0, accuracy: 0.01)

        XCTAssertEqual(viewport.caretByteOffset, 8)
    }

    func testShiftPageDownSelectsAPage() {
        let viewport = makeViewport(numberedLines(200), caret: 4)

        press(.pageDown, .shift, in: viewport)

        XCTAssertEqual(viewport.selectionByteRange, 4..<(4 * viewport.rowsPerPage))
    }

    func testShiftEndSelectsToTheEndOfTheDocument() {
        let viewport = makeViewport("one\ntwo\n", caret: 2)

        press(.end, .shift, in: viewport)

        XCTAssertEqual(viewport.selectionByteRange, 2..<8)
    }

    func testOptionPageDownMovesTheCaret() {
        let viewport = makeViewport(numberedLines(200), caret: 0)

        press(.pageDown, .option, in: viewport)

        XCTAssertEqual(viewport.caretByteOffset, 4 * (viewport.rowsPerPage - 1))
    }

    func testWithoutACaretTheArrowsScroll() {
        let viewport = makeViewport(numberedLines(200), caret: nil)

        press(.down, in: viewport)
        press(.down, .option, in: viewport)

        XCTAssertEqual(viewport.scrollRow, 2, accuracy: 0.01)
        XCTAssertNil(viewport.selection)
    }

    func testWithACaretThePlainArrowsMoveIt() {
        let viewport = makeViewport("one\ntwo\n", caret: 1)

        press(.down, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 5)
        press(.right, in: viewport)
        XCTAssertEqual(viewport.caretByteOffset, 6)
        press(.left, .shift, in: viewport)
        XCTAssertEqual(viewport.selectionByteRange, 5..<6)
    }
}
