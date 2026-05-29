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
}
