import XCTest
@testable import BigEdit

final class StatisticsScanTests: XCTestCase {

    func testCountsMatchWcSemantics() {
        // From `wc -lwm` (lines / words / chars) on this exact content.
        let cases: [(content: String, lines: Int, words: Int, chars: Int)] = [
            ("foo bar foo\nbaz foo\nno match here\nfoofoo\n", 4, 9, 41),
            ("", 0, 0, 0),
            ("single", 1, 1, 6),
            ("a b c\nd e\n", 2, 5, 10)
        ]
        for testCase in cases {
            let url = TestHelpers.writeTempFile(testCase.content)
            defer { TestHelpers.remove(url) }
            let file = MappedFile(path: url.path)!
            let stats = StatisticsScan()
            stats.runSynchronously(in: file)
            XCTAssertEqual(stats.wordCount, testCase.words,
                           "Wrong words for \(testCase.content.debugDescription)")
            XCTAssertEqual(stats.characterCount, testCase.chars,
                           "Wrong chars for \(testCase.content.debugDescription)")
            XCTAssertTrue(stats.isComplete)
        }
    }

    // MARK: - Counting the edited document

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

    /// Counts the logical bytes directly, as the answer the scan must match.
    private func expectedCounts(of document: EditedDocument) -> (words: Int, characters: Int) {
        let bytes = document.bytes(in: 0..<document.length)
        var words = 0
        var characters = 0
        var inWord = false
        for byte in bytes {
            let isWhitespace = byte == 0x20 || byte == 0x09 || byte == 0x0A
                || byte == 0x0D || byte == 0x0B || byte == 0x0C
            if isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
            if (byte & 0xC0) != 0x80 {
                characters += 1
            }
        }
        return (words, characters)
    }

    private func assertCountsMatchDocument(_ document: EditedDocument,
                                           _ message: String = "",
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        let scan = StatisticsScan()
        scan.runSynchronously(in: document)
        let expected = expectedCounts(of: document)
        XCTAssertEqual(scan.wordCount, expected.words, "words \(message)", file: file, line: line)
        XCTAssertEqual(scan.characterCount, expected.characters,
                       "characters \(message)", file: file, line: line)
        XCTAssertTrue(scan.isComplete, file: file, line: line)
    }

    func testUneditedDocumentCountsLikeTheFile() {
        assertCountsMatchDocument(makeDocument("a b c\nd e\n"))
    }

    func testCountsFollowAnInsertion() {
        let document = makeDocument("one two\n")
        document.replace(4..<4, with: Array("three ".utf8))
        assertCountsMatchDocument(document, "after inserting a word")
    }

    func testCountsFollowADeletion() {
        let document = makeDocument("alpha beta gamma\n")
        document.replace(0..<6, with: [])
        assertCountsMatchDocument(document, "after deleting a word")
    }

    /// The counts used to come from the file on disk, so an edit left them
    /// describing something the user could no longer see.
    func testCountsDescribeTheEditsNotTheFileOnDisk() {
        let document = makeDocument("one two three\n")
        document.replace(0..<document.length, with: Array("single\n".utf8))
        let scan = StatisticsScan()
        scan.runSynchronously(in: document)
        XCTAssertEqual(scan.wordCount, 1)
        XCTAssertEqual(scan.characterCount, 7)
    }

    /// A word split across a piece boundary must be counted once, not twice.
    func testAWordSplitAcrossPiecesIsCountedOnce() {
        let document = makeDocument("abcdef\n")
        document.replace(3..<3, with: Array("XYZ".utf8))     // abc|XYZ|def
        let scan = StatisticsScan()
        scan.runSynchronously(in: document)
        XCTAssertEqual(scan.wordCount, 1, "abcXYZdef is one word across three pieces")
        assertCountsMatchDocument(document, "with a word spanning pieces")
    }

    func testCountsAcrossManyEdits() {
        let document = makeDocument("the quick brown fox\njumps over\n")
        document.replace(4..<9, with: Array("slow".utf8))
        document.replace(0..<0, with: Array("well, ".utf8))
        document.replace(document.length..<document.length, with: Array("the lazy dog\n".utf8))
        assertCountsMatchDocument(document, "after several edits")
    }

    func testNonASCIICharactersCountAsOne() {
        let document = makeDocument("naïve café\n")
        document.replace(0..<0, with: Array("Spärck ".utf8))
        assertCountsMatchDocument(document, "with multi-byte characters")
    }
}
