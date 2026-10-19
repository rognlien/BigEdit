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

    func testTheSelectedRangeFollowsTheInputMethodInsideTheMarkedText() {
        let (viewport, _) = makeViewport("x")

        mark(viewport, "かんじ", selected: NSRange(location: 1, length: 0))

        XCTAssertEqual(viewport.selectedRange(),
                       NSRange(location: viewport.markedRange().location + 1, length: 0))
        XCTAssertEqual(viewport.caretByteOffset, 1 + "か".utf8.count)
    }

    func testConversionKeepsTheTextMarkedWithTheClauseSelected() {
        let (viewport, document) = makeViewport("x")

        typeRomajiForKanji(into: viewport)

        XCTAssertEqual(text(of: document), "x漢字")
        XCTAssertTrue(viewport.hasMarkedText())
        XCTAssertEqual(viewport.markedRange().length, 2)
        XCTAssertEqual(viewport.selectedRange(),
                       NSRange(location: viewport.markedRange().location, length: 2))
    }

    func testAcceptingAConversionLeavesTheCaretAfterIt() {
        let (viewport, document) = makeViewport("x\ny", caret: 1)
        typeRomajiForKanji(into: viewport)

        viewport.unmarkText()

        XCTAssertEqual(text(of: document), "x漢字\ny")
        XCTAssertEqual(viewport.selection?.range, 7..<7)
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

    // MARK: - Press-and-hold

    func testPressAndHoldReplacesTheLetterJustTyped() {
        let (viewport, document) = makeViewport("caf")

        viewport.insertText("e", replacementRange: none)
        let caret = viewport.selectedRange()
        XCTAssertNotEqual(caret.location, NSNotFound)
        viewport.insertText("é", replacementRange: NSRange(location: caret.location - 1, length: 1))

        XCTAssertEqual(text(of: document), "café")
        XCTAssertEqual(viewport.caretByteOffset, document.length)
    }

    func testPressAndHoldThatMarksTheLetterFirstReplacesIt() {
        let (viewport, document) = makeViewport("caf")

        viewport.insertText("e", replacementRange: none)
        let caret = viewport.selectedRange()
        viewport.setMarkedText("e", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: caret.location - 1, length: 1))
        XCTAssertEqual(text(of: document), "cafe")
        XCTAssertTrue(viewport.hasMarkedText())
        viewport.insertText("é", replacementRange: none)

        XCTAssertEqual(text(of: document), "café")
        XCTAssertFalse(viewport.hasMarkedText())
    }

    func testTheTextBeforeTheCaretCanBeRead() {
        let (viewport, _) = makeViewport("first line\ncafe")

        let caret = viewport.selectedRange()
        let substring = viewport.attributedSubstring(
            forProposedRange: NSRange(location: caret.location - 1, length: 1), actualRange: nil)

        XCTAssertEqual(substring?.string, "e")
    }

    func testTheSelectedRangeCoversTheSelection() {
        let (viewport, _) = makeViewport("first line\nblåbær")
        viewport.selection = TextSelection(anchorOffset: 11, activeOffset: 11 + "blå".utf8.count)

        let selected = viewport.selectedRange()

        XCTAssertEqual(selected.length, 3)
        XCTAssertEqual(viewport.attributedSubstring(forProposedRange: selected, actualRange: nil)?.string, "blå")
    }

    func testPressAndHoldFarIntoALongLine() {
        let line = String(repeating: "blåbær ", count: 2000)
        let (viewport, document) = makeViewport(line + "\nnext")
        let caret = line.utf8.count
        viewport.selection = TextSelection(anchorOffset: caret, activeOffset: caret)

        viewport.insertText("e", replacementRange: none)
        let selected = viewport.selectedRange()
        XCTAssertLessThan(selected.location, ViewportView.inputAnchorBlockLength)
        viewport.insertText("é", replacementRange: NSRange(location: selected.location - 1, length: 1))

        XCTAssertEqual(text(of: document), line + "é\nnext")
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

    func testTheCaretStepsOverAWholeEmoji() {
        let emoji = ["👍🏽", "🇳🇴", "👨‍👩‍👧"]
        let (viewport, document) = makeViewport("a" + emoji.joined() + "b", caret: 1)
        var boundaries = [1]
        for character in emoji {
            boundaries.append(boundaries.last! + character.utf8.count)
        }

        for boundary in boundaries.dropFirst() {
            viewport.moveCaretHorizontally(forward: true, extend: false)
            XCTAssertEqual(viewport.caretByteOffset, boundary)
        }
        for boundary in boundaries.dropLast().reversed() {
            viewport.moveCaretHorizontally(forward: false, extend: false)
            XCTAssertEqual(viewport.caretByteOffset, boundary)
        }
        XCTAssertEqual(document.length, boundaries.last! + 1)
    }

    func testTheCaretStepsOverALetterWithACombiningMark() {
        let (viewport, _) = makeViewport("ae\u{301}b", caret: 1)

        viewport.moveCaretHorizontally(forward: true, extend: false)
        XCTAssertEqual(viewport.caretByteOffset, 4)
        viewport.moveCaretHorizontally(forward: false, extend: false)
        XCTAssertEqual(viewport.caretByteOffset, 1)
    }

    func testTheCaretNeverStopsInsideACRLFPair() {
        let (viewport, _) = makeViewport("ab\r\ncd", caret: 2)

        viewport.moveCaretHorizontally(forward: true, extend: false)
        XCTAssertEqual(viewport.caretByteOffset, 4)
        viewport.moveCaretHorizontally(forward: false, extend: false)
        XCTAssertEqual(viewport.caretByteOffset, 2)
    }

    func testTheCaretStepsOverACharacterLongerThanTheLookAhead() {
        let marks = String(repeating: "\u{301}", count: EditedDocument.graphemeLookLength)
        let (viewport, document) = makeViewport("e" + marks + "b", caret: 0)

        viewport.moveCaretHorizontally(forward: true, extend: false)

        XCTAssertGreaterThan(viewport.caretByteOffset!, 1)
        XCTAssertLessThan(viewport.caretByteOffset!, document.length)
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

    // MARK: - Geometry

    private func placeInWindow(_ viewport: ViewportView) -> NSWindow {
        let window = NSWindow(contentRect: viewport.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = viewport
        return window
    }

    func testTheCandidateWindowGoesUnderTheClauseBeingConverted() {
        let (viewport, _) = makeViewport("x")
        let window = placeInWindow(viewport)
        mark(viewport, "わたしは")
        let marked = viewport.markedRange()

        var actual = NSRange(location: NSNotFound, length: 0)
        let whole = viewport.firstRect(forCharacterRange: marked, actualRange: &actual)
        let clause = viewport.firstRect(forCharacterRange: NSRange(location: marked.location + 3, length: 1),
                                        actualRange: nil)

        XCTAssertEqual(actual, marked)
        XCTAssertGreaterThan(whole.width, 1)
        XCTAssertEqual(clause.minY, whole.minY)
        XCTAssertGreaterThan(clause.minX, whole.minX)
        XCTAssertEqual(clause.maxX, whole.maxX, accuracy: 0.5)
        withExtendedLifetime(window) {}
    }

    func testARangeOverARowWrapReportsItsFirstRow() {
        let line = String(repeating: "abcdefghij", count: 200)
        let (viewport, _) = makeViewport(line + "\n", caret: 0)
        let window = placeInWindow(viewport)
        let boundary = viewport.layout!.visualLines(forRows: 1..<2).first!.byteRange.lowerBound

        var actual = NSRange(location: NSNotFound, length: 0)
        _ = viewport.firstRect(forCharacterRange: NSRange(location: boundary - 2, length: 4), actualRange: &actual)

        XCTAssertEqual(actual, NSRange(location: boundary - 2, length: 2))
        withExtendedLifetime(window) {}
    }

    func testTheCharacterUnderAPointIsFound() {
        let (viewport, _) = makeViewport("blåbær ")
        let window = placeInWindow(viewport)
        mark(viewport, "わたしは")
        let marked = viewport.markedRange()
        let third = viewport.firstRect(forCharacterRange: NSRange(location: marked.location + 2, length: 1),
                                       actualRange: nil)

        let index = viewport.characterIndex(for: NSPoint(x: third.minX + 2, y: third.midY))

        XCTAssertEqual(index, marked.location + 2)
        withExtendedLifetime(window) {}
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

    func testRangesCountUTF16UnitsOverMultiByteText() {
        let prefix = "blåbær 👍 "
        let (viewport, document) = makeViewport(prefix)

        mark(viewport, "かな")
        let marked = viewport.markedRange()
        XCTAssertEqual(viewport.attributedSubstring(forProposedRange: marked, actualRange: nil)?.string, "かな")
        let emoji = NSRange(location: marked.location - 3, length: 2)
        XCTAssertEqual(viewport.attributedSubstring(forProposedRange: emoji, actualRange: nil)?.string, "👍")
        viewport.insertText("仮名", replacementRange: marked)
        viewport.insertText("e", replacementRange: none)
        let caret = viewport.selectedRange()
        viewport.insertText("é", replacementRange: NSRange(location: caret.location - 1, length: 1))

        XCTAssertEqual(text(of: document), prefix + "仮名é")
        XCTAssertEqual(bytes(of: document), Array((prefix + "仮名é").utf8))
    }

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

    func testPressAndHoldInWindows1252() {
        let (viewport, document) = makeViewport("blåbær caf", encoding: .windows1252)

        viewport.insertText("e", replacementRange: none)
        let caret = viewport.selectedRange()
        viewport.insertText("é", replacementRange: NSRange(location: caret.location - 1, length: 1))

        XCTAssertEqual(bytes(of: document), TextEncoding.windows1252.encode("blåbær café"))
        XCTAssertEqual(document.length, 11)
    }

    func testPressAndHoldForALetterWindows1252LacksKeepsTheTypedOne() {
        let (viewport, document) = makeViewport("caf", encoding: .windows1252)

        viewport.insertText("e", replacementRange: none)
        let caret = viewport.selectedRange()
        viewport.insertText("ē", replacementRange: NSRange(location: caret.location - 1, length: 1))

        XCTAssertEqual(bytes(of: document), Array("cafe".utf8))
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

    func testCommittingACompositionWithADelimiterQuotesTheCell() {
        let csv = "name,age\nbob,2\n"
        let (viewport, document) = makeCSVViewport(csv, caret: "name,age\nbob".utf8.count)

        mark(viewport, "x,y")
        viewport.insertText("x,y", replacementRange: none)

        XCTAssertEqual(text(of: document), "name,age\n\"bobx,y\",2\n")
        XCTAssertFalse(viewport.hasMarkedText())
    }

    func testAnUncommittedCompositionWithADelimiterQuotesTheCell() {
        let csv = "name,age\nbob,2\n"
        let (viewport, document) = makeCSVViewport(csv, caret: "name,age\nbob".utf8.count)

        mark(viewport, "x,y")
        viewport.unmarkText()

        XCTAssertEqual(text(of: document), "name,age\n\"bobx,y\",2\n")
    }

    func testAGrowingCompositionStaysInsideTheQuotes() {
        let csv = "name,age\nbob,2\n"
        let (viewport, document) = makeCSVViewport(csv, caret: "name,age\nbob".utf8.count)

        mark(viewport, "x,")
        mark(viewport, "x,\"y")
        XCTAssertEqual(text(of: document), "name,age\n\"bobx,\"\"y\",2\n")
        viewport.insertText("x,\"y", replacementRange: none)

        XCTAssertEqual(text(of: document), "name,age\n\"bobx,\"\"y\",2\n")
        XCTAssertEqual(viewport.caretByteOffset, "name,age\n\"bobx,\"\"y".utf8.count)
    }

    func testADeadKeyInAWindows1252Cell() {
        let csv = "name,åge\nbøb,2\n"
        let (viewport, document) = makeCSVViewport(csv, encoding: .windows1252, caret: 12)

        mark(viewport, "´")
        viewport.insertText("é", replacementRange: none)

        XCTAssertEqual(bytes(of: document), TextEncoding.windows1252.encode("name,åge\nbøbé,2\n"))
    }
}
