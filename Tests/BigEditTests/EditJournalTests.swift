import XCTest
@testable import BigEdit

/// The journal has to bring back exactly the unsaved edits, and only when the
/// file on disk is still the one they were made against. Every test here
/// "crashes" by simply dropping the document and opening the file again.
final class EditJournalTests: XCTestCase {

    private var temporaryFiles: [URL] = []
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditJournalTest-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func open(_ url: URL) -> EditedDocument {
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.journal = EditJournal.open(for: url.path, in: root)
        return document
    }

    /// A document with a fresh baseline, as a first open produces.
    private func openFresh(_ content: String) -> (EditedDocument, URL) {
        let url = TestHelpers.writeTempFile(content)
        temporaryFiles.append(url)
        let document = open(url)
        document.journal!.setBaseline(document.file)
        return (document, url)
    }

    /// Opens the file again as after a relaunch and recovers if the journal
    /// says there is something to recover.
    private func reopenAndRecover(_ url: URL) -> (document: EditedDocument, recovered: Bool) {
        let document = open(url)
        var recovered = false
        if document.journal!.hasRecoverableEdits(for: document.file) {
            recovered = document.recover(from: document.journal!)
        }
        return (document, recovered)
    }

    private func text(_ document: EditedDocument) -> String {
        String(decoding: document.bytes(in: 0..<document.length), as: UTF8.self)
    }

    // MARK: - Recovery

    func testEditsComeBackAfterACrash() {
        let (first, url) = openFresh("alpha beta gamma\n")
        first.replace(6..<10, with: Array("BETA".utf8))
        first.replace(0..<0, with: Array("> ".utf8))
        first.replace(first.length..<first.length, with: Array("delta\n".utf8))
        let expected = text(first)
        XCTAssertEqual(expected, "> alpha BETA gamma\ndelta\n")

        let (second, recovered) = reopenAndRecover(url)
        XCTAssertTrue(recovered)
        XCTAssertEqual(text(second), expected)
        XCTAssertTrue(second.hasEdits, "the recovered document is dirty, as it should be")
    }

    func testUndoneEditsAreRecoveredAsUndone() {
        let (first, url) = openFresh("keep\n")
        first.replace(4..<4, with: Array(" this".utf8))
        first.replace(0..<0, with: Array("no ".utf8))
        _ = first.undoStack.undo(in: first)                  // journaled as a splice too
        XCTAssertEqual(text(first), "keep this\n")

        let (second, recovered) = reopenAndRecover(url)
        XCTAssertTrue(recovered)
        XCTAssertEqual(text(second), "keep this\n")
    }

    func testEditingAfterRecoveryContinuesTheSameJournal() {
        let (first, url) = openFresh("a\n")
        first.replace(1..<1, with: Array("b".utf8))
        let (second, _) = reopenAndRecover(url)
        second.replace(2..<2, with: Array("c".utf8))
        XCTAssertEqual(text(second), "abc\n")

        let (third, recovered) = reopenAndRecover(url)
        XCTAssertTrue(recovered)
        XCTAssertEqual(text(third), "abc\n", "both the recovered and the later edit came back")
    }

    // MARK: - When the journal must not apply

    func testNothingIsRecoveredWhenTheFileChangedUnderneath() {
        let (first, url) = openFresh("original\n")
        first.replace(0..<0, with: Array("edit ".utf8))
        try! Data("rewritten elsewhere\n".utf8).write(to: url)   // same path, new content

        let (second, recovered) = reopenAndRecover(url)
        XCTAssertFalse(recovered)
        XCTAssertEqual(text(second), "rewritten elsewhere\n")
        XCTAssertFalse(second.hasEdits)
    }

    func testACrashMidWriteDropsOnlyTheTornRecord() {
        let (first, url) = openFresh("one two three\n")
        first.replace(0..<3, with: Array("ONE".utf8))
        first.replace(4..<7, with: Array("TWO".utf8))
        let afterTwo = text(first)
        first.replace(8..<13, with: Array("THREE".utf8))

        // Chop the last few bytes off the ops file, as a crash mid-append would.
        let operations = first.journal!.directory.appendingPathComponent("ops")
        var data = try! Data(contentsOf: operations)
        data.removeLast(5)
        try! data.write(to: operations)

        let (second, recovered) = reopenAndRecover(url)
        XCTAssertTrue(recovered)
        XCTAssertEqual(text(second), afterTwo, "everything before the torn record applies")
    }

    func testASaveMovesTheBaselineAndEmptiesTheOperations() {
        let (first, url) = openFresh("before\n")
        first.replace(0..<0, with: Array("well ".utf8))
        guard case .success = FileWriter.saveSynchronously(document: first, to: url) else {
            return XCTFail("save failed")
        }
        // As the app does after a save: the new file is the baseline.
        let saved = open(url)
        saved.journal!.setBaseline(saved.file)
        XCTAssertEqual(text(saved), "well before\n")
        XCTAssertFalse(saved.journal!.hasRecoverableEdits(for: saved.file))

        saved.replace(saved.length..<saved.length, with: Array("after\n".utf8))
        let (third, recovered) = reopenAndRecover(url)
        XCTAssertTrue(recovered)
        XCTAssertEqual(text(third), "well before\nafter\n",
                       "only the post-save edit replays, over the saved file")
    }

    func testDiscardRemovesEverything() {
        let (first, url) = openFresh("x\n")
        first.replace(0..<0, with: Array("y".utf8))
        let directory = first.journal!.directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        first.journal!.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let (second, recovered) = reopenAndRecover(url)
        XCTAssertFalse(recovered)
        XCTAssertEqual(text(second), "x\n")
    }

    func testAnUntouchedDocumentHasNothingToRecover() {
        let (first, url) = openFresh("untouched\n")
        XCTAssertFalse(first.journal!.hasRecoverableEdits(for: first.file))
        let (_, recovered) = reopenAndRecover(url)
        XCTAssertFalse(recovered)
    }

    func testJournalDirectoriesAreKeyedByPath() {
        let one = EditJournal.directory(for: "/a/b.txt", in: root)
        let two = EditJournal.directory(for: "/a/c.txt", in: root)
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(one, EditJournal.directory(for: "/a/b.txt", in: root), "stable across runs")
    }
}
