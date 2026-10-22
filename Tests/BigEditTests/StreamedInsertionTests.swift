import AppKit
import XCTest
@testable import BigEdit

/// A long paste is encoded a chunk at a time straight into the add buffer;
/// what lands there must be byte for byte what encoding it whole would give,
/// whatever falls on a chunk boundary.
final class StreamedInsertionTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeDocument(_ text: String, encoding: TextEncoding = .utf8,
                              newline: [UInt8] = [0x0A]) -> EditedDocument {
        let url = TestHelpers.writeTempFile(Data(encoding.encode(text)!))
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.encoding = encoding
        document.newlineBytes = newline
        document.isEditable = true
        return document
    }

    private func makeViewport(_ document: EditedDocument) -> ViewportView {
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.setTextEncoding(document.encoding)
        viewport.selection = TextSelection(anchorOffset: document.length, activeOffset: document.length)
        return viewport
    }

    /// The text encoded whole, as a short paste is.
    private func expectedBytes(_ text: String, encoding: TextEncoding, newline: String) -> [UInt8] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: newline)
        return encoding.encode(normalized)!
    }

    private func streamed(_ text: String, encoding: TextEncoding = .utf8,
                          newline: [UInt8] = [0x0A]) -> (bytes: [UInt8], containsNewline: Bool)? {
        let document = makeDocument("", encoding: encoding, newline: newline)
        let insertion = StreamedInsertion(encoding: encoding, newline: newline)
        return insertion.append(text, to: document).map { added in
            (document.addBuffer.bytes(in: added.range), added.containsNewline)
        }
    }

    /// Text one UTF-16 unit short of a chunk, followed by `boundary`.
    private func textWithBoundary(_ boundary: String) -> String {
        String(repeating: "a", count: StreamedInsertion.chunkLength - 1) + boundary + "z"
    }

    // MARK: - Line endings

    func testLineEndingsBecomeTheDocumentsAcrossChunks() {
        var normalizer = LineEndingNormalizer(newline: [0x0D, 0x0A])
        let first = normalizer.normalize(ArraySlice(Array("a\r".utf8)))
        let second = normalizer.normalize(ArraySlice(Array("\nb\rc\n".utf8)))
        let rest = normalizer.finish()
        XCTAssertEqual(first + second + rest, Array("a\r\nb\r\nc\r\n".utf8))
        XCTAssertTrue(normalizer.containsNewline)
    }

    func testALoneCarriageReturnAtTheEndIsALineBreak() {
        var normalizer = LineEndingNormalizer(newline: [0x0A])
        let bytes = normalizer.normalize(ArraySlice(Array("end\r".utf8))) + normalizer.finish()
        XCTAssertEqual(bytes, Array("end\n".utf8))
    }

    func testTextWithoutLineBreaksSaysSo() {
        var normalizer = LineEndingNormalizer(newline: [0x0A])
        _ = normalizer.normalize(ArraySlice(Array("plain".utf8)))
        XCTAssertFalse(normalizer.containsNewline)
    }

    // MARK: - Chunk boundaries

    func testACarriageReturnLineFeedSplitByAChunkIsOneLineBreak() {
        let text = textWithBoundary("\r\n")
        let result = streamed(text, newline: [0x0D, 0x0A])
        XCTAssertEqual(result?.bytes, expectedBytes(text, encoding: .utf8, newline: "\r\n"))
        XCTAssertEqual(result?.containsNewline, true)
    }

    func testACharacterSplitByAChunkIsWholeInUTF8() {
        let text = textWithBoundary("😀é")
        XCTAssertEqual(streamed(text)?.bytes, expectedBytes(text, encoding: .utf8, newline: "\n"))
    }

    func testWindows1252IsEncodedAcrossChunks() {
        let text = textWithBoundary("€\r\né")
        XCTAssertEqual(streamed(text, encoding: .windows1252)?.bytes,
                       expectedBytes(text, encoding: .windows1252, newline: "\n"))
    }

    func testACharacterTheEncodingCannotWriteStopsTheInsertion() {
        XCTAssertNil(streamed(textWithBoundary("😀"), encoding: .windows1252))
    }

    // MARK: - Through the viewport

    func testALongPasteLandsAsOneUndoableEdit() {
        let document = makeDocument("start\n")
        let viewport = makeViewport(document)
        let line = String(repeating: "x", count: 99) + "\r\n"
        let text = String(repeating: line, count: ViewportView.streamedInsertionLength / 100 + 1)
        viewport.insertTextAtSelection(text)

        let expected = Array("start\n".utf8) + expectedBytes(text, encoding: .utf8, newline: "\n")
        XCTAssertEqual(document.bytes(in: 0..<document.length), expected)
        XCTAssertEqual(viewport.selection?.activeOffset, expected.count)
        XCTAssertEqual(document.layout.documentLineCount, 1 + ViewportView.streamedInsertionLength / 100 + 1)

        _ = document.undoStack.undo(in: document)
        XCTAssertEqual(document.bytes(in: 0..<document.length), Array("start\n".utf8))
    }

    func testALongPasteTheEncodingCannotWriteChangesNothing() {
        let document = makeDocument("start\n", encoding: .windows1252)
        let viewport = makeViewport(document)
        var refused: String?
        viewport.onUnrepresentableText = { refused = $0 }
        let text = String(repeating: "x", count: ViewportView.streamedInsertionLength) + "😀"
        viewport.insertTextAtSelection(text)
        XCTAssertEqual(document.bytes(in: 0..<document.length), Array("start\n".utf8))
        XCTAssertEqual(refused, text)
    }
}
