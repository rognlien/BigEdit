import AppKit
import XCTest
@testable import BigEdit

/// Option-arrows and Option-Control-F/B move by word, landing where
/// `NSTextView` lands from every position in the samples.
final class WordMovementTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    /// Scripts whose words come from a dictionary, such as Japanese and
    /// Thai, are left out: the system text view segments them with more
    /// context than a word step reads.
    private let samples = [
        "hello, world  foo_bar.baz 3.14 don't\nnext line",
        "café crème — naïve résumé\r\nzwei Wörter",
        "an emoji 👍🏽 。 ok, Привет мир",
        "  leading\n\n\ttabs\tand (brackets) [x] {y}",
        "path/to/file.txt key=value 192.168.0.1 e-mail",
        "a -- b ... c !! d x = y + z; // comment",
    ]

    private func makeViewport(_ text: String, caret: Int) -> (ViewportView, EditedDocument) {
        let url = TestHelpers.writeTempFile(text)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.isEditable = true
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.selection = TextSelection(anchorOffset: caret, activeOffset: caret)
        return (viewport, document)
    }

    private func textView(_ text: String, selection: NSRange) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 2000, height: 200))
        view.string = text
        view.setSelectedRange(selection)
        return view
    }

    /// Every caret position of `text`, as a UTF-16 offset and a byte offset.
    private func caretPositions(in text: String) -> [(utf16: Int, byte: Int)] {
        var positions = [(utf16: 0, byte: 0)]
        var index = text.startIndex
        while index < text.endIndex {
            index = text.index(after: index)
            positions.append((text[..<index].utf16.count, text[..<index].utf8.count))
        }
        return positions
    }

    private func byteOffset(ofUTF16 offset: Int, in text: String) -> Int {
        text[..<String.Index(utf16Offset: offset, in: text)].utf8.count
    }

    private func assertMatchesTextView(_ move: (ViewportView) -> Void, _ oracle: (NSTextView) -> Void,
                                       file: StaticString = #filePath, line: UInt = #line) {
        for sample in samples {
            for position in caretPositions(in: sample) {
                let (viewport, _) = makeViewport(sample, caret: position.byte)
                let view = textView(sample, selection: NSRange(location: position.utf16, length: 0))

                move(viewport)
                oracle(view)

                XCTAssertEqual(viewport.caretByteOffset, byteOffset(ofUTF16: view.selectedRange().location, in: sample),
                               "from \(position.utf16) in \(sample.debugDescription)", file: file, line: line)
            }
        }
    }

    func testOptionRightLandsWhereNSTextViewLands() {
        assertMatchesTextView({ $0.moveWordRight(nil) }, { $0.moveWordRight(nil) })
    }

    func testOptionLeftLandsWhereNSTextViewLands() {
        assertMatchesTextView({ $0.moveWordLeft(nil) }, { $0.moveWordLeft(nil) })
    }

    func testOptionControlFAndBLandWhereNSTextViewLands() {
        assertMatchesTextView({ $0.moveWordForward(nil) }, { $0.moveWordForward(nil) })
        assertMatchesTextView({ $0.moveWordBackward(nil) }, { $0.moveWordBackward(nil) })
    }

    func testAWordMoveCollapsesASelectionFromTheEdgeItMovesTowards() {
        let (viewport, _) = makeViewport("one two three", caret: 0)
        viewport.selection = TextSelection(anchorOffset: 4, activeOffset: 7)
        viewport.moveWordForward(nil)
        XCTAssertEqual(viewport.caretByteOffset, 13)

        viewport.selection = TextSelection(anchorOffset: 7, activeOffset: 4)
        viewport.moveWordBackward(nil)
        XCTAssertEqual(viewport.caretByteOffset, 0)
    }

    func testShiftOptionArrowsExtendTheSelectionByWord() {
        let (viewport, _) = makeViewport("one two three", caret: 4)

        viewport.moveWordRightAndModifySelection(nil)
        viewport.moveWordRightAndModifySelection(nil)
        XCTAssertEqual(viewport.selectionByteRange, 4..<13)
        viewport.moveWordLeftAndModifySelection(nil)
        XCTAssertEqual(viewport.selectionByteRange, 4..<8)
    }

    func testAWordLongerThanTheLookAheadIsSteppedInParts() {
        let word = String(repeating: "x", count: ViewportView.wordLookLength * 2)
        let (viewport, document) = makeViewport(word + " end", caret: 0)

        viewport.moveWordForward(nil)
        XCTAssertGreaterThan(viewport.caretByteOffset!, 0)
        viewport.moveWordForward(nil)
        viewport.moveWordForward(nil)

        XCTAssertEqual(viewport.caretByteOffset, document.length)
    }

    func testWordMovesInWindows1252() {
        let text = "café crème"
        let url = TestHelpers.writeTempFile(Data(TextEncoding.windows1252.encode(text)!))
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.encoding = .windows1252
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.setTextEncoding(.windows1252)
        viewport.selection = TextSelection(anchorOffset: 0, activeOffset: 0)

        viewport.moveWordForward(nil)
        XCTAssertEqual(viewport.caretByteOffset, 4)
        viewport.moveWordForward(nil)
        XCTAssertEqual(viewport.caretByteOffset, 10)
        viewport.moveWordBackward(nil)
        XCTAssertEqual(viewport.caretByteOffset, 5)
    }
}
