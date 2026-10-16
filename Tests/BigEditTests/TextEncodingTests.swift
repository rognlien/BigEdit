import AppKit
import XCTest
@testable import BigEdit

/// A Windows-1252 file must read, copy, search and count correctly — with
/// every byte↔character mapping exact — and take edits in its own encoding.
final class TextEncodingTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    /// "blåbærgrød €" in Windows-1252, where each non-ASCII letter is one byte.
    /// Built step by step: a long chain of `+` between literals is something
    /// the type checker gives up on.
    private let sample: [UInt8] = {
        var bytes: [UInt8] = Array("bl".utf8)
        bytes.append(0xE5)                          // å
        bytes.append(contentsOf: Array("b".utf8))
        bytes.append(0xE6)                          // æ
        bytes.append(contentsOf: Array("rgr".utf8))
        bytes.append(0xF8)                          // ø
        bytes.append(contentsOf: Array("d ".utf8))
        bytes.append(0x80)                          // €
        bytes.append(0x0A)
        return bytes
    }()
    private let sampleText = "blåbærgrød €\n"

    private func mapped(_ bytes: [UInt8]) -> MappedFile {
        let url = TestHelpers.writeTempFile(Data(bytes))
        temporaryFiles.append(url)
        return MappedFile(path: url.path)!
    }

    // MARK: - The encoding itself

    func testDecodesWindows1252() {
        XCTAssertEqual(TextEncoding.windows1252.decode(sample), sampleText)
    }

    func testEncodesBackToTheSameBytes() {
        XCTAssertEqual(TextEncoding.windows1252.encode(sampleText), sample)
    }

    func testACharacterOutsideTheEncodingCannotBeEncoded() {
        XCTAssertNil(TextEncoding.windows1252.encode("🙂"))
        XCTAssertEqual(TextEncoding.utf8.encode("🙂"), Array("🙂".utf8))
    }

    func testEveryByteDecodesEvenTheUndefinedOnes() {
        // 0x81 has no meaning in Windows-1252; it must not make decoding fail.
        let text = TextEncoding.windows1252.decode([0x41, 0x81, 0x42])
        XCTAssertEqual(text.count, 3)
        XCTAssertTrue(text.hasPrefix("A") && text.hasSuffix("B"))
    }

    func testFindsTheFirstCharacterTheEncodingCannotHold() {
        XCTAssertEqual(TextEncoding.latin1.firstUnrepresentableCharacter(in: "aé€🙂"), "€")
        XCTAssertEqual(TextEncoding.windows1252.firstUnrepresentableCharacter(in: "aé€🙂"), "🙂")
        XCTAssertNil(TextEncoding.windows1252.firstUnrepresentableCharacter(in: "aé€"))
    }

    func testByteLengthIsOneInASingleByteEncoding() {
        let scalar: Unicode.Scalar = "ø"
        XCTAssertEqual(TextEncoding.windows1252.byteLength(of: scalar), 1)
        XCTAssertEqual(TextEncoding.utf8.byteLength(of: scalar), 2)
    }

    // MARK: - Detection

    func testAWindows1252FileIsDetected() {
        let format = FileFormat(scanning: mapped(sample))
        XCTAssertEqual(format.textEncoding, .windows1252)
        XCTAssertEqual(format.encoding, "Windows-1252")
        XCTAssertFalse(format.isUTF8)
    }

    func testUTF8AndBinaryDetectionAreUnchanged() {
        XCTAssertEqual(FileFormat(scanning: mapped(Array(sampleText.utf8))).textEncoding, .utf8)
        XCTAssertNil(FileFormat(scanning: mapped([0x41, 0x00, 0x42])).textEncoding)
    }

    // MARK: - Search

    func testLiteralSearchEncodesTheNeedle() {
        let file = mapped(sample + sample)
        let scan = SearchScan(query: "ø", encoding: .windows1252)!
        scan.runSynchronously(in: file)
        XCTAssertEqual(scan.matchOffsets(beginningIn: 0..<Int.max), [8, 8 + sample.count])
        XCTAssertEqual(scan.queryByteLength, 1, "one byte, as it is in the file")
    }

    func testANeedleTheEncodingCannotHoldIsNotSearchable() {
        XCTAssertNil(SearchScan(query: "🙂", encoding: .windows1252))
    }

    func testRegularExpressionRangesAreByteExact() {
        let file = mapped(sample)
        let scan = SearchScan(regularExpression: "[åæø]+", encoding: .windows1252)!
        scan.runSynchronously(in: file)
        let ranges = scan.matches(beginningIn: 0..<Int.max)
        XCTAssertEqual(ranges, [2..<3, 4..<5, 8..<9], "each letter is one byte")
    }

    // MARK: - Counting, copying, clicking

    func testCharacterCountIsByteCountInASingleByteEncoding() {
        let file = mapped(sample)
        let scan = StatisticsScan(encoding: .windows1252)
        scan.runSynchronously(in: file)
        XCTAssertEqual(scan.characterCount, sample.count)
        XCTAssertEqual(scan.wordCount, 2)
    }

    func testCopyDecodesInTheDocumentsEncoding() {
        XCTAssertEqual(ViewportView.pasteboardText(from: sample, encoding: .windows1252), sampleText)
    }

    func testClickMappingUsesOneByteperCharacter() {
        // In "aøb", the character after ø is at UTF-16 index 2: byte 2 in
        // Latin-1, byte 3 in UTF-8.
        XCTAssertEqual(ViewportView.byteOffset(forUTF16Index: 2, in: "aøb", encoding: .latin1), 2)
        XCTAssertEqual(ViewportView.byteOffset(forUTF16Index: 2, in: "aøb", encoding: .utf8), 3)
    }

    // MARK: - Caret stepping

    private func document(_ bytes: [UInt8], encoding: TextEncoding) -> EditedDocument {
        let file = mapped(bytes)
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.encoding = encoding
        return document
    }

    func testTheCaretStepsOneByteAtATimeInASingleByteEncoding() {
        // The € at byte 11 is 0x80, which UTF-8 would read as a continuation.
        let document = document(sample, encoding: .windows1252)
        XCTAssertEqual(document.nextCharacterOffset(after: 10), 11)
        XCTAssertEqual(document.nextCharacterOffset(after: 11), 12)
        XCTAssertEqual(document.previousCharacterOffset(before: 12), 11)
    }

    func testTheCaretStillStepsOverWholeUTF8Sequences() {
        let document = document(Array("a€b".utf8), encoding: .utf8)
        XCTAssertEqual(document.nextCharacterOffset(after: 0), 1)
        XCTAssertEqual(document.nextCharacterOffset(after: 1), 4)
        XCTAssertEqual(document.previousCharacterOffset(before: 4), 1)
    }

    // MARK: - Editing

    private func viewport(_ bytes: [UInt8], encoding: TextEncoding,
                          caret: Int) -> (ViewportView, EditedDocument) {
        let document = document(bytes, encoding: encoding)
        document.isEditable = true
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.setTextEncoding(encoding)
        viewport.selection = TextSelection(anchorOffset: caret, activeOffset: caret)
        return (viewport, document)
    }

    private func contents(of document: EditedDocument) -> [UInt8] {
        document.bytes(in: 0..<document.length)
    }

    func testTypingAnAccentedLetterInLatin1WritesItsSingleByte() {
        let (viewport, document) = viewport(Array("caf".utf8), encoding: .latin1, caret: 3)

        viewport.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(contents(of: document), [0x63, 0x61, 0x66, 0xE9])
        XCTAssertEqual(viewport.caretByteOffset, 4)
    }

    func testTypingTheEuroSignInWindows1252WritesByte80() {
        let (viewport, document) = viewport(Array("5 ".utf8), encoding: .windows1252, caret: 2)

        viewport.insertText("€", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(contents(of: document), [0x35, 0x20, 0x80])
    }

    func testTextTheEncodingCannotHoldIsRejected() {
        let (viewport, document) = viewport(Array("ab".utf8), encoding: .latin1, caret: 1)
        var rejected: [String] = []
        viewport.onUnrepresentableText = { rejected.append($0) }

        viewport.insertText("€", replacementRange: NSRange(location: NSNotFound, length: 0))
        viewport.insertText("x🙂", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(contents(of: document), Array("ab".utf8))
        XCTAssertEqual(rejected, ["€", "x🙂"])
        XCTAssertFalse(document.hasEdits)
    }

    func testRejectedTextLeavesTheSelectionInPlace() {
        let (viewport, document) = viewport(Array("abc".utf8), encoding: .latin1, caret: 0)
        viewport.selection = TextSelection(anchorOffset: 0, activeOffset: 2)

        viewport.insertText("🙂", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(contents(of: document), Array("abc".utf8))
        XCTAssertEqual(viewport.selectionByteRange, 0..<2)
    }

    func testADeadKeyTheEncodingCannotShowStillComposes() {
        // Option-I's circumflex, U+02C6, has no Latin-1 byte; ê does.
        let (viewport, document) = viewport(Array("t".utf8), encoding: .latin1, caret: 1)
        let none = NSRange(location: NSNotFound, length: 0)

        viewport.setMarkedText("ˆ", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        XCTAssertTrue(viewport.hasMarkedText())
        viewport.insertText("ê", replacementRange: none)

        XCTAssertEqual(contents(of: document), [0x74, 0xEA])
        XCTAssertFalse(viewport.hasMarkedText())
    }

    func testAComposedCharacterTheEncodingCannotHoldIsDropped() {
        let (viewport, document) = viewport(Array("t".utf8), encoding: .latin1, caret: 1)
        let none = NSRange(location: NSNotFound, length: 0)

        viewport.setMarkedText("¨", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        XCTAssertEqual(contents(of: document), [0x74, 0xA8], "the diaeresis is a Latin-1 byte")
        viewport.insertText("ẅ", replacementRange: none)

        XCTAssertEqual(contents(of: document), [0x74])
    }

    func testDeletingBackwardRemovesOneSingleByteCharacter() {
        let (viewport, document) = viewport(sample, encoding: .windows1252, caret: 12)

        viewport.deleteBackward(nil)

        XCTAssertEqual(contents(of: document), Array(sample[0..<11]) + [0x0A])
    }

    func testTheLineOperationsStayUTF8Only() {
        let (viewport, _) = viewport(sample, encoding: .windows1252, caret: 0)
        XCTAssertTrue(viewport.isEditingAllowed)
        XCTAssertFalse(viewport.isWholeDocumentReplacementAllowed,
                       "the line operations decode lines as UTF-8")
    }

    // MARK: - Converting to UTF-8

    func testTranscodesToUTF8() {
        XCTAssertEqual(TextEncoding.windows1252.transcodedToUTF8(sample), Array(sampleText.utf8))
        XCTAssertEqual(TextEncoding.latin1.transcodedToUTF8([0x80, 0xE9]), [0xC2, 0x80, 0xC3, 0xA9])
    }

    func testAnUndefinedByteDoesNotChangeHowItsNeighboursConvert() {
        // 0x81 means nothing in Windows-1252; the € beside it is still €.
        let converted = TextEncoding.windows1252.transcodedToUTF8([0x80, 0x81])
        XCTAssertEqual(converted, Array("€".utf8) + [0xC2, 0x81])
    }

    func testConvertingAnEditedDocumentStreamsItAsUTF8() throws {
        let (viewport, document) = viewport(sample, encoding: .windows1252, caret: 0)
        viewport.insertText("Ærø € ", replacementRange: NSRange(location: NSNotFound, length: 0))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditTest-\(UUID().uuidString)")
        temporaryFiles.append(destination)

        let result = FileWriter.saveSynchronously(document: document, convertingFrom: .windows1252,
                                                  to: destination, windowSize: 3)

        XCTAssertNoThrow(try result.get())
        let converted = try Data(contentsOf: destination)
        XCTAssertEqual(String(data: converted, encoding: .utf8), "Ærø € " + sampleText)
    }

    private func documentView(_ bytes: [UInt8]) -> DocumentView {
        let file = mapped(bytes)
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.load(file: file, index: index)
        view.setFileFormat(FileFormat(scanning: file))
        return view
    }

    func testASingleByteDocumentIsEditableAndCanBeConverted() {
        let view = documentView(sample)
        XCTAssertEqual(view.editedDocument?.isEditable, true)
        XCTAssertEqual(view.editedDocument?.encoding, .windows1252)
        XCTAssertTrue(view.canConvertToUTF8)
    }

    func testAUTF8DocumentHasNothingToConvert() {
        let view = documentView(Array(sampleText.utf8))
        XCTAssertEqual(view.editedDocument?.isEditable, true)
        XCTAssertFalse(view.canConvertToUTF8)
    }

    func testAnEditedSingleByteDocumentSavesItsBytesUnchanged() throws {
        let (viewport, document) = viewport(sample, encoding: .windows1252, caret: 0)
        viewport.insertText("Ærø € ", replacementRange: NSRange(location: NSNotFound, length: 0))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditTest-\(UUID().uuidString)")
        temporaryFiles.append(destination)

        let result = FileWriter.saveSynchronously(document: document, to: destination)

        XCTAssertNoThrow(try result.get())
        let saved = Array(try Data(contentsOf: destination))
        XCTAssertEqual(saved, [0xC6, 0x72, 0xF8, 0x20, 0x80, 0x20] + sample)
        XCTAssertEqual(TextEncoding.windows1252.decode(saved), "Ærø € " + sampleText)
    }
}
