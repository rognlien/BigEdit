import XCTest
@testable import BigEdit

final class HighlighterTests: XCTestCase {

    private let inputs = [
        "<element attr=\"value\">text</element>",
        "{ \"key\": \"value\", \"n\": 42 }",
        "# Heading **bold** *italic* `code`",
        "key: value # comment",
        "for f in *.txt; do echo \"$f ${x:-1}\"; done # end",
        "cat <<",
        "echo $ \\",
        "x=$'unterminated"
    ]

    func testTokensStayInsideTheRow() {
        for input in inputs {
            let length = (input as NSString).length
            let all = XMLHighlighter.tokens(input) + JSONHighlighter.tokens(input)
                + MarkdownHighlighter.tokens(input) + YAMLHighlighter.tokens(input)
                + ShellHighlighter.tokens(input)
            for token in all {
                XCTAssertGreaterThanOrEqual(token.range.lowerBound, 0, "\(token) in \(input)")
                XCTAssertLessThanOrEqual(token.range.upperBound, length, "\(token) in \(input)")
                XCTAssertFalse(token.range.isEmpty, "\(token) in \(input)")
            }
        }
    }

    func testXMLTagAndAttributes() {
        XCTAssertEqual(XMLHighlighter.tokens("<book id='1'/>"), [
            Token(kind: .punctuation, range: 0..<1),
            Token(kind: .tag, range: 1..<5),
            Token(kind: .attributeName, range: 6..<8),
            Token(kind: .punctuation, range: 8..<9),
            Token(kind: .attributeValue, range: 9..<12),
            Token(kind: .punctuation, range: 12..<13),
            Token(kind: .punctuation, range: 13..<14)
        ])
    }

    func testJSONKeyAndValueAreToldApart() {
        XCTAssertEqual(JSONHighlighter.tokens("\"k\":\"v\""), [
            Token(kind: .key, range: 0..<3),
            Token(kind: .punctuation, range: 3..<4),
            Token(kind: .string, range: 4..<7)
        ])
    }

    func testMarkdownHeadingMarkersOverlapTheHeading() {
        XCTAssertEqual(MarkdownHighlighter.tokens("## Title"), [
            Token(kind: .heading, range: 0..<8),
            Token(kind: .punctuation, range: 0..<2)
        ])
    }

    func testYAMLKeyValueAndComment() {
        XCTAssertEqual(YAMLHighlighter.tokens("port: 8080 # default"), [
            Token(kind: .key, range: 0..<4),
            Token(kind: .punctuation, range: 4..<5),
            Token(kind: .number, range: 6..<10),
            Token(kind: .comment, range: 11..<20)
        ])
    }

    func testBlockCommentContinuationShiftsTheRestOfTheRow() {
        let (tokens, state) = JSONHighlighter.tokens("end */ 42", startState: .blockComment)
        XCTAssertEqual(tokens, [
            Token(kind: .comment, range: 0..<6),
            Token(kind: .number, range: 7..<9)
        ])
        XCTAssertEqual(state, .normal)
    }

    func testShellKeywordsVariablesAndComment() {
        XCTAssertEqual(ShellHighlighter.tokens("if [ -n \"$x\" ]; then exit 1; fi # done"), [
            Token(kind: .keyword, range: 0..<2),
            Token(kind: .string, range: 8..<12),
            Token(kind: .variable, range: 9..<11),
            Token(kind: .punctuation, range: 14..<15),
            Token(kind: .keyword, range: 16..<20),
            Token(kind: .keyword, range: 21..<25),
            Token(kind: .number, range: 26..<27),
            Token(kind: .punctuation, range: 27..<28),
            Token(kind: .keyword, range: 29..<31),
            Token(kind: .comment, range: 32..<38)
        ])
    }

    func testShellKeywordsOnlyWhereACommandStarts() {
        XCTAssertEqual(ShellHighlighter.tokens("echo if done"), [])
    }

    func testShellAssignmentAndExpansion() {
        XCTAssertEqual(ShellHighlighter.tokens("NAME=${1:-x} cmd"), [
            Token(kind: .variable, range: 0..<4),
            Token(kind: .variable, range: 5..<12)
        ])
    }

    func testShellFunctionDefinitions() {
        XCTAssertEqual(ShellHighlighter.tokens("build() {"), [
            Token(kind: .declaration, range: 0..<5),
            Token(kind: .punctuation, range: 5..<7),
            Token(kind: .punctuation, range: 8..<9)
        ])
        XCTAssertEqual(ShellHighlighter.tokens("function build {"), [
            Token(kind: .keyword, range: 0..<8),
            Token(kind: .declaration, range: 9..<14),
            Token(kind: .punctuation, range: 15..<16)
        ])
    }

    func testShellLoopVariableAndIn() {
        XCTAssertEqual(ShellHighlighter.tokens("for item in a b"), [
            Token(kind: .keyword, range: 0..<3),
            Token(kind: .variable, range: 4..<8),
            Token(kind: .keyword, range: 9..<11)
        ])
    }

    func testShellHashInsideAWordIsNotAComment() {
        XCTAssertEqual(ShellHighlighter.tokens("echo a#b ${#list}"), [
            Token(kind: .variable, range: 9..<17)
        ])
    }

    func testShellSingleQuotesDoNotExpand() {
        XCTAssertEqual(ShellHighlighter.tokens("echo '$HOME'"), [
            Token(kind: .string, range: 5..<12)
        ])
    }
}
