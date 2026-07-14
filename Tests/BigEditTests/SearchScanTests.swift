import XCTest
@testable import BigEdit

/// The piece-table search must find exactly what a naive search over the
/// materialised edited bytes finds — including matches created by edits and
/// matches straddling scan-window boundaries.
final class EditedSearchScanTests: XCTestCase {

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

    /// All match offsets from a synchronous logical scan.
    private func offsets(of query: String, in document: EditedDocument,
                         caseSensitive: Bool = true, window: Int = 64 * 1024 * 1024) -> [Int] {
        let scan = SearchScan(query: query, caseSensitive: caseSensitive,
                              logicalScanWindow: window)!
        scan.runSynchronously(in: document)
        return scan.matchOffsets(beginningIn: 0..<Int.max)
    }

    /// Non-overlapping match offsets computed naively over plain bytes.
    private func naiveOffsets(of query: [UInt8], in bytes: [UInt8]) -> [Int] {
        var result: [Int] = []
        var cursor = 0
        while cursor + query.count <= bytes.count {
            if Array(bytes[cursor..<(cursor + query.count)]) == query {
                result.append(cursor)
                cursor += query.count
            } else {
                cursor += 1
            }
        }
        return result
    }

    func testMatchesCreatedByEditsAreFound() {
        let document = makeDocument("alpha beta gamma\n")
        document.replace(6..<10, with: Array("alpha".utf8))   // beta → alpha

        XCTAssertEqual(offsets(of: "alpha", in: document), [0, 6])
    }

    func testMatchSpanningAnEditBoundaryIsFound() {
        let document = makeDocument("ab--cd\n")
        document.replace(2..<4, with: Array("XY".utf8))       // "abXYcd"

        // "bXY" spans original + added pieces; "Ycd" spans added + original.
        XCTAssertEqual(offsets(of: "bXY", in: document), [1])
        XCTAssertEqual(offsets(of: "Ycd", in: document), [3])
    }

    func testWindowBoundaryStraddlingMatches() {
        // A tiny scan window forces many boundaries; matches must neither be
        // lost at boundaries nor double-counted in the overlap.
        let content = String(repeating: "needle-", count: 40)
        let document = makeDocument(content)
        document.replace(3..<3, with: Array("x".utf8))        // force the piece path

        let expected = naiveOffsets(of: Array("needle".utf8),
                                    in: document.bytes(in: 0..<document.length))
        for window in [7, 11, 30, 64] {
            XCTAssertEqual(offsets(of: "needle", in: document, window: window), expected,
                           "window \(window)")
        }
    }

    func testCaseInsensitiveLogicalScan() {
        let document = makeDocument("Foo foo FOO\n")
        document.replace(0..<0, with: Array("fOo ".utf8))

        XCTAssertEqual(offsets(of: "foo", in: document, caseSensitive: false),
                       [0, 4, 8, 12])
    }

    func testFuzzAgainstNaiveSearchOverEditedContent() {
        for seed: UInt64 in [61, 6161] {
            var generator = SeededGenerator(seed: seed)
            let alphabet: [UInt8] = Array("abcab\n".utf8)
            var model = (0..<900).map { _ in
                alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
            }
            let document = makeDocument(String(decoding: model, as: UTF8.self))

            for _ in 0..<25 {
                let lower = Int.random(in: 0...model.count, using: &generator)
                let upper = Int.random(in: lower...min(model.count, lower + 40), using: &generator)
                let insert = (0..<Int.random(in: 0...20, using: &generator)).map { _ in
                    alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
                }
                document.replace(lower..<upper, with: insert)
                model.replaceSubrange(lower..<upper, with: insert)
            }

            for query in ["ab", "cab", "abcab", "bb"] {
                let expected = naiveOffsets(of: Array(query.utf8), in: model)
                for window in [13, 257] {
                    XCTAssertEqual(offsets(of: query, in: document, window: window),
                                   expected, "seed \(seed) query \(query) window \(window)")
                }
            }
        }
    }
}

final class SearchScanTests: XCTestCase {

    func testCaseSensitiveMatchesArePreciseAndNonOverlapping() {
        let content = "foofoo foo bar Foo"   // "Foo" should NOT match in case-sensitive mode.
        let url = TestHelpers.writeTempFile(content)
        defer { TestHelpers.remove(url) }
        let file = MappedFile(path: url.path)!
        let scan = SearchScan(query: "foo", caseSensitive: true)!
        scan.runSynchronously(in: file)
        XCTAssertEqual(scan.matchCount, 3)
        XCTAssertEqual(scan.matchOffset(at: 0), 0)
        XCTAssertEqual(scan.matchOffset(at: 1), 3)   // Non-overlapping: next match starts after the first.
        XCTAssertEqual(scan.matchOffset(at: 2), 7)
    }

    func testCaseInsensitiveMatchesAdditionalCases() {
        let content = "foofoo foo bar Foo FOO"
        let url = TestHelpers.writeTempFile(content)
        defer { TestHelpers.remove(url) }
        let file = MappedFile(path: url.path)!
        let scan = SearchScan(query: "foo", caseSensitive: false)!
        scan.runSynchronously(in: file)
        XCTAssertEqual(scan.matchCount, 5)
        XCTAssertEqual(scan.matchOffset(at: 3), 15)  // "Foo"
        XCTAssertEqual(scan.matchOffset(at: 4), 19)  // "FOO"
    }

    func testNoMatchesReturnsZero() {
        let content = "the quick brown fox"
        let url = TestHelpers.writeTempFile(content)
        defer { TestHelpers.remove(url) }
        let file = MappedFile(path: url.path)!
        let scan = SearchScan(query: "zzz", caseSensitive: true)!
        scan.runSynchronously(in: file)
        XCTAssertEqual(scan.matchCount, 0)
        XCTAssertTrue(scan.isComplete)
    }

    func testEmptyQueryFailsInit() {
        XCTAssertNil(SearchScan(query: ""))
    }
}
