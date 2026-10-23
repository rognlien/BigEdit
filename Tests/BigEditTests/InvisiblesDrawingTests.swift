import AppKit
import XCTest
@testable import BigEdit

/// Invisible characters are marked where the row's own layout puts them, and
/// showing the marks changes nothing else: not the caret, a selection, a
/// click or what is copied.
final class InvisiblesDrawingTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeViewport(_ text: String, encoding: TextEncoding = .utf8) -> ViewportView {
        let url = TestHelpers.writeTempFile(Data(encoding.encode(text)!))
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.isEditable = true
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.setTextEncoding(encoding)
        return viewport
    }

    private func row(_ number: Int, of viewport: ViewportView) -> LineIndex.VisualLine {
        viewport.layout!.visualLines(forRows: number..<(number + 1)).first!
    }

    private func placements(_ number: Int, of viewport: ViewportView) -> [ViewportView.InvisibleMarkPlacement] {
        let line = row(number, of: viewport)
        let drawn = viewport.attributedRow(viewport.decodeChunk(line))
        return viewport.invisibleMarkPlacements(for: line, drawnAs: drawn)
    }

    private func kinds(_ number: Int, of viewport: ViewportView) -> [InvisibleCharacters.Kind] {
        placements(number, of: viewport).map(\.mark.kind)
    }

    func testATabIsPlacedOverItsSpan() {
        let viewport = makeViewport("ab\tc\n")
        let line = row(0, of: viewport)

        let tab = placements(0, of: viewport).first { $0.mark.kind == .tab }!

        XCTAssertEqual(tab.minX, viewport.xOffset(inRow: line, forByte: 2), accuracy: 0.01)
        XCTAssertEqual(tab.maxX, viewport.xOffset(inRow: line, forByte: 3), accuracy: 0.01)
        XCTAssertEqual(tab.maxX, viewport.characterWidth * 4, accuracy: 0.01)
    }

    func testCRLFAndLFLineEndingsAreToldApart() {
        let viewport = makeViewport("a\nb\r\nc\n")

        XCTAssertEqual(viewport.lineTerminator(of: row(0, of: viewport)), .lineFeed)
        XCTAssertEqual(viewport.lineTerminator(of: row(1, of: viewport)), .carriageReturnLineFeed)
        XCTAssertEqual(kinds(1, of: viewport), [.carriageReturnLineFeed])
    }

    func testALineEndingIsMarkedWhereTheCaretEndsTheLine() {
        let viewport = makeViewport("ab\r\ncd\n")
        let line = row(0, of: viewport)

        let ending = placements(0, of: viewport).last!

        XCTAssertEqual(ending.minX, viewport.xOffset(inRow: line, forByte: 2), accuracy: 0.01)
        XCTAssertEqual(ending.minX, viewport.characterWidth * 2, accuracy: 0.01)
    }

    func testTheFinalLineWithoutANewlineHasNoLineEndingMark() {
        let viewport = makeViewport("a\nb")

        XCTAssertEqual(kinds(0, of: viewport), [.lineFeed])
        XCTAssertEqual(kinds(1, of: viewport), [])
    }

    func testTheEmptyRowAfterAFinalNewlineHasNoMark() {
        let viewport = makeViewport("a\n")

        XCTAssertEqual(viewport.layout!.visualRowCount, 2)
        XCTAssertEqual(kinds(1, of: viewport), [])
    }

    func testAnEmptyLineIsMarked() {
        let viewport = makeViewport("a\n\nb\n")

        XCTAssertEqual(kinds(1, of: viewport), [.lineFeed])
    }

    func testANoBreakSpaceIsPlacedAtItsCharacter() {
        let viewport = makeViewport("漢\u{00A0}x\n")
        let line = row(0, of: viewport)

        let space = placements(0, of: viewport).first!

        XCTAssertEqual(space.mark.kind, .unusualSpace)
        XCTAssertEqual(space.minX, viewport.xOffset(inRow: line, forByte: 3), accuracy: 0.01)
        XCTAssertEqual(space.maxX, viewport.xOffset(inRow: line, forByte: 5), accuracy: 0.01)
    }

    func testASpaceAfterACombiningMarkIsPlacedAtTheCaretsPosition() {
        let viewport = makeViewport("e\u{0301} x\n")
        let line = row(0, of: viewport)

        let space = placements(0, of: viewport).first!

        XCTAssertEqual(space.mark.kind, .space)
        XCTAssertEqual(space.minX, viewport.xOffset(inRow: line, forByte: 3), accuracy: 0.01)
    }

    func testAZeroWidthSpaceTakesNoRoom() {
        let viewport = makeViewport("a\u{200B}b\n")
        let line = row(0, of: viewport)

        let mark = placements(0, of: viewport).first!

        XCTAssertEqual(mark.mark.kind, .zeroWidth)
        XCTAssertEqual(mark.minX, mark.maxX, accuracy: 0.01)
        XCTAssertEqual(mark.minX, viewport.xOffset(inRow: line, forByte: 1), accuracy: 0.01)
        XCTAssertEqual(viewport.xOffset(inRow: line, forByte: 5), viewport.characterWidth * 2, accuracy: 0.01)
    }

    func testALoneCarriageReturnIsMarkedInsideTheLineAndAtTheEndOfTheFile() {
        let viewport = makeViewport("a\rb\nc\r")

        XCTAssertEqual(kinds(0, of: viewport), [.carriageReturn, .lineFeed])
        XCTAssertEqual(viewport.lineTerminator(of: row(1, of: viewport)), .carriageReturn)
        XCTAssertEqual(kinds(1, of: viewport), [.carriageReturn])
    }

    func testALeadingByteOrderMarkIsNotMarked() {
        let viewport = makeViewport("\u{FEFF}a\n\u{FEFF}b\n")

        XCTAssertEqual(kinds(0, of: viewport), [.lineFeed])
        XCTAssertEqual(kinds(1, of: viewport), [.zeroWidth, .lineFeed])
    }

    func testALatin1NoBreakSpaceIsFound() {
        let viewport = makeViewport("caf\u{E9}\u{00A0}x\r\n", encoding: .latin1)
        let line = row(0, of: viewport)

        let marks = placements(0, of: viewport)

        XCTAssertEqual(marks.map(\.mark.kind), [.unusualSpace, .carriageReturnLineFeed])
        XCTAssertEqual(marks[0].minX, viewport.xOffset(inRow: line, forByte: 4), accuracy: 0.01)
    }

    func testOnlyTheLastChunkOfALongLineEndsIt() {
        let viewport = makeViewport(String(repeating: "a", count: 3000) + "\nb\n")
        let lastChunk = viewport.layout!.visualRow(forDocumentLine: 1) - 1

        XCTAssertGreaterThan(lastChunk, 0)
        XCTAssertEqual(kinds(0, of: viewport), [])
        XCTAssertEqual(kinds(lastChunk, of: viewport), [.lineFeed])
    }

    func testShowingInvisiblesChangesNoGeometryOrCopiedText() {
        let text = "a b\t漢\u{00A0}e\u{0301}\u{200B}z\r\nnext line\n"
        let viewport = makeViewport(text)
        viewport.selection = TextSelection(anchorOffset: 1, activeOffset: 12)
        let before = geometry(of: viewport)

        viewport.showsInvisibles = true
        render(viewport)

        XCTAssertEqual(geometry(of: viewport), before)
    }

    func testAColumnSelectionCopiesTheSameWithInvisiblesShown() {
        let viewport = makeViewport("a b c\nd e f\n")
        viewport.selection = TextSelection(anchorOffset: 1, activeOffset: 1)
        viewport.extendColumnSelection(byRows: 1)
        viewport.widenColumnSelection(byCharacters: 3)
        let before = viewport.columnSelectionText(cap: 1024)

        viewport.showsInvisibles = true
        render(viewport)

        XCTAssertEqual(viewport.columnSelectionText(cap: 1024), before)
        XCTAssertEqual(before, " b \n e ")
    }

    func testTheCSVTableIsDrawnTheSameWithInvisiblesShown() {
        let viewport = makeViewport("name,city\nAda Lovelace,Lon\u{00A0}don\r\n")
        let dialect = CSVDialect()
        viewport.setCSVRendering(dialect: dialect,
                                 columnLayout: CSVColumnLayout.measure(file: viewport.file!, dialect: dialect,
                                                                       encoding: .utf8))
        let hidden = render(viewport)

        viewport.showsInvisibles = true

        XCTAssertEqual(render(viewport), hidden)
    }

    func testShowingInvisiblesDrawsMarks() {
        let viewport = makeViewport("a b\n")
        let hidden = render(viewport)

        viewport.showsInvisibles = true

        XCTAssertNotEqual(render(viewport), hidden)
    }

    private struct Geometry: Equatable {
        let caretXs: [CGFloat]
        let clickOffsets: [Int]
        let drawnText: [String]
        let copiedText: String
    }

    private func geometry(of viewport: ViewportView) -> Geometry {
        let lines = viewport.layout!.visualLines(forRows: 0..<viewport.layout!.visualRowCount)
        let caretXs = lines.flatMap { line in
            (line.byteRange.lowerBound...line.byteRange.upperBound).map {
                viewport.xOffset(inRow: line, forByte: $0)
            }
        }
        let clickOffsets = lines.flatMap { line in
            stride(from: 0, to: 120, by: 3).map { viewport.byteOffset(inRow: line, atX: CGFloat($0)) }
        }
        let drawnText = lines.map { viewport.attributedRow(viewport.decodeChunk($0)).string }
        let selected = viewport.document!.displayBytes(in: viewport.selection!.range)
        return Geometry(caretXs: caretXs, clickOffsets: clickOffsets, drawnText: drawnText,
                        copiedText: ViewportView.pasteboardText(from: selected, encoding: viewport.textEncoding))
    }

    @discardableResult
    private func render(_ viewport: ViewportView) -> Data {
        let representation = viewport.bitmapImageRepForCachingDisplay(in: viewport.bounds)!
        viewport.cacheDisplay(in: viewport.bounds, to: representation)
        return representation.tiffRepresentation!
    }
}
