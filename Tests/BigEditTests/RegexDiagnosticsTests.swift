import XCTest
@testable import BigEdit

/// The find bar explains a broken pattern in words rather than refusing it.
final class RegexDiagnosticsTests: XCTestCase {

    func testAValidPatternHasNoProblem() {
        XCTAssertNil(RegexDiagnostics.problem(in: "[a-z]+(\\d{2,4})?"))
        XCTAssertNil(RegexDiagnostics.problem(in: ""))
        XCTAssertNil(RegexDiagnostics.problem(in: "\\(\\)"))
    }

    func testUnclosedGroup() {
        XCTAssertEqual(RegexDiagnostics.problem(in: "(ab"), "Unclosed “(” group")
        XCTAssertEqual(RegexDiagnostics.problem(in: "((ab"), "2 unclosed “(” groups")
    }

    func testUnmatchedClosingParenthesis() {
        XCTAssertEqual(RegexDiagnostics.problem(in: "ab)"), "Unmatched “)” at position 3")
    }

    func testUnclosedCharacterClass() {
        XCTAssertEqual(RegexDiagnostics.problem(in: "[abc"), "Unclosed “[” character class")
    }

    func testNothingToRepeat() {
        XCTAssertEqual(RegexDiagnostics.problem(in: "*a"), "Nothing to repeat before “*” at position 1")
        XCTAssertEqual(RegexDiagnostics.problem(in: "a|+"), "Nothing to repeat before “+” at position 3")
    }

    func testTrailingBackslash() {
        XCTAssertEqual(RegexDiagnostics.problem(in: "abc\\"), "A backslash at the end has nothing to escape")
    }

    func testBracesTheWrongWayRound() {
        XCTAssertEqual(RegexDiagnostics.problem(in: "a{5,2}"), "“{5,2}” has its bounds the wrong way round")
    }

    func testAnythingElseIsStillReported() {
        XCTAssertEqual(RegexDiagnostics.problem(in: "\\p{NoSuchProperty}"), "Invalid pattern")
    }

    // MARK: - Replacement preview

    func testExpansionSubstitutesGroups() {
        XCTAssertEqual(ReplacementPreview.expansion(of: "$2-$1", for: "ab", pattern: "(a)(b)", options: []),
                       "b-a")
        XCTAssertEqual(ReplacementPreview.expansion(of: "<$0>", for: "x", pattern: "x", options: []), "<x>")
    }

    func testExpansionNeedsTheWholeTextToMatch() {
        XCTAssertNil(ReplacementPreview.expansion(of: "y", for: "xa", pattern: "x", options: []))
        XCTAssertNil(ReplacementPreview.expansion(of: "y", for: "x", pattern: "(", options: []))
    }
}
