import XCTest
@testable import BigEdit

/// Undo records are piece splices; these tests drive edits through
/// `EditedDocument.replace` exactly as the viewport does, and check
/// coalescing rules plus full undo/redo walks against snapshots.
final class UndoStackTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeDocument(_ content: String) -> EditedDocument {
        let url = TestHelpers.writeTempFile(content)
        temporaryFiles.append(url)
        guard let file = MappedFile(path: url.path) else {
            fatalError("could not map temp file")
        }
        let index = LineIndex()
        index.buildSynchronously(from: file)
        return EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
    }

    private func text(of document: EditedDocument) -> String {
        String(decoding: document.bytes(in: 0..<document.length), as: UTF8.self)
    }

    /// Types `text` one character at a time starting at `offset`, as
    /// keystrokes would.
    private func type(_ text: String, at offset: Int, in document: EditedDocument) {
        var position = offset
        for character in text {
            let bytes = Array(String(character).utf8)
            document.replace(position..<position, with: bytes)
            position += bytes.count
        }
    }

    func testTypingRunCoalescesIntoOneOperation() {
        let document = makeDocument("hello world")
        type("big ", at: 6, in: document)

        XCTAssertEqual(text(of: document), "hello big world")
        XCTAssertEqual(document.undoStack.depth, 1)

        _ = document.undoStack.undo(in: document)
        XCTAssertEqual(text(of: document), "hello world")
    }

    func testNewlineBreaksTheTypingRun() {
        let document = makeDocument("ab")
        type("x", at: 1, in: document)
        document.replace(2..<2, with: [0x0A])
        type("y", at: 3, in: document)

        XCTAssertEqual(document.undoStack.depth, 3)
    }

    func testBackspaceRunCoalesces() {
        let document = makeDocument("hello world")
        // Backspace over "hello" from the caret after it, one byte at a time.
        for position in stride(from: 5, through: 1, by: -1) {
            document.replace((position - 1)..<position, with: [])
        }

        XCTAssertEqual(text(of: document), " world")
        XCTAssertEqual(document.undoStack.depth, 1)

        _ = document.undoStack.undo(in: document)
        XCTAssertEqual(text(of: document), "hello world")
    }

    func testBackspacingIntoATypingRunStaysOneOperation() {
        let document = makeDocument("ab")
        type("xyz", at: 1, in: document)
        document.replace(3..<4, with: [])   // backspace the "z"

        XCTAssertEqual(text(of: document), "axyb")
        XCTAssertEqual(document.undoStack.depth, 1)

        _ = document.undoStack.undo(in: document)
        XCTAssertEqual(text(of: document), "ab")
    }

    func testCaretMoveBreaksCoalescing() {
        let document = makeDocument("ab")
        type("x", at: 1, in: document)
        document.undoStack.breakCoalescing()
        type("y", at: 2, in: document)

        XCTAssertEqual(document.undoStack.depth, 2)

        _ = document.undoStack.undo(in: document)
        XCTAssertEqual(text(of: document), "axb")
        _ = document.undoStack.undo(in: document)
        XCTAssertEqual(text(of: document), "ab")
    }

    func testUndoRestoresSelectionAndRedoReapplies() {
        let document = makeDocument("hello world")
        let before = TextSelection(anchorOffset: 6, activeOffset: 11)
        document.replace(6..<11, with: Array("there".utf8), selectionBefore: before)

        let afterUndo = document.undoStack.undo(in: document)
        XCTAssertEqual(text(of: document), "hello world")
        XCTAssertEqual(afterUndo?.anchorOffset, 6)
        XCTAssertEqual(afterUndo?.activeOffset, 11)

        let afterRedo = document.undoStack.redo(in: document)
        XCTAssertEqual(text(of: document), "hello there")
        XCTAssertEqual(afterRedo?.activeOffset, 11)
    }

    func testNewEditClearsTheRedoStack() {
        let document = makeDocument("ab")
        type("x", at: 1, in: document)
        _ = document.undoStack.undo(in: document)
        XCTAssertTrue(document.undoStack.canRedo)

        type("y", at: 1, in: document)
        XCTAssertFalse(document.undoStack.canRedo)
    }

    /// A Replace-All-style batch applied back-to-front inside a group must
    /// undo and redo as one step.
    func testGroupedEditsUndoAsOneStep() {
        let document = makeDocument("foo bar foo baz foo\n")
        let matches = [0, 8, 16]   // "foo" offsets

        document.undoStack.beginGrouping()
        for offset in matches.reversed() {
            document.replace(offset..<(offset + 3), with: Array("QUUX".utf8))
        }
        document.undoStack.endGrouping()

        XCTAssertEqual(text(of: document), "QUUX bar QUUX baz QUUX\n")
        XCTAssertEqual(document.undoStack.depth, 1)

        _ = document.undoStack.undo(in: document)
        XCTAssertEqual(text(of: document), "foo bar foo baz foo\n")

        _ = document.undoStack.redo(in: document)
        XCTAssertEqual(text(of: document), "QUUX bar QUUX baz QUUX\n")

        _ = document.undoStack.undo(in: document)
        XCTAssertEqual(text(of: document), "foo bar foo baz foo\n")
    }

    /// A materialisation-sized batch (2,000 scattered replacements) must
    /// stay interactive and keep the layout consistent.
    func testLargeGroupedBatchIsFastAndConsistent() {
        let occurrences = 2_000
        let content = String(repeating: "match and some padding here\n", count: occurrences)
        let document = makeDocument(content)
        let lineLength = "match and some padding here\n".utf8.count

        let started = Date()
        document.undoStack.beginGrouping()
        for line in stride(from: occurrences - 1, through: 0, by: -1) {
            let offset = line * lineLength
            document.replace(offset..<(offset + 5), with: Array("hit".utf8))
        }
        document.undoStack.endGrouping()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 10, "materialisation must stay interactive")
        XCTAssertEqual(document.undoStack.depth, 1)
        XCTAssertEqual(document.length, content.utf8.count - occurrences * 2)
        XCTAssertEqual(document.layout.documentLineCount, occurrences)
        XCTAssertTrue(text(of: document).hasPrefix("hit and some padding here\n"))

        _ = document.undoStack.undo(in: document)
        XCTAssertEqual(text(of: document), content)
    }

    /// Random edits with random coalescing breaks; a full undo walk must
    /// retrace every snapshot in reverse, and a full redo walk must retrace
    /// them forward again — with the layout agreeing at every step.
    func testFuzzUndoRedoWalksRetraceHistory() {
        for seed: UInt64 in [51, 5151] {
            var generator = SeededGenerator(seed: seed)
            var model = (0..<400).map { _ in
                Int.random(in: 0..<12, using: &generator) == 0
                    ? UInt8(0x0A)
                    : UInt8.random(in: 32...126, using: &generator)
            }
            let document = makeDocument(String(decoding: model, as: UTF8.self))

            // One snapshot per undo operation (edits may coalesce).
            var snapshots: [[UInt8]] = []
            for _ in 0..<60 {
                let lower = Int.random(in: 0...model.count, using: &generator)
                let upper = Int.random(in: lower...min(model.count, lower + 30), using: &generator)
                let insert = (0..<Int.random(in: 0...15, using: &generator)).map { _ in
                    Int.random(in: 0..<10, using: &generator) == 0
                        ? UInt8(0x0A)
                        : UInt8.random(in: 32...126, using: &generator)
                }
                let depthBefore = document.undoStack.depth
                document.replace(lower..<upper, with: insert)
                if document.undoStack.depth > depthBefore {
                    snapshots.append(model)
                }
                model.replaceSubrange(lower..<upper, with: insert)
                if Bool.random(using: &generator) {
                    document.undoStack.breakCoalescing()
                }
            }

            var forward: [[UInt8]] = []   // states re-entered by redo
            forward.append(model)
            while document.undoStack.canUndo {
                _ = document.undoStack.undo(in: document)
                let expected = snapshots.removeLast()
                XCTAssertEqual(document.bytes(in: 0..<document.length), expected, "seed \(seed)")
                XCTAssertEqual(document.layout.length, expected.count, "seed \(seed)")
                forward.append(expected)
            }
            forward.removeLast()   // the fully-undone state is current

            while document.undoStack.canRedo {
                _ = document.undoStack.redo(in: document)
                let expected = forward.removeLast()
                XCTAssertEqual(document.bytes(in: 0..<document.length), expected, "seed \(seed)")
                XCTAssertEqual(document.layout.length, expected.count, "seed \(seed)")
            }
            XCTAssertEqual(document.bytes(in: 0..<document.length), model, "seed \(seed)")
        }
    }
}
