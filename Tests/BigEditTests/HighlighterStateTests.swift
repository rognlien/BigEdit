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

    // MARK: Shell strings and here-documents

    func testShellStringsCarryAcrossRows() {
        XCTAssertEqual(ShellHighlighter.endState("echo 'multi", start: .normal), .singleQuotedString)
        XCTAssertEqual(ShellHighlighter.endState("still \" inside", start: .singleQuotedString),
                       .singleQuotedString)
        XCTAssertEqual(ShellHighlighter.endState("end' # x", start: .singleQuotedString), .normal)
        XCTAssertEqual(ShellHighlighter.endState("echo \"a \\\"", start: .normal), .doubleQuotedString)
        XCTAssertEqual(ShellHighlighter.endState("b\"", start: .doubleQuotedString), .normal)
    }

    func testShellHereDocumentRunsToItsDelimiter() {
        let open = HighlightState.hereDocument(delimiter: "EOF", stripsTabs: false, expands: true)
        XCTAssertEqual(ShellHighlighter.endState("cat <<EOF > out", start: .normal), open)
        XCTAssertEqual(ShellHighlighter.endState("echo \"not code", start: open), open)
        XCTAssertEqual(ShellHighlighter.endState(" EOF", start: open), open)
        XCTAssertEqual(ShellHighlighter.endState("EOF", start: open), .normal)
    }

    func testShellQuotedHereDocumentDoesNotExpand() {
        let open = HighlightState.hereDocument(delimiter: "END", stripsTabs: true, expands: false)
        XCTAssertEqual(ShellHighlighter.endState("cat <<-'END'", start: .normal), open)
        XCTAssertEqual(ShellHighlighter.tokens("\t$HOME", startState: open).0,
                       [Token(kind: .string, range: 0..<6)])
        XCTAssertEqual(ShellHighlighter.endState("\t\tEND", start: open), .normal)
    }

    func testShellHereDocumentExpandsParameters() {
        let open = HighlightState.hereDocument(delimiter: "EOF", stripsTabs: false, expands: true)
        XCTAssertEqual(ShellHighlighter.tokens("home: $HOME", startState: open).0, [
            Token(kind: .string, range: 0..<11),
            Token(kind: .variable, range: 6..<11)
        ])
    }

    func testShellHereStringIsNotAHereDocument() {
        XCTAssertEqual(ShellHighlighter.endState("cat <<< \"$x\"", start: .normal), .normal)
    }

    // MARK: SQL comments, strings and dollar-quoted bodies

    func testSQLBlockCommentCarriesAcrossRows() {
        XCTAssertEqual(SQLHighlighter.endState("SELECT 1; /* start", start: .normal), .blockComment)
        XCTAssertEqual(SQLHighlighter.endState("-- not a close */", start: .blockComment), .normal)
        XCTAssertEqual(SQLHighlighter.endState("'*/' still", start: .blockComment), .singleQuotedString)
    }

    func testSQLStringCarriesAcrossRows() {
        XCTAssertEqual(SQLHighlighter.endState("VALUES ('line one", start: .normal), .singleQuotedString)
        XCTAssertEqual(SQLHighlighter.endState("it''s -- inside", start: .singleQuotedString),
                       .singleQuotedString)
        XCTAssertEqual(SQLHighlighter.endState("end'); -- x", start: .singleQuotedString), .normal)
        XCTAssertEqual(SQLHighlighter.endState("'a\\' b'", start: .normal), .normal)
    }

    func testSQLDollarQuotedBodyRunsToItsDelimiter() {
        let open = HighlightState.dollarQuotedString(delimiter: "$body$")
        XCTAssertEqual(SQLHighlighter.endState("AS $body$", start: .normal), open)
        XCTAssertEqual(SQLHighlighter.endState("SELECT 'x $$ y", start: open), open)
        XCTAssertEqual(SQLHighlighter.tokens("$body$ LANGUAGE sql;", startState: open).0, [
            Token(kind: .string, range: 0..<6),
            Token(kind: .keyword, range: 7..<15),
            Token(kind: .punctuation, range: 19..<20)
        ])
        XCTAssertEqual(SQLHighlighter.endState("AS $$ SELECT 1 $$;", start: .normal), .normal)
    }
}
