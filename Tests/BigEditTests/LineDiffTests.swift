import XCTest
@testable import BigEdit

/// The sequence diff must describe a way to turn the first document into
/// the second, prefer the obvious alignment, and write hunks the way
/// `diff -u` does.
final class LineDiffTests: XCTestCase {

    private func diff(_ first: [String], _ second: [String]) throws -> [LineDiff.Edit] {
        try XCTUnwrap(LineDiff.diff(first, second))
    }

    /// Replays `edits` over `first` and returns the document they produce.
    private func patched(_ first: [String], _ second: [String], _ edits: [LineDiff.Edit]) -> [String] {
        var result: [String] = []
        var firstCursor = 0
        for edit in edits {
            switch edit {
            case .equal(let f, let s, let count):
                XCTAssertEqual(f, firstCursor, "equal run out of order")
                XCTAssertEqual(Array(first[f..<(f + count)]), Array(second[s..<(s + count)]))
                result.append(contentsOf: first[f..<(f + count)])
                firstCursor = f + count
            case .delete(let f, let count):
                XCTAssertEqual(f, firstCursor, "delete out of order")
                firstCursor = f + count
            case .insert(let s, let count):
                result.append(contentsOf: second[s..<(s + count)])
            }
        }
        XCTAssertEqual(firstCursor, first.count, "the script must consume the first document")
        return result
    }

    func testIdenticalDocumentsAreOneEqualRun() throws {
        XCTAssertEqual(try diff(["a", "b"], ["a", "b"]), [.equal(first: 0, second: 0, count: 2)])
        XCTAssertEqual(try diff([], []), [])
    }

    func testInsertionsAndDeletionsAtTheEdges() throws {
        XCTAssertEqual(try diff(["a"], ["x", "a"]),
                       [.insert(second: 0, count: 1), .equal(first: 0, second: 1, count: 1)])
        XCTAssertEqual(try diff(["a", "x"], ["a"]),
                       [.equal(first: 0, second: 0, count: 1), .delete(first: 1, count: 1)])
        XCTAssertEqual(try diff([], ["a", "b"]), [.insert(second: 0, count: 2)])
        XCTAssertEqual(try diff(["a", "b"], []), [.delete(first: 0, count: 2)])
    }

    func testAChangedLineIsADeleteAndAnInsert() throws {
        let edits = try diff(["a", "b", "c"], ["a", "B", "c"])
        XCTAssertEqual(edits, [
            .equal(first: 0, second: 0, count: 1),
            .delete(first: 1, count: 1),
            .insert(second: 1, count: 1),
            .equal(first: 2, second: 2, count: 1)
        ])
    }

    func testUniqueLinesAnchorTheAlignment() throws {
        let first = ["x", "x", "anchor", "x", "y"]
        let second = ["y", "x", "anchor", "x", "x"]
        let edits = try diff(first, second)
        XCTAssertEqual(patched(first, second, edits), second)
        let anchored = edits.contains { edit in
            if case .equal(let first, let second, let count) = edit {
                return (first..<(first + count)).contains(2) && second - first == 0
            }
            return false
        }
        XCTAssertTrue(anchored, "the unique line lines up with itself")
    }

    func testScriptAlwaysReproducesTheSecondDocument() throws {
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<200 {
            let first = (0..<Int.random(in: 0..<40, using: &generator)).map { _ in
                String(Int.random(in: 0..<6, using: &generator))
            }
            var second = first
            for _ in 0..<Int.random(in: 0..<10, using: &generator) {
                if !second.isEmpty && Bool.random(using: &generator) {
                    second.remove(at: Int.random(in: 0..<second.count, using: &generator))
                } else {
                    second.insert(String(Int.random(in: 0..<6, using: &generator)),
                                  at: Int.random(in: 0...second.count, using: &generator))
                }
            }
            let edits = try diff(first, second)
            XCTAssertEqual(patched(first, second, edits), second)
        }
    }

    func testRunsAreMergedAndNeverEmpty() throws {
        let first = ["a", "b", "c", "d"]
        let second = ["a", "c", "d", "e", "f"]
        let edits = try diff(first, second)
        XCTAssertEqual(edits, [
            .equal(first: 0, second: 0, count: 1),
            .delete(first: 1, count: 1),
            .equal(first: 2, second: 1, count: 2),
            .insert(second: 3, count: 2)
        ])
    }

    func testALargeGapWithNoAnchorsIsAReplacement() throws {
        let first = (0..<3000).map { _ in "same" }
        let second = (0..<3000).map { _ in "other" }
        let edits = try diff(first, second)
        XCTAssertEqual(edits, [.delete(first: 0, count: 3000), .insert(second: 0, count: 3000)])
    }

    func testCancellationReturnsNil() {
        XCTAssertNil(LineDiff.diff(["a"], ["b"], isCancelled: { true }))
    }

    // MARK: - Unified format

    func testUnifiedDiffMatchesDiffU() throws {
        let first = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
        let second = ["one", "two", "three", "FOUR", "five", "six", "seven", "eight"]
        let text = LineDiff.unified(try diff(first, second), first: first, second: second,
                                    firstName: "a.txt", secondName: "b.txt")
        XCTAssertEqual(text, """
            --- a.txt
            +++ b.txt
            @@ -1,7 +1,7 @@
             one
             two
             three
            -four
            +FOUR
             five
             six
             seven

            """)
    }

    func testFarApartChangesGetTheirOwnHunks() throws {
        let first = (1...20).map { "line \($0)" }
        var second = first
        second[0] = "LINE 1"
        second[19] = "LINE 20"
        let hunks = LineDiff.hunks(try diff(first, second), first: first, second: second, context: 3)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].header, "@@ -1,4 +1,4 @@")
        XCTAssertEqual(hunks[1].header, "@@ -17,4 +17,4 @@")
        XCTAssertEqual(hunks[1].lines, [" line 17", " line 18", " line 19", "-line 20", "+LINE 20"])
    }

    func testNearbyChangesShareAHunk() throws {
        let first = (1...12).map { "line \($0)" }
        var second = first
        second[2] = "LINE 3"
        second[8] = "LINE 9"
        let hunks = LineDiff.hunks(try diff(first, second), first: first, second: second, context: 3)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].header, "@@ -1,12 +1,12 @@")
    }

    func testInsertionIntoAnEmptyDocumentIsWrittenLikeDiffDoes() throws {
        let hunks = LineDiff.hunks(try diff([], ["a"]), first: [], second: ["a"], context: 3)
        XCTAssertEqual(hunks.map(\.header), ["@@ -0,0 +1 @@"])
        XCTAssertEqual(hunks[0].lines, ["+a"])
    }
}
