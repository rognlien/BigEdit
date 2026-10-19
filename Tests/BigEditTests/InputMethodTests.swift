import AppKit
import XCTest
@testable import BigEdit

/// The call sequences macOS input methods make — Kotoeri, Pinyin, dead keys,
/// press-and-hold and the Character Viewer — replayed against the viewport,
/// since nobody can type through a real input method in a test.
final class InputMethodTests: XCTestCase {

    private var temporaryFiles: [URL] = []
    private let none = NSRange(location: NSNotFound, length: 0)

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeViewport(_ text: String, encoding: TextEncoding = .utf8,
                              caret: Int? = nil) -> (ViewportView, EditedDocument) {
        let document = makeDocument(text, encoding: encoding)
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.setTextEncoding(encoding)
        let offset = caret ?? document.length
        viewport.selection = TextSelection(anchorOffset: offset, activeOffset: offset)
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

    private func makeDocument(_ text: String, encoding: TextEncoding) -> EditedDocument {
        let url = TestHelpers.writeTempFile(Data(encoding.encode(text)!))
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.encoding = encoding
        document.isEditable = true
        return document
    }

    private func text(of document: EditedDocument) -> String {
        document.encoding.decode(document.bytes(in: 0..<document.length))
    }

    private func bytes(of document: EditedDocument) -> [UInt8] {
        document.bytes(in: 0..<document.length)
    }

    private func mark(_ viewport: ViewportView, _ text: String, selected: NSRange? = nil) {
        let selection = selected ?? NSRange(location: text.utf16.count, length: 0)
        viewport.setMarkedText(text, selectedRange: selection, replacementRange: none)
    }

    private func typeRomajiForKanji(into viewport: ViewportView) {
        mark(viewport, "k")
        mark(viewport, "か")
        mark(viewport, "かん")
        mark(viewport, "かんじ")
        mark(viewport, "漢字", selected: NSRange(location: 0, length: 2))
    }

    // MARK: - Kotoeri romaji

    func testRomajiGrowsTheMarkedTextInPlace() {
        let (viewport, document) = makeViewport("x")

        mark(viewport, "k")
        XCTAssertEqual(viewport.markedRange().length, 1)
        mark(viewport, "か")
        mark(viewport, "かん")
        mark(viewport, "かんじ")

        XCTAssertEqual(text(of: document), "xかんじ")
        XCTAssertTrue(viewport.hasMarkedText())
        XCTAssertEqual(viewport.markedRange().length, 3)
        XCTAssertEqual(viewport.selectedRange(),
                       NSRange(location: viewport.markedRange().location + 3, length: 0))
    }

    func testCommittingWithoutAReplacementRangeKeepsTheConversion() {
        let (viewport, document) = makeViewport("x")
        typeRomajiForKanji(into: viewport)

        viewport.insertText("漢字", replacementRange: none)

        XCTAssertEqual(text(of: document), "x漢字")
        XCTAssertFalse(viewport.hasMarkedText())
        XCTAssertEqual(viewport.markedRange().location, NSNotFound)
        XCTAssertEqual(viewport.caretByteOffset, document.length)
    }

    func testCommittingOverTheMarkedRangeReplacesExactlyIt() {
        let (viewport, document) = makeViewport("x\ny")
        viewport.selection = TextSelection(anchorOffset: 1, activeOffset: 1)
        typeRomajiForKanji(into: viewport)

        viewport.insertText("漢字", replacementRange: viewport.markedRange())

        XCTAssertEqual(text(of: document), "x漢字\ny")
        XCTAssertFalse(viewport.hasMarkedText())
        XCTAssertEqual(viewport.caretByteOffset, 1 + "漢字".utf8.count)
    }

    // MARK: - Pinyin

    func testPinyinLettersCommitAsHanCharacters() {
        let (viewport, document) = makeViewport("")

        ["n", "ni", "nih", "niha", "nihao"].forEach { mark(viewport, $0) }
        XCTAssertEqual(text(of: document), "nihao")
        viewport.insertText("你好", replacementRange: none)

        XCTAssertEqual(text(of: document), "你好")
        XCTAssertFalse(viewport.hasMarkedText())
    }

    func testEscapeLeavesTheDocumentAsItWas() {
        let (viewport, document) = makeViewport("ab", caret: 1)

        ["n", "ni"].forEach { mark(viewport, $0) }
        viewport.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: none)
        viewport.unmarkText()

        XCTAssertEqual(text(of: document), "ab")
        XCTAssertFalse(viewport.hasMarkedText())
        XCTAssertEqual(viewport.caretByteOffset, 1)
    }

    func testUnmarkTextAcceptsTheCompositionAsItStands() {
        let (viewport, document) = makeViewport("ab", caret: 1)

        mark(viewport, "ni")
        viewport.unmarkText()

        XCTAssertEqual(text(of: document), "anib")
        XCTAssertFalse(viewport.hasMarkedText())
    }

    // MARK: - Dead keys

    func testADeadKeyCombinesWithTheNextLetter() {
        let (viewport, document) = makeViewport("caf")

        mark(viewport, "´")
        XCTAssertEqual(text(of: document), "caf´")
        viewport.insertText("é", replacementRange: none)

        XCTAssertEqual(text(of: document), "café")
        XCTAssertEqual(viewport.caretByteOffset, document.length)
        XCTAssertFalse(viewport.hasMarkedText())
    }

    func testANorwegianDiaeresisCombines() {
        let (viewport, document) = makeViewport("")

        mark(viewport, "¨")
        viewport.insertText("ü", replacementRange: none)

        XCTAssertEqual(text(of: document), "ü")
    }

    func testADeadKeyBeforeALetterItCannotCombineWithInsertsBoth() {
        let (viewport, document) = makeViewport("")

        mark(viewport, "´")
        viewport.insertText("´x", replacementRange: none)

        XCTAssertEqual(text(of: document), "´x")
        XCTAssertEqual(viewport.caretByteOffset, document.length)
    }

    func testADeadKeyCommittedBeforeASeparateLetterInsertsBoth() {
        let (viewport, document) = makeViewport("")

        mark(viewport, "´")
        viewport.insertText("´", replacementRange: none)
        viewport.insertText("x", replacementRange: none)

        XCTAssertEqual(text(of: document), "´x")
    }

    func testAnArrowKeyCommitsTheDeadKeyThenMovesTheCaret() {
        let (viewport, document) = makeViewport("ab", caret: 1)

        mark(viewport, "´")
        viewport.insertText("´", replacementRange: none)
        viewport.doCommand(by: #selector(NSResponder.moveLeft(_:)))

        XCTAssertEqual(text(of: document), "a´b")
        XCTAssertEqual(viewport.caretByteOffset, 1)
    }

    func testShiftArrowAfterADeadKeyExtendsTheSelection() {
        let (viewport, _) = makeViewport("ab\ncd", caret: 1)

        mark(viewport, "´")
        viewport.insertText("´", replacementRange: none)
        viewport.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))

        XCTAssertEqual(viewport.selection?.anchorOffset, 3)
        XCTAssertEqual(viewport.selection?.activeOffset, "a´b\ncd".utf8.count)
    }

    func testAClickCommitsTheDeadKeyAndMovesTheCaret() {
        let (viewport, document) = makeViewport("abc\ndef", caret: 1)

        mark(viewport, "´")
        click(viewport, at: NSPoint(x: 590, y: viewport.lineHeight * 1.5))

        XCTAssertEqual(text(of: document), "a´bc\ndef")
        XCTAssertFalse(viewport.hasMarkedText())
        XCTAssertEqual(viewport.caretByteOffset, document.length)
    }

    private func click(_ viewport: ViewportView, at point: NSPoint) {
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                                      pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                                    pressure: 0)!
        viewport.mouseDown(with: down)
        viewport.mouseUp(with: up)
    }

    // MARK: - Character Viewer

    func testTheCharacterViewerInsertsMultiScalarCharactersWhole() {
        let (viewport, document) = makeViewport("a")

        for character in ["👍🏽", "🇳🇴", "👨‍👩‍👧"] {
            viewport.insertText(character, replacementRange: none)
        }

        XCTAssertEqual(text(of: document), "a👍🏽🇳🇴👨‍👩‍👧")
        XCTAssertEqual(viewport.caretByteOffset, document.length)
    }

    // MARK: - Where the composition lands

    func testMarkedTextReplacesTheSelection() {
        let (viewport, document) = makeViewport("hello world")
        viewport.selection = TextSelection(anchorOffset: 6, activeOffset: 11)

        mark(viewport, "w")
        XCTAssertEqual(text(of: document), "hello w")
        viewport.insertText("ワ", replacementRange: none)

        XCTAssertEqual(text(of: document), "hello ワ")
    }

    func testComposingAtTheEndOfTheFile() {
        let (viewport, document) = makeViewport("abc")

        typeRomajiForKanji(into: viewport)
        viewport.insertText("漢字", replacementRange: none)

        XCTAssertEqual(text(of: document), "abc漢字")
        XCTAssertEqual(viewport.caretByteOffset, document.length)
    }

    func testComposingAtARowWrapBoundary() {
        let line = String(repeating: "abcdefghij", count: 200)
        let (viewport, document) = makeViewport(line + "\n")
        let secondRow = viewport.layout!.visualLines(forRows: 1..<2).first!
        let boundary = secondRow.byteRange.lowerBound
        XCTAssertGreaterThan(boundary, 0, "the line wraps")
        viewport.selection = TextSelection(anchorOffset: boundary, activeOffset: boundary)

        typeRomajiForKanji(into: viewport)
        viewport.insertText("漢字", replacementRange: none)

        let expected = String(line.prefix(boundary)) + "漢字" + String(line.dropFirst(boundary)) + "\n"
        XCTAssertEqual(text(of: document), expected)
        XCTAssertEqual(viewport.caretByteOffset, boundary + "漢字".utf8.count)
    }

    func testComposingInACRLFDocument() {
        let (viewport, document) = makeViewport("ab\r\ncd\r\n", caret: 2)

        typeRomajiForKanji(into: viewport)
        viewport.insertText("漢字", replacementRange: none)
        let secondLine = "ab漢字\r\n".utf8.count
        viewport.selection = TextSelection(anchorOffset: secondLine, activeOffset: secondLine)
        mark(viewport, "に")
        viewport.insertText("二", replacementRange: viewport.markedRange())

        XCTAssertEqual(text(of: document), "ab漢字\r\n二cd\r\n")
    }

    // MARK: - Undo

    func testUndoRemovesTheCommittedWordInOneStep() {
        let (viewport, document) = makeViewport("ab")

        typeRomajiForKanji(into: viewport)
        viewport.insertText("漢字", replacementRange: none)
        viewport.undo(nil)

        XCTAssertEqual(text(of: document), "ab")
        XCTAssertFalse(viewport.hasMarkedText())
        XCTAssertEqual(viewport.caretByteOffset, 2)
    }

    func testUndoInTheMiddleOfACompositionDiscardsIt() {
        let (viewport, document) = makeViewport("ab")

        mark(viewport, "かん")
        viewport.undo(nil)

        XCTAssertEqual(text(of: document), "ab")
        XCTAssertFalse(viewport.hasMarkedText())
    }

    // MARK: - UTF-16 ranges over multi-byte text

    func testAReplacementRangeInsideTheMarkedTextMapsToItsBytes() {
        let (viewport, document) = makeViewport("blåbær ")

        mark(viewport, "わたしは")
        let marked = viewport.markedRange()
        viewport.setMarkedText("私", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: marked.location, length: 3))

        XCTAssertEqual(text(of: document), "blåbær 私は")
        XCTAssertEqual(viewport.markedRange(), NSRange(location: marked.location, length: 1))
        viewport.insertText("私", replacementRange: viewport.markedRange())
        XCTAssertEqual(text(of: document), "blåbær 私は")
    }

    // MARK: - Windows-1252

    func testADeadKeyLandsAsOneByteInWindows1252() {
        let (viewport, document) = makeViewport("caf", encoding: .windows1252)

        mark(viewport, "´")
        XCTAssertEqual(bytes(of: document), [0x63, 0x61, 0x66, 0xB4])
        viewport.insertText("é", replacementRange: none)

        XCTAssertEqual(bytes(of: document), [0x63, 0x61, 0x66, 0xE9])
        XCTAssertEqual(viewport.caretByteOffset, 4)
    }

    func testKanaTheEncodingCannotHoldLeaveNoMarkedState() {
        let (viewport, document) = makeViewport("ab", encoding: .windows1252)
        var rejected: [String] = []
        viewport.onUnrepresentableText = { rejected.append($0) }

        typeRomajiForKanji(into: viewport)
        viewport.insertText("漢字", replacementRange: none)

        XCTAssertEqual(bytes(of: document), Array("ab".utf8))
        XCTAssertFalse(viewport.hasMarkedText())
        XCTAssertEqual(rejected, ["漢字"])
        XCTAssertEqual(viewport.caretByteOffset, 2)
    }

    func testCancellingUnrepresentableCompositionLeavesNoMarkedState() {
        let (viewport, document) = makeViewport("ab", encoding: .windows1252)

        mark(viewport, "に")
        viewport.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: none)

        XCTAssertEqual(bytes(of: document), Array("ab".utf8))
        XCTAssertFalse(viewport.hasMarkedText())
    }

    func testEmojiAreRefusedInWindows1252() {
        let (viewport, document) = makeViewport("a", encoding: .windows1252)

        viewport.insertText("👍🏽", replacementRange: none)

        XCTAssertEqual(bytes(of: document), Array("a".utf8))
        XCTAssertFalse(viewport.hasMarkedText())
    }

    // MARK: - CSV

    func testACompositionStaysInItsCell() {
        let csv = "name,age\nbob,2\n"
        let (viewport, document) = makeCSVViewport(csv, caret: "name,age\nbob".utf8.count)

        typeRomajiForKanji(into: viewport)
        viewport.insertText("漢字", replacementRange: none)

        XCTAssertEqual(text(of: document), "name,age\nbob漢字,2\n")
    }

    func testADeadKeyInAWindows1252Cell() {
        let csv = "name,åge\nbøb,2\n"
        let (viewport, document) = makeCSVViewport(csv, encoding: .windows1252, caret: 12)

        mark(viewport, "´")
        viewport.insertText("é", replacementRange: none)

        XCTAssertEqual(bytes(of: document), TextEncoding.windows1252.encode("name,åge\nbøbé,2\n"))
    }
}
