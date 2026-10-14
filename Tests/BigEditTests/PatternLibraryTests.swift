import XCTest
@testable import BigEdit

/// The saved patterns round-trip through one JSON file and survive the
/// file going missing or being damaged.
final class PatternLibraryTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditPatterns-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func fileURL(_ name: String = PatternLibrary.fileName) -> URL {
        directory.appendingPathComponent(name)
    }

    func testAMissingFileIsAnEmptyLibrary() {
        let library = PatternLibrary(fileURL: fileURL())
        XCTAssertEqual(library.patterns, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL().path))
    }

    func testPatternsRoundTripThroughTheFile() {
        let library = PatternLibrary(fileURL: fileURL())
        let saved = SavedPattern(name: "dates", pattern: "\\d{4}-\\d{2}-\\d{2}", replacement: "$0!",
                                 isRegularExpression: true, isCaseSensitive: false, note: "ISO dates")
        XCTAssertNil(library.add(saved))
        XCTAssertNil(library.add(SavedPattern(name: "plain", pattern: "foo", isRegularExpression: false)))

        let reopened = PatternLibrary(fileURL: fileURL())
        XCTAssertEqual(reopened.patterns, library.patterns)
        XCTAssertEqual(reopened.patterns.first, saved)
    }

    func testUpdateRemoveAndMove() {
        let library = PatternLibrary(fileURL: fileURL())
        let first = SavedPattern(name: "one", pattern: "1")
        let second = SavedPattern(name: "two", pattern: "2")
        library.add(first)
        library.add(second)

        var renamed = first
        renamed.name = "uno"
        library.update(renamed)
        XCTAssertEqual(library.patterns.map(\.name), ["uno", "two"])

        library.move(from: 1, to: 0)
        XCTAssertEqual(library.patterns.map(\.name), ["two", "uno"])

        library.remove(id: second.id)
        XCTAssertEqual(PatternLibrary(fileURL: fileURL()).patterns.map(\.name), ["uno"])
    }

    func testAFileThatStopsBeingReadableKeepsThePatternsAlreadyLoaded() throws {
        let library = PatternLibrary(fileURL: fileURL())
        library.add(SavedPattern(name: "kept", pattern: "k"))
        try Data("damaged".utf8).write(to: fileURL())
        library.reload()
        XCTAssertEqual(library.patterns.map(\.name), ["kept"])
        try FileManager.default.removeItem(at: fileURL())
        library.reload()
        XCTAssertEqual(library.patterns, [], "a file that is gone is an empty library")
    }

    func testADamagedFileReadsAsEmptyAndIsNotOverwrittenUntilAChange() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL())
        let library = PatternLibrary(fileURL: fileURL())
        XCTAssertEqual(library.patterns, [])
        XCTAssertEqual(try String(contentsOf: fileURL(), encoding: .utf8), "not json")
    }

    func testChangesPostANotification() {
        let library = PatternLibrary(fileURL: fileURL())
        let expectation = expectation(forNotification: PatternLibrary.didChangeNotification,
                                      object: library)
        library.add(SavedPattern(name: "x", pattern: "x"))
        wait(for: [expectation], timeout: 1)
    }

    func testReloadIfChangedPicksUpAnotherWriter() {
        let library = PatternLibrary(fileURL: fileURL())
        let writer = PatternLibrary(fileURL: fileURL())
        writer.add(SavedPattern(name: "from elsewhere", pattern: "e"))
        library.reloadIfChangedOnDisk()
        XCTAssertEqual(library.patterns.map(\.name), ["from elsewhere"])
    }

    func testRelocateMovesTheFileOrAdoptsAnExistingOne() throws {
        let library = PatternLibrary(fileURL: fileURL("a.json"))
        library.add(SavedPattern(name: "a", pattern: "a"))
        try library.relocate(to: fileURL("b.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL("a.json").path))
        XCTAssertEqual(PatternLibrary(fileURL: fileURL("b.json")).patterns.map(\.name), ["a"])

        let other = PatternLibrary(fileURL: fileURL("c.json"))
        other.add(SavedPattern(name: "c", pattern: "c"))
        try library.relocate(to: fileURL("c.json"))
        XCTAssertEqual(library.patterns.map(\.name), ["c"], "an existing file at the destination wins")
    }

    func testSuggestedNamesAreUnique() {
        let library = PatternLibrary(fileURL: fileURL())
        XCTAssertEqual(library.suggestedName(for: "foo"), "foo")
        library.add(SavedPattern(name: "foo", pattern: "foo"))
        XCTAssertEqual(library.suggestedName(for: "foo"), "foo 2")
        XCTAssertEqual(library.suggestedName(for: ""), "Pattern")
    }
}
