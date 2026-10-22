import AppKit
import XCTest
@testable import BigEdit

/// Backspace and Forward Delete remove what `NSTextView` removes: a whole
/// emoji, flag or accented Latin letter, but one mark at a time from an
/// Indic, Thai, Arabic or Hebrew cluster when going backwards.
final class CharacterDeletionTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    /// Text after a one-letter prefix, so Forward Delete has a cluster to
    /// remove at offset 1 and Backspace one at the end.
    private let samples = [
        "ae\u{301}", "ae\u{301}\u{323}", "a\u{E9}", "ao\u{304}\u{300}", "aα\u{301}", "aи\u{306}",
        "a👍🏽", "a🇳🇴", "a🇳🇴🇸🇪", "a👨‍👩‍👧", "a👩🏽‍💻", "a1\u{FE0F}\u{20E3}", "a\u{2764}\u{FE0F}",
        "a🏴󠁧󠁢󠁥󠁮󠁧󠁿", "aA\u{20DD}", "a\u{1100}\u{1161}\u{11A8}", "a각\u{301}",
        "aकि", "aक्", "aक्षि", "aक्\u{200D}ष", "aকী", "aகொ", "aக்ஷ", "aകൊ", "aกี่", "aกำ",
        "aبَ", "aשָׁ", "a\u{600}1", "a\r\n", "a\u{200D}",
    ]

    private func makeViewport(_ text: String, encoding: TextEncoding = .utf8,
                              caret: Int) -> (ViewportView, EditedDocument) {
        let url = TestHelpers.writeTempFile(Data(encoding.encode(text)!))
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.encoding = encoding
        document.isEditable = true
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.setTextEncoding(encoding)
        viewport.selection = TextSelection(anchorOffset: caret, activeOffset: caret)
        return (viewport, document)
    }

    private func makeCSVViewport(_ text: String, encoding: TextEncoding = .utf8,
                                 caret: Int) -> (ViewportView, EditedDocument) {
        let (viewport, document) = makeViewport(text, encoding: encoding, caret: caret)
        let dialect = CSVDialect()
        viewport.setCSVRendering(dialect: dialect,
                                 columnLayout: CSVColumnLayout.measure(file: document.file, dialect: dialect,
                                                                       encoding: encoding))
        return (viewport, document)
    }

    private func text(of document: EditedDocument) -> String {
        document.encoding.decode(document.bytes(in: 0..<document.length))
    }

    private func textView(_ text: String, caret: Int) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.string = text
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }

    private func scalars(_ text: String) -> String {
        text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
    }

    // MARK: - The system text view as the oracle

    func testBackspaceRemovesWhatNSTextViewRemoves() {
        for sample in samples {
            let (viewport, document) = makeViewport(sample, caret: sample.utf8.count)
            let oracle = textView(sample, caret: sample.utf16.count)

            viewport.deleteBackward(nil)
            oracle.deleteBackward(nil)

            XCTAssertEqual(scalars(text(of: document)), scalars(oracle.string), scalars(sample))
        }
    }

    func testForwardDeleteRemovesWhatNSTextViewRemoves() {
        for sample in samples where sample.first == "a" {
            let (viewport, document) = makeViewport(sample, caret: 1)
            let oracle = textView(sample, caret: 1)

            viewport.deleteForward(nil)
            oracle.deleteForward(nil)

            XCTAssertEqual(scalars(text(of: document)), scalars(oracle.string), scalars(sample))
        }
    }

    func testControlBackspaceDecomposesAsNSTextViewDoes() {
        for sample in samples + ["a각", "a\u{0BCA}", "abc"] {
            let (viewport, document) = makeViewport(sample, caret: sample.utf8.count)
            let oracle = textView(sample, caret: sample.utf16.count)

            viewport.deleteBackwardByDecomposingPreviousCharacter(nil)
            oracle.deleteBackwardByDecomposingPreviousCharacter(nil)

            XCTAssertEqual(scalars(text(of: document)), scalars(oracle.string), scalars(sample))
            XCTAssertEqual(viewport.caretByteOffset, document.length, scalars(sample))
        }
    }

    // MARK: - Backspace

    func testBackspaceRemovesAWholeEmoji() {
        let (viewport, document) = makeViewport("ok 👍🏽", caret: 11)

        viewport.deleteBackward(nil)

        XCTAssertEqual(text(of: document), "ok ")
        XCTAssertEqual(viewport.caretByteOffset, 3)
    }

    func testBackspaceRemovesAnIndicVowelSignAlone() {
        let (viewport, document) = makeViewport("कि", caret: 6)

        viewport.deleteBackward(nil)

        XCTAssertEqual(text(of: document), "क")
    }

    func testBackspaceRemovesALatinLetterWithItsAccent() {
        let (viewport, document) = makeViewport("cafe\u{301}", caret: 6)

        viewport.deleteBackward(nil)

        XCTAssertEqual(text(of: document), "caf")
    }

    func testForwardDeleteRemovesAWholeFlag() {
        let (viewport, document) = makeViewport("🇳🇴🇸🇪", caret: 0)

        viewport.deleteForward(nil)

        XCTAssertEqual(text(of: document), "🇸🇪")
        XCTAssertEqual(viewport.caretByteOffset, 0)
    }

    func testAClusterLongerThanTheLookBehindIsDeletedInParts() {
        let marks = String(repeating: "\u{301}", count: EditedDocument.graphemeLookLength)
        let (viewport, document) = makeViewport("e" + marks, caret: 1 + 2 * EditedDocument.graphemeLookLength)

        viewport.deleteBackward(nil)

        XCTAssertGreaterThan(document.length, 0)
    }

    func testASelectionIsDeletedAsItIs() {
        let (viewport, document) = makeViewport("a👍🏽b", caret: 0)
        viewport.selection = TextSelection(anchorOffset: 1, activeOffset: 5)

        viewport.deleteBackward(nil)

        XCTAssertEqual(scalars(text(of: document)), scalars("a\u{1F3FD}b"))
    }

    func testABackspaceRunOverEmojiUndoesInOneStep() {
        let (viewport, document) = makeViewport("x👍🏽🇳🇴", caret: 17)

        viewport.deleteBackward(nil)
        viewport.deleteBackward(nil)
        XCTAssertEqual(text(of: document), "x")
        viewport.undo(nil)

        XCTAssertEqual(text(of: document), "x👍🏽🇳🇴")
    }

    // MARK: - Windows-1252

    func testWindows1252DeletesOneByteAtATime() {
        let (viewport, document) = makeViewport("café", encoding: .windows1252, caret: 4)

        viewport.deleteBackward(nil)
        XCTAssertEqual(text(of: document), "caf")
        viewport.selection = TextSelection(anchorOffset: 0, activeOffset: 0)
        viewport.deleteForward(nil)

        XCTAssertEqual(text(of: document), "af")
    }

    func testControlBackspaceInWindows1252TakesTheAccentOff() {
        let (viewport, document) = makeViewport("café", encoding: .windows1252, caret: 4)

        viewport.deleteBackwardByDecomposingPreviousCharacter(nil)

        XCTAssertEqual(text(of: document), "cafe")
        XCTAssertEqual(viewport.caretByteOffset, 4)
    }

    func testControlBackspaceDeletesASelection() {
        let (viewport, document) = makeViewport("café", caret: 0)
        viewport.selection = TextSelection(anchorOffset: 1, activeOffset: 5)

        viewport.deleteBackwardByDecomposingPreviousCharacter(nil)

        XCTAssertEqual(text(of: document), "c")
    }

    func testWindows1252DeletesACRLFPairAsOne() {
        let (viewport, document) = makeViewport("a\r\nb", encoding: .windows1252, caret: 3)

        viewport.deleteBackward(nil)

        XCTAssertEqual(text(of: document), "ab")
    }

    // MARK: - CSV cells

    func testBackspaceInACellRemovesAWholeEmoji() {
        let (viewport, document) = makeCSVViewport("a,x👍🏽\nb,c\n", caret: 11)

        viewport.deleteBackward(nil)

        XCTAssertEqual(text(of: document), "a,x\nb,c\n")
    }

    func testForwardDeleteInAQuotedCellRemovesAWholeFlag() {
        let (viewport, document) = makeCSVViewport("a,\"🇳🇴,\"\n", caret: 3)

        viewport.deleteForward(nil)

        XCTAssertEqual(text(of: document), "a,\",\"\n")
    }

    func testBackspaceInACellRemovesAnIndicVowelSignAlone() {
        let (viewport, document) = makeCSVViewport("a,कि\n", caret: 8)

        viewport.deleteBackward(nil)

        XCTAssertEqual(text(of: document), "a,क\n")
    }

    func testACellStartingWithAMarkStillStopsAtItsEdge() {
        let (viewport, document) = makeCSVViewport("e,\u{301}x\n", caret: 4)

        viewport.deleteBackward(nil)
        XCTAssertEqual(text(of: document), "e,x\n")
        viewport.deleteBackward(nil)

        XCTAssertEqual(text(of: document), "e,x\n", "the delimiter is not deleted")
    }

    func testACellClusterNeverTakesInAQuote() {
        let field = Array("\"a\"\"\u{301}\"".utf8)

        let range = CSVCellEditing.deletion(backward: true, at: 6, inField: field,
                                            dialect: CSVDialect(), encoding: .utf8)

        XCTAssertEqual(range, 4..<6)
    }
}
