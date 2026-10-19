import XCTest
@testable import BigEdit

/// An untitled document is an empty placeholder file in a directory of its
/// own, named the way TextEdit names its untitled windows.
final class UntitledDocumentsTests: XCTestCase {

    private var untitled: UntitledDocuments!

    override func setUp() {
        super.setUp()
        untitled = TestHelpers.isolatedUntitledDocuments()
    }

    override func tearDown() {
        TestHelpers.remove(untitled.directory)
        super.tearDown()
    }

    func testAPlaceholderIsAnEmptyFileInTheDirectory() throws {
        let url = try XCTUnwrap(untitled.makePlaceholder())
        XCTAssertTrue(untitled.contains(url))
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testEachPlaceholderIsANewFile() throws {
        let first = try XCTUnwrap(untitled.makePlaceholder())
        let second = try XCTUnwrap(untitled.makePlaceholder())
        XCTAssertNotEqual(first, second)
    }

    func testAFileElsewhereIsNotAPlaceholder() {
        let url = TestHelpers.writeTempFile("")
        defer { TestHelpers.remove(url) }
        XCTAssertFalse(untitled.contains(url))
    }

    func testTheFirstIsUntitledAndTheRestAreNumbered() {
        XCTAssertEqual(UntitledDocuments.name(numbered: 1), "Untitled")
        XCTAssertEqual(UntitledDocuments.name(numbered: 2), "Untitled 2")
    }

    func testTheLowestNumberNotInUseIsTaken() {
        XCTAssertEqual(UntitledDocuments.lowestUnusedNumber(among: []), 1)
        XCTAssertEqual(UntitledDocuments.lowestUnusedNumber(among: [1, 2]), 3)
        XCTAssertEqual(UntitledDocuments.lowestUnusedNumber(among: [2, 3]), 1)
        XCTAssertEqual(UntitledDocuments.lowestUnusedNumber(among: [3, 1]), 2)
    }

    // MARK: - Across launches

    private func typeIntoPlaceholder(_ url: URL, _ text: String, journalRoot: URL) -> EditedDocument {
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.journal = EditJournal.open(for: url.path, in: journalRoot)
        document.journal!.setBaseline(document.file)
        document.replace(0..<0, with: Array(text.utf8))
        return document
    }

    func testTheTextOfAnUntitledDocumentComesBackFromItsJournal() throws {
        let journalRoot = untitled.directory.appendingPathComponent("Journals", isDirectory: true)
        let url = try XCTUnwrap(untitled.makePlaceholder())
        _ = typeIntoPlaceholder(url, "kept across quit\n", journalRoot: journalRoot)

        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let reopened = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        reopened.journal = EditJournal.open(for: url.path, in: journalRoot)
        XCTAssertEqual(reopened.journal!.recoveryState(for: file), .recoverable)
        XCTAssertTrue(reopened.recover(from: reopened.journal!))
        XCTAssertEqual(String(decoding: reopened.bytes(in: 0..<reopened.length), as: UTF8.self),
                       "kept across quit\n")
    }

    func testPlaceholdersWithTextAreThoseWrittenToOrWithJournaledEdits() throws {
        let journalRoot = untitled.directory.appendingPathComponent("Journals", isDirectory: true)
        let empty = try XCTUnwrap(untitled.makePlaceholder())
        let written = try XCTUnwrap(untitled.makePlaceholder())
        try Data("on disk\n".utf8).write(to: written)
        let journaled = try XCTUnwrap(untitled.makePlaceholder())
        _ = typeIntoPlaceholder(journaled, "typed\n", journalRoot: journalRoot)

        let found = untitled.placeholdersWithText(excluding: [], journalRoot: journalRoot)
        XCTAssertEqual(Set(found.map(\.lastPathComponent)),
                       [written.lastPathComponent, journaled.lastPathComponent])
        XCTAssertFalse(found.map(\.lastPathComponent).contains(empty.lastPathComponent))
    }

    func testPlaceholdersAlreadyOpenAreNotReopened() throws {
        let journalRoot = untitled.directory.appendingPathComponent("Journals", isDirectory: true)
        let written = try XCTUnwrap(untitled.makePlaceholder())
        try Data("on disk\n".utf8).write(to: written)

        XCTAssertEqual(untitled.placeholdersWithText(excluding: [written], journalRoot: journalRoot), [])
    }

    func testCleanupRemovesOnlyEmptyPlaceholdersThatAreNotOpen() throws {
        let journalRoot = untitled.directory.appendingPathComponent("Journals", isDirectory: true)
        let open = try XCTUnwrap(untitled.makePlaceholder())
        let abandoned = try XCTUnwrap(untitled.makePlaceholder())
        let written = try XCTUnwrap(untitled.makePlaceholder())
        try Data("on disk\n".utf8).write(to: written)
        let journaled = try XCTUnwrap(untitled.makePlaceholder())
        _ = typeIntoPlaceholder(journaled, "typed\n", journalRoot: journalRoot)

        untitled.removeUnusedPlaceholders(keeping: [open], journalRoot: journalRoot)

        let remaining = Set(untitled.placeholders().map(\.lastPathComponent))
        XCTAssertEqual(remaining, [open.lastPathComponent, written.lastPathComponent,
                                   journaled.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }

    func testAMissingDirectoryHasNoPlaceholders() {
        XCTAssertEqual(untitled.placeholders(), [])
    }

    // MARK: - The first save

    private func suggestedName(for text: String) -> String {
        let language = UntitledDocuments.language(ofHead: Array(text.utf8))
        return UntitledDocuments.suggestedFileName("Untitled", language: language)
    }

    func testPlainTextIsSuggestedAsText() {
        XCTAssertEqual(suggestedName(for: ""), "Untitled.txt")
        XCTAssertEqual(suggestedName(for: "hello\n"), "Untitled.txt")
    }

    func testTextThatLooksLikeALanguageGetsItsExtension() {
        XCTAssertEqual(suggestedName(for: "  {\"a\": 1}\n"), "Untitled.json")
        XCTAssertEqual(suggestedName(for: "<root/>\n"), "Untitled.xml")
        XCTAssertEqual(suggestedName(for: "#!/bin/sh\necho hi\n"), "Untitled.sh")
    }

    func testTheNumberedNameIsKept() {
        XCTAssertEqual(UntitledDocuments.suggestedFileName("Untitled 2", language: LanguageRegistry.markdown),
                       "Untitled 2.md")
    }
}
