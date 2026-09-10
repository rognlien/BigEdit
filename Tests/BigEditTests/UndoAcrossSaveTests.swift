import XCTest
@testable import BigEdit

/// Undo used to clear on save because the document re-mapped from disk and the
/// history's pieces pointed at a file that no longer existed at that path.
/// Now the previous mapping is retired and kept alive, and the history is
/// rewritten to point at it. These tests go through a real save — an atomic
/// rename over the same path — so the bytes an undo puts back genuinely exist
/// only in the old inode.
final class UndoAcrossSaveTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func open(_ url: URL) -> EditedDocument {
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        return EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
    }

    private func text(_ document: EditedDocument) -> String {
        String(decoding: document.bytes(in: 0..<document.length), as: UTF8.self)
    }

    /// Saves `document` over its own path and returns the document the app
    /// would build afterwards — over the new mapping, inheriting the history.
    private func saveAndReopen(_ document: EditedDocument, at url: URL) -> EditedDocument {
        let result = FileWriter.saveSynchronously(document: document, to: url)
        guard case .success = result else {
            XCTFail("save failed: \(result)")
            return document
        }
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        return EditedDocument(file: file, editModel: EditModel(), lineIndex: index,
                              inheritingHistoryFrom: document)
    }

    /// The inode at `url`, so a test can show the save really replaced it.
    private func inode(of url: URL) -> UInt64 {
        var info = stat()
        _ = stat(url.path, &info)
        return UInt64(info.st_ino)
    }

    private func newDocument(_ content: String) -> (EditedDocument, URL) {
        let url = TestHelpers.writeTempFile(content)
        temporaryFiles.append(url)
        return (open(url), url)
    }

    // MARK: - The core case

    func testUndoAfterSaveRestoresBytesThatOnlyExistInTheOldInode() {
        let (first, url) = newDocument("hello world\n")
        first.replace(6..<11, with: [])                       // delete "world"
        first.undoStack.breakCoalescing()                     // as a caret move would
        first.replace(6..<6, with: Array("there".utf8))       // type "there"
        XCTAssertEqual(text(first), "hello there\n")
        let inodeBefore = inode(of: url)

        let second = saveAndReopen(first, at: url)
        XCTAssertEqual(text(second), "hello there\n")
        XCTAssertNotEqual(inode(of: url), inodeBefore, "the save replaced the inode")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello there\n")
        XCTAssertTrue(second.undoStack.canUndo, "history survived the save")

        _ = second.undoStack.undo(in: second)
        XCTAssertEqual(text(second), "hello \n")
        _ = second.undoStack.undo(in: second)
        XCTAssertEqual(text(second), "hello world\n",
                       "\"world\" is not on disk any more; it came from the retired mapping")
        XCTAssertFalse(second.undoStack.canUndo)

        _ = second.undoStack.redo(in: second)
        _ = second.undoStack.redo(in: second)
        XCTAssertEqual(text(second), "hello there\n")
    }

    func testEditsAfterSaveUndoInOrderBackAcrossIt() {
        let (first, url) = newDocument("one\n")
        first.replace(3..<3, with: Array(" two".utf8))
        let second = saveAndReopen(first, at: url)
        second.replace(second.length - 1..<second.length - 1, with: Array(" three".utf8))
        XCTAssertEqual(text(second), "one two three\n")

        _ = second.undoStack.undo(in: second)
        XCTAssertEqual(text(second), "one two\n", "the post-save edit goes first")
        _ = second.undoStack.undo(in: second)
        XCTAssertEqual(text(second), "one\n", "then the pre-save one")
    }

    func testSavingAgainAfterAnUndoWritesTheRetiredBytes() {
        // After undoing across a save, the document is partly made of retired
        // pieces. Saving it must write them out correctly.
        let (first, url) = newDocument("alpha beta gamma\n")
        first.replace(6..<11, with: [])                       // "alpha gamma\n"
        let second = saveAndReopen(first, at: url)
        _ = second.undoStack.undo(in: second)                 // "alpha beta gamma\n" via retired(0)
        XCTAssertEqual(text(second), "alpha beta gamma\n")

        let third = saveAndReopen(second, at: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "alpha beta gamma\n")
        XCTAssertEqual(text(third), "alpha beta gamma\n")
        XCTAssertEqual(third.retiredFiles.count, 2, "two saves, two retired mappings")
    }

    // MARK: - Everything else that reads pieces

    func testSearchAndStatisticsSeeRetiredPieces() {
        let (first, url) = newDocument("find the needle here\n")
        first.replace(9..<16, with: [])                        // remove "needle "
        let second = saveAndReopen(first, at: url)
        _ = second.undoStack.undo(in: second)                  // "needle " is retired now
        XCTAssertEqual(text(second), "find the needle here\n")

        let search = SearchScan(query: "needle")!
        search.runSynchronously(in: second)
        XCTAssertEqual(search.matchOffsets(beginningIn: 0..<Int.max), [9])

        let statistics = StatisticsScan()
        statistics.runSynchronously(in: second)
        XCTAssertEqual(statistics.wordCount, 4)
    }

    // MARK: - History housekeeping

    func testRedoSurvivesTheSave() {
        let (first, url) = newDocument("x\n")
        first.replace(1..<1, with: Array("y".utf8))
        _ = first.undoStack.undo(in: first)                    // leaves a redo entry
        XCTAssertEqual(text(first), "x\n")
        let second = saveAndReopen(first, at: url)
        XCTAssertTrue(second.undoStack.canRedo)
        _ = second.undoStack.redo(in: second)
        XCTAssertEqual(text(second), "xy\n")
    }

    func testASaveEndsATypingRun() {
        let (first, url) = newDocument("")
        for character in "ab" {
            first.replace(first.length..<first.length, with: Array(String(character).utf8))
        }
        let second = saveAndReopen(first, at: url)
        for character in "cd" {
            second.replace(second.length..<second.length, with: Array(String(character).utf8))
        }
        _ = second.undoStack.undo(in: second)
        XCTAssertEqual(text(second), "ab", "typing after the save is its own undo step")
    }

    func testASaveWithNoHistoryRetiresNothing() {
        let (first, url) = newDocument("untouched\n")
        let second = saveAndReopen(first, at: url)
        XCTAssertTrue(second.retiredFiles.isEmpty, "nothing refers to the old mapping")
        XCTAssertFalse(second.undoStack.canUndo)
    }

    func testHistoryIsClearedRatherThanPinningMappingsForever() {
        var (document, url) = newDocument("0\n")
        for round in 1...(EditedDocument.maximumRetiredMappings + 1) {
            document.replace(document.length..<document.length, with: Array("\(round)\n".utf8))
            document = saveAndReopen(document, at: url)
        }
        XCTAssertTrue(document.retiredFiles.count <= EditedDocument.maximumRetiredMappings)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       (0...(EditedDocument.maximumRetiredMappings + 1)).map { "\($0)\n" }.joined(),
                       "every save still wrote the right bytes")
    }
}
