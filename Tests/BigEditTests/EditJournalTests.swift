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

    func testEditsAfterASaveToANewFileComeBackAfterACrash() {
        let (first, _) = openFresh("start\n")
        first.replace(0..<0, with: Array("typed ".utf8))
        let destination = TestHelpers.writeTempFile("")
        temporaryFiles.append(destination)
        guard case .success = FileWriter.saveSynchronously(document: first, to: destination) else {
            return XCTFail("save failed")
        }
        // As the app does after Save As: the new file carries the add buffer over.
        let savedFile = MappedFile(path: destination.path)!
        let index = LineIndex()
        index.buildSynchronously(from: savedFile)
        let saved = EditedDocument(file: savedFile, editModel: EditModel(), lineIndex: index,
                                   inheritingHistoryFrom: first)
        saved.journal = EditJournal.open(for: destination.path, in: root)
        saved.journal!.setBaseline(saved.file, mirroring: saved.addBuffer)
        saved.replace(saved.length..<saved.length, with: Array("more\n".utf8))

        let (third, recovered) = reopenAndRecover(destination)
        XCTAssertTrue(recovered)
        XCTAssertEqual(text(third), "typed start\nmore\n")
    }

    func testPendingOperationsCanBeSeenWithoutOpeningTheJournal() {
        let (first, url) = openFresh("seen\n")
        XCTAssertFalse(EditJournal.hasPendingOperations(forPath: url.path, in: root))
        first.replace(0..<0, with: Array("+".utf8))
        XCTAssertTrue(EditJournal.hasPendingOperations(forPath: url.path, in: root))
        XCTAssertFalse(EditJournal.hasPendingOperations(forPath: "/nowhere/at/all", in: root))
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

    // MARK: - The baseline fingerprint

    private func state(reopening url: URL) -> EditJournal.RecoveryState {
        let document = open(url)
        return document.journal!.recoveryState(for: document.file)
    }

    private func setModificationDate(_ date: Date, of url: URL) {
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func modificationDate(of url: URL) -> Date {
        try! FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
    }

    private func manifestURL(of document: EditedDocument) -> URL {
        document.journal!.directory.appendingPathComponent("manifest.json")
    }

    /// Rewrites the manifest as the first format wrote it: no content sample.
    private func makeLegacyManifest(of document: EditedDocument) {
        let url = manifestURL(of: document)
        var manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        manifest["sample"] = nil
        manifest["version"] = 1
        try! JSONSerialization.data(withJSONObject: manifest).write(to: url)
    }

    func testAnUnchangedFileIsRecoverable() {
        let (first, url) = openFresh("same\n")
        first.replace(0..<0, with: Array("+".utf8))
        XCTAssertEqual(state(reopening: url), .recoverable)
    }

    func testAFileOfAnotherSizeIsReportedAsChangedAndKeepsItsEdits() {
        let (first, url) = openFresh("original\n")
        first.replace(0..<0, with: Array("edit ".utf8))
        try! Data("rewritten elsewhere\n".utf8).write(to: url)

        XCTAssertEqual(state(reopening: url), .baselineChanged)
        XCTAssertEqual(first.journal!.readOperations()?.count, 1, "asking does not discard")
    }

    func testSameSizeDifferentContentIsReportedAsChanged() {
        let (first, url) = openFresh("abcdef\n")
        first.replace(0..<0, with: Array("+".utf8))
        let date = modificationDate(of: url)
        try! Data("ABCDEF\n".utf8).write(to: url)
        setModificationDate(date, of: url)

        XCTAssertEqual(state(reopening: url), .baselineChanged, "the sample catches it")
    }

    func testAChangeAtTheTailOfALargeFileIsCaught() {
        let length = EditJournal.sampleLength * 3
        let (first, url) = openFresh(String(repeating: "x", count: length))
        first.replace(0..<0, with: Array("+".utf8))
        let date = modificationDate(of: url)
        try! Data((String(repeating: "x", count: length - 1) + "y").utf8).write(to: url)
        setModificationDate(date, of: url)

        XCTAssertEqual(state(reopening: url), .baselineChanged)
    }

    func testATouchedFileIsUncertain() {
        let (first, url) = openFresh("touched\n")
        first.replace(0..<0, with: Array("+".utf8))
        setModificationDate(Date(timeIntervalSinceNow: 60), of: url)

        XCTAssertEqual(state(reopening: url), .baselineUncertain)
    }

    func testRecoveringOntoAnUncertainFileAdoptsItAsTheBaseline() {
        let (first, url) = openFresh("touched\n")
        first.replace(0..<0, with: Array("+".utf8))
        setModificationDate(Date(timeIntervalSinceNow: 60), of: url)
        let second = open(url)
        XCTAssertTrue(second.recover(from: second.journal!))
        second.journal!.adoptBaseline(second.file)

        let (third, recovered) = reopenAndRecover(url)
        XCTAssertTrue(recovered)
        XCTAssertEqual(text(third), "+touched\n")
    }

    func testALegacyManifestStillRecoversAnUnchangedFile() {
        let (first, url) = openFresh("legacy\n")
        first.replace(0..<0, with: Array("+".utf8))
        makeLegacyManifest(of: first)

        let (second, recovered) = reopenAndRecover(url)
        XCTAssertTrue(recovered)
        XCTAssertEqual(text(second), "+legacy\n")
    }

    func testALegacyManifestCannotVouchForATouchedFile() {
        let (first, url) = openFresh("legacy\n")
        first.replace(0..<0, with: Array("+".utf8))
        makeLegacyManifest(of: first)
        setModificationDate(Date(timeIntervalSinceNow: 60), of: url)

        XCTAssertEqual(state(reopening: url), .baselineUncertain)
    }

    func testAMissingManifestIsTreatedAsChanged() {
        let (first, url) = openFresh("orphan\n")
        first.replace(0..<0, with: Array("+".utf8))
        try! FileManager.default.removeItem(at: manifestURL(of: first))

        XCTAssertEqual(state(reopening: url), .baselineChanged)
    }

    func testAnUnreadableManifestDoesNotCrash() {
        let (first, url) = openFresh("garbled\n")
        first.replace(0..<0, with: Array("+".utf8))
        try! Data("{not json".utf8).write(to: manifestURL(of: first))

        XCTAssertEqual(state(reopening: url), .baselineChanged)
    }

    // MARK: - Cleaning up

    /// Leaves a journal with pending edits behind, as a crash does, and
    /// returns its directory once nothing holds it.
    private func abandonJournal(_ content: String) -> (directory: URL, file: URL) {
        let (document, url) = openFresh(content)
        document.replace(0..<0, with: Array("+".utf8))
        return (document.journal!.directory, url)
    }

    private func age(_ directory: URL, by interval: TimeInterval) {
        let date = Date(timeIntervalSinceNow: -interval)
        let files = try! FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in files + [directory] {
            setModificationDate(date, of: url)
        }
    }

    private func exists(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    func testCleanupKeepsARecentJournalWhoseFileExists() {
        let (directory, _) = abandonJournal("kept\n")
        EditJournal.removeStaleJournals(in: root)
        XCTAssertTrue(exists(directory))
    }

    func testCleanupRemovesAJournalWhoseFileIsGone() {
        let (directory, url) = abandonJournal("gone\n")
        try! FileManager.default.removeItem(at: url)
        EditJournal.removeStaleJournals(in: root)
        XCTAssertFalse(exists(directory))
    }

    func testCleanupRemovesAJournalUntouchedForTooLong() {
        let (directory, _) = abandonJournal("old\n")
        age(directory, by: EditJournal.maximumAge + 60)
        EditJournal.removeStaleJournals(in: root)
        XCTAssertFalse(exists(directory))
    }

    func testCleanupKeepsAJournalEditedRecentlyInAnOldDirectory() {
        let (directory, _) = abandonJournal("old\n")
        age(directory, by: EditJournal.maximumAge + 60)
        setModificationDate(Date(), of: directory.appendingPathComponent("ops"))
        EditJournal.removeStaleJournals(in: root)
        XCTAssertTrue(exists(directory))
    }

    func testCleanupNeverRemovesTheJournalOfAnOpenDocument() {
        let (document, url) = openFresh("open\n")
        document.replace(0..<0, with: Array("+".utf8))
        let directory = document.journal!.directory
        age(directory, by: EditJournal.maximumAge + 60)
        try! FileManager.default.removeItem(at: url)

        EditJournal.removeStaleJournals(in: root)
        XCTAssertTrue(exists(directory))
        XCTAssertNotNil(document.journal)
    }

    func testCleanupRemovesAnOldJournalWithoutAManifest() {
        let directory = root.appendingPathComponent("orphan", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! Data([1]).write(to: directory.appendingPathComponent("ops"))
        age(directory, by: EditJournal.maximumAge + 60)
        EditJournal.removeStaleJournals(in: root)
        XCTAssertFalse(exists(directory))
    }

    func testCleanupOfAMissingRootDoesNothing() {
        EditJournal.removeStaleJournals(in: root.appendingPathComponent("absent"))
        XCTAssertFalse(exists(root.appendingPathComponent("absent")))
    }

    func testJournalDirectoriesAreKeyedByPath() {
        let one = EditJournal.directory(for: "/a/b.txt", in: root)
        let two = EditJournal.directory(for: "/a/c.txt", in: root)
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(one, EditJournal.directory(for: "/a/b.txt", in: root), "stable across runs")
    }
}
