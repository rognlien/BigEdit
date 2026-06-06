import XCTest
@testable import BigEdit

/// The carried highlight state drives multi-row colouring, so the per-row
/// `endState` transitions need to be exact.
final class HighlighterStateTests: XCTestCase {

    // MARK: JSON / JSONC block comments

    func testJSONOpensAndStaysInBlockComment() {
        XCTAssertEqual(JSONHighlighter.endState("value, /* opening", start: .normal), .blockComment)
        XCTAssertEqual(JSONHighlighter.endState("still inside", start: .blockComment), .blockComment)
    }

    func testJSONClosesBlockComment() {
        XCTAssertEqual(JSONHighlighter.endState("closing */ {", start: .blockComment), .normal)
        XCTAssertEqual(JSONHighlighter.endState("/* whole */ thing", start: .normal), .normal)
    }

    func testJSONIgnoresCommentMarkersInStringsAndLineComments() {
        XCTAssertEqual(JSONHighlighter.endState("\"/* not a comment\"", start: .normal), .normal)
        XCTAssertEqual(JSONHighlighter.endState("x // /* trailing", start: .normal), .normal)
    }

    // MARK: XML comments

    func testXMLBlockComment() {
        XCTAssertEqual(XMLHighlighter.endState("<a/> <!-- start", start: .normal), .blockComment)
        XCTAssertEqual(XMLHighlighter.endState("end --> <b/>", start: .blockComment), .normal)
        XCTAssertEqual(XMLHighlighter.endState("<!-- a --> <!-- b", start: .normal), .blockComment)
    }

    // MARK: Markdown fenced code

    func testMarkdownFence() {
        XCTAssertEqual(MarkdownHighlighter.endState("```swift", start: .normal), .fencedCode)
        XCTAssertEqual(MarkdownHighlighter.endState("let x = 1", start: .fencedCode), .fencedCode)
        XCTAssertEqual(MarkdownHighlighter.endState("```", start: .fencedCode), .normal)
        XCTAssertEqual(MarkdownHighlighter.endState("plain text", start: .normal), .normal)
    }

    // MARK: YAML block scalars

    func testYAMLBlockScalarOpensByIndicator() {
        XCTAssertEqual(YAMLHighlighter.endState("notes: |", start: .normal), .blockScalar(indent: 0))
        XCTAssertEqual(YAMLHighlighter.endState("folded: >-", start: .normal), .blockScalar(indent: 0))
        XCTAssertEqual(YAMLHighlighter.endState("  child: |", start: .normal), .blockScalar(indent: 2))
    }

    func testYAMLBlockScalarContinuesAndExitsByIndent() {
        XCTAssertEqual(YAMLHighlighter.endState("    deeper text", start: .blockScalar(indent: 2)),
                       .blockScalar(indent: 2))
        XCTAssertEqual(YAMLHighlighter.endState("", start: .blockScalar(indent: 2)),
                       .blockScalar(indent: 2))   // blank lines stay in the scalar
        XCTAssertEqual(YAMLHighlighter.endState("  sibling: x", start: .blockScalar(indent: 2)),
                       .normal)
    }

    func testYAMLPlainValueDoesNotOpenScalar() {
        XCTAssertEqual(YAMLHighlighter.endState("url: http://example.com", start: .normal), .normal)
    }
}
