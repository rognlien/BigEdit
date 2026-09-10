import XCTest
@testable import BigEdit

final class HighlighterTests: XCTestCase {

    private let inputs = [
        "<element attr=\"value\">text</element>",
        "{ \"key\": \"value\", \"n\": 42 }",
        "# Heading **bold** *italic* `code`",
        "key: value # comment"
    ]

    func testTokensStayInsideTheRow() {
        for input in inputs {
            let length = (input as NSString).length
            let all = XMLHighlighter.tokens(input) + JSONHighlighter.tokens(input)
                + MarkdownHighlighter.tokens(input) + YAMLHighlighter.tokens(input)
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
}
