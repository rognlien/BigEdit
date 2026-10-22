import XCTest
@testable import BigEdit

/// The add buffer reads back exactly what was appended, whether it is still
/// in memory or has spilled to disk, and a spill leaves nothing behind.
final class AddBufferTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditSpillTest-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        TestHelpers.remove(directory)
        super.tearDown()
    }

    private func contents(of directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    func testASmallBufferStaysInMemory() {
        let buffer = AddBuffer(spillThreshold: 16, spillDirectory: directory)
        XCTAssertEqual(buffer.append(Array("hello".utf8)), 0..<5)
        XCTAssertFalse(buffer.isSpilled)
        XCTAssertEqual(buffer.bytes(in: 1..<4), Array("ell".utf8))
    }

    func testPassingTheThresholdSpillsWhatWasAlreadyThere() {
        let buffer = AddBuffer(spillThreshold: 8, spillDirectory: directory)
        buffer.append(Array("hello".utf8))
        XCTAssertEqual(buffer.append(Array(" world".utf8)), 5..<11)
        XCTAssertTrue(buffer.isSpilled)
        XCTAssertEqual(buffer.count, 11)
        XCTAssertEqual(buffer.bytes(in: 0..<11), Array("hello world".utf8))
        XCTAssertEqual(buffer.bytes(in: 3..<7), Array("lo w".utf8))
    }

    func testASpillFileTakesNoNameInItsDirectory() {
        let buffer = AddBuffer(spillThreshold: 0, spillDirectory: directory)
        buffer.append([1, 2, 3])
        XCTAssertTrue(buffer.isSpilled)
        XCTAssertEqual(contents(of: directory), [])
    }

    func testAnUnwritableDirectoryKeepsTheBytesInMemory() throws {
        let blocker = TestHelpers.writeTempFile("not a directory")
        defer { TestHelpers.remove(blocker) }
        let buffer = AddBuffer(spillThreshold: 0, spillDirectory: blocker.appendingPathComponent("inside"))
        buffer.append([1, 2, 3])
        buffer.append([4])
        XCTAssertFalse(buffer.isSpilled)
        XCTAssertEqual(buffer.bytes(in: 0..<4), [1, 2, 3, 4])
    }

    /// Appends of every size and reads that start and end anywhere — inside
    /// a page, across pages, past the cache's read limit, in the growing
    /// last page — against a plain array.
    func testRandomAppendsAndReadsMatchAnArray() {
        var generator = SeededGenerator(seed: 7)
        let buffer = AddBuffer(spillThreshold: 1000, spillDirectory: directory)
        var expected: [UInt8] = []
        let page = SpillFile.pageLength
        for _ in 0..<120 {
            let length = [1, 3, 100, page - 1, page + 7, 3 * page].randomElement(using: &generator)!
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            XCTAssertEqual(buffer.append(bytes), expected.count..<(expected.count + length))
            expected += bytes
            for _ in 0..<4 {
                let start = Int.random(in: 0..<expected.count, using: &generator)
                let readLength = [1, 17, page, SpillFile.uncachedReadLength + 5].randomElement(using: &generator)!
                let range = start..<min(expected.count, start + readLength)
                XCTAssertEqual(buffer.bytes(in: range), Array(expected[range]))
            }
        }
        XCTAssertTrue(buffer.isSpilled)
        XCTAssertEqual(buffer.bytes(in: 0..<expected.count), expected)
    }

    func testOnlyOldLeftoversAreRemoved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent("old")
        let new = directory.appendingPathComponent("new")
        try Data([1]).write(to: old)
        try Data([1]).write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: old.path)
        AddBuffer.removeLeftoverSpillFiles(in: directory)
        XCTAssertEqual(contents(of: directory), ["new"])
    }

    func testASpilledBufferSavesAndUndoes() throws {
        let url = TestHelpers.writeTempFile("one\ntwo\n")
        let output = url.appendingPathExtension("out")
        defer {
            TestHelpers.remove(url)
            TestHelpers.remove(output)
        }
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index,
                                      addBuffer: AddBuffer(spillThreshold: 4, spillDirectory: directory))
        document.replace(4..<4, with: Array("inserted\n".utf8))
        document.replace(0..<3, with: Array("ONE".utf8))
        XCTAssertTrue(document.addBuffer.isSpilled)
        XCTAssertEqual(document.bytes(in: 0..<document.length), Array("ONE\ninserted\ntwo\n".utf8))

        XCTAssertNoThrow(try FileWriter.saveSynchronously(document: document, to: output).get())
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "ONE\ninserted\ntwo\n")

        _ = document.undoStack.undo(in: document)
        XCTAssertEqual(document.bytes(in: 0..<document.length), Array("one\ninserted\ntwo\n".utf8))
    }
}
