import XCTest
@testable import BigEdit

/// Regular-expression search has to report byte ranges, over a file or an
/// edited document, that match what running the same pattern over the whole
/// text as one string would give — including across window boundaries and
/// through multi-byte characters, where a UTF-16 offset and a byte offset
/// part company.
final class RegularExpressionSearchTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func mapped(_ content: String) -> MappedFile {
        let url = TestHelpers.writeTempFile(content)
        temporaryFiles.append(url)
        return MappedFile(path: url.path)!
    }

    private func document(_ content: String) -> EditedDocument {
        let file = mapped(content)
        let index = LineIndex()
        index.buildSynchronously(from: file)
        return EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
    }

    /// Byte ranges of non-empty matches, computed by running the pattern over
    /// the whole text at once and converting each range through the UTF-8 view.
    private func expectedRanges(_ pattern: String, in text: String,
                                caseSensitive: Bool = true) -> [Range<Int>] {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !caseSensitive { options.insert(.caseInsensitive) }
        let expression = try! NSRegularExpression(pattern: pattern, options: options)
        let whole = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: whole).compactMap { match in
            guard match.range.length > 0, let range = Range(match.range, in: text) else { return nil }
            let start = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.utf8.distance(from: text.startIndex, to: range.upperBound)
            return start..<end
        }
    }

    private func actualRanges(_ pattern: String, in file: MappedFile,
                              caseSensitive: Bool = true, window: Int = 1 << 20) -> [Range<Int>] {
        let scan = SearchScan(regularExpression: pattern, caseSensitive: caseSensitive,
                              logicalScanWindow: window)!
        scan.runSynchronously(in: file)
        XCTAssertTrue(scan.isComplete)
        return scan.matches(beginningIn: 0..<Int.max)
    }

    // MARK: - Basics

    func testInvalidPatternFailsInit() {
        XCTAssertNil(SearchScan(regularExpression: "(unclosed"))
        XCTAssertNil(SearchScan(regularExpression: ""))
    }

    func testMatchesAreByteRanges() {
        let text = "id=12 name=ada\nid=345 name=alan\n"
        let file = mapped(text)
        let ranges = actualRanges("[0-9]+", in: file)
        XCTAssertEqual(ranges, expectedRanges("[0-9]+", in: text))
        XCTAssertEqual(ranges.map { $0.count }, [2, 3], "lengths vary per match")
    }

    func testAnchorsMatchAtLineBoundaries() {
        let text = "error one\nwarning\nerror two\n"
        let file = mapped(text)
        XCTAssertEqual(actualRanges("^error", in: file).count, 2)
        XCTAssertEqual(actualRanges("two$", in: file).count, 1)
    }

    func testCaseInsensitiveFoldsUnicode() {
        let text = "Straße STRASSE straße\n"
        let file = mapped(text)
        XCTAssertEqual(actualRanges("straße", in: file, caseSensitive: false),
                       expectedRanges("straße", in: text, caseSensitive: false))
        XCTAssertEqual(actualRanges("straße", in: file, caseSensitive: true).count, 1)
    }

    func testEmptyMatchesAreSkipped() {
        // `a*` matches the empty string everywhere; only the runs of `a` count.
        let file = mapped("baab\n")
        let ranges = actualRanges("a*", in: file)
        XCTAssertEqual(ranges, [1..<3])
    }

    func testMultiByteCharactersKeepByteOffsetsRight() {
        // Every character before the digits is more than one byte in UTF-8,
        // and one of them (🙂) is two UTF-16 units, so any mix-up between
        // UTF-16 offsets and byte offsets shows here.
        let text = "ñ🙂ü 42 ẞ 7\n"
        let file = mapped(text)
        let ranges = actualRanges("[0-9]+", in: file)
        XCTAssertEqual(ranges, expectedRanges("[0-9]+", in: text))
        for range in ranges {
            let bytes = Array(text.utf8)[range]
            XCTAssertTrue(bytes.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }, "range \(range) is digits")
        }
    }

    // MARK: - Windows

    func testSmallWindowsCutAtLinesGiveTheSameMatches() {
        var generator = SeededGenerator(seed: 5)
        var lines: [String] = []
        for _ in 0..<400 {
            let n = Int.random(in: 0...30, using: &generator)
            lines.append(String((0..<n).map { _ in "abc 123 xyz".randomElement(using: &generator)! }))
        }
        let text = lines.joined(separator: "\n") + "\n"
        let file = mapped(text)
        let expected = expectedRanges("[0-9]+|abc", in: text)
        for window in [40, 97, 500, 1 << 20] {
            XCTAssertEqual(actualRanges("[0-9]+|abc", in: file, window: window), expected,
                           "window \(window)")
        }
    }

    func testLineLongerThanTheWindowIsSearchedWhole() {
        // One 5,000-byte line with a window of 1,000. A window with no newline
        // in it grows until it holds the whole line, so the cut always lands
        // on a line boundary and neither match can be split in two.
        var text = String(repeating: "x", count: 500) + "111"
        text += String(repeating: "x", count: 2000) + "222"
        text += String(repeating: "x", count: 2000) + "\n"
        let file = mapped(text)
        let found = actualRanges("[0-9]+", in: file, window: 1000)
        XCTAssertEqual(found.map { String(decoding: Array(text.utf8)[$0], as: UTF8.self) },
                       ["111", "222"])
    }

    // MARK: - Invalid bytes

    func testALineOfInvalidUTF8IsSkippedAndTheRestIsSearched() {
        var bytes = Array("good 1\n".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, 0x20, 0x32, 0x0A])   // "?? 2" but not UTF-8
        bytes.append(contentsOf: Array("good 3\n".utf8))
        let url = TestHelpers.writeTempFile(Data(bytes))
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let ranges = actualRanges("[0-9]", in: file)
        XCTAssertEqual(ranges.map { $0.lowerBound }, [5, 17], "the digits on the two valid lines")
    }

    // MARK: - Edited documents

    func testEditedDocumentIsSearchedThroughThePieceTable() {
        let doc = document("alpha 1\nbeta 2\n")
        doc.replace(6..<7, with: Array("99".utf8))           // "alpha 99"
        doc.replace(doc.length..<doc.length, with: Array("gamma 3\n".utf8))
        let text = String(decoding: doc.bytes(in: 0..<doc.length), as: UTF8.self)
        let scan = SearchScan(regularExpression: "[0-9]+")!
        scan.runSynchronously(in: doc)
        XCTAssertEqual(scan.matches(beginningIn: 0..<Int.max), expectedRanges("[0-9]+", in: text))
    }

    func testFuzzEditedDocumentAgainstWholeStringMatching() {
        for seed: UInt64 in [2, 44, 808] {
            var generator = SeededGenerator(seed: seed)
            let doc = document("start 0\n")
            for _ in 0..<25 {
                let at = Int.random(in: 0...doc.length, using: &generator)
                let piece = ["7", "ab", "\n", " ", "x9y", "zz\n"].randomElement(using: &generator)!
                doc.replace(at..<at, with: Array(piece.utf8))
            }
            let text = String(decoding: doc.bytes(in: 0..<doc.length), as: UTF8.self)
            for window in [8, 64, 1 << 20] {
                let scan = SearchScan(regularExpression: "[0-9]+|ab", logicalScanWindow: window)!
                scan.runSynchronously(in: doc)
                XCTAssertEqual(scan.matches(beginningIn: 0..<Int.max),
                               expectedRanges("[0-9]+|ab", in: text),
                               "seed \(seed) window \(window)")
            }
        }
    }

    // MARK: - Literal mode is untouched

    func testLiteralScanStillReportsFixedLengthRanges() {
        let file = mapped("foo foo\n")
        let scan = SearchScan(query: "foo")!
        scan.runSynchronously(in: file)
        XCTAssertEqual(scan.matches(beginningIn: 0..<Int.max), [0..<3, 4..<7])
        XCTAssertEqual(scan.longestMatchLength, 3)
        XCTAssertFalse(scan.isRegularExpression)
    }
}
