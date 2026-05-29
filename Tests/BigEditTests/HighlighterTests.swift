import AppKit
import XCTest
@testable import BigEdit

final class HighlighterTests: XCTestCase {

    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func testHighlightersPreserveExactString() {
        // The attributed string a highlighter returns must contain the exact
        // input — colouring is layered as attributes, not by changing glyphs.
        let inputs = [
            "<element attr=\"value\">text</element>",
            "{ \"key\": \"value\", \"n\": 42 }",
            "# Heading\n**bold** *italic* `code`",
            "key: value\n- item\n# comment\n"
        ]
        for input in inputs {
            XCTAssertEqual(XMLHighlighter.attributedRow(input, font: font).string, input)
            XCTAssertEqual(JSONHighlighter.attributedRow(input, font: font).string, input)
            XCTAssertEqual(MarkdownHighlighter.attributedRow(input, font: font).string, input)
            XCTAssertEqual(YAMLHighlighter.attributedRow(input, font: font).string, input)
        }
    }

    func testXMLTagNameIsColoured() {
        let result = XMLHighlighter.attributedRow("<book>", font: font)
        // The "book" range (1..<5) should have a foreground colour applied.
        var hasColor = false
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 1, length: 4)) { value, _, _ in
            if value != nil { hasColor = true }
        }
        XCTAssertTrue(hasColor)
    }

    func testJSONKeyAndValueGetDifferentColours() {
        let source = "\"k\":\"v\""
        let result = JSONHighlighter.attributedRow(source, font: font)
        let keyAttr = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let valueAttr = result.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(keyAttr)
        XCTAssertNotNil(valueAttr)
        XCTAssertNotEqual(keyAttr, valueAttr)
    }
}
