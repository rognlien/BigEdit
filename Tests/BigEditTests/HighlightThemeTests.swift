import AppKit
import XCTest
@testable import BigEdit

final class HighlightThemeTests: XCTestCase {

    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let theme = HighlightTheme.standard

    func testStylingPreservesTheExactString() {
        // Colouring is layered as attributes, never by changing glyphs.
        let text = "# Heading **bold** ~~gone~~"
        let result = theme.attributedRow(text, tokens: MarkdownHighlighter.tokens(text), font: font)
        XCTAssertEqual(result.string, text)
    }

    func testUnstyledTextKeepsTheDefaultColour() {
        let result = theme.attributedRow("plain", tokens: [], font: font)
        let color = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, NSColor.textColor)
        XCTAssertEqual(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
    }

    func testLaterTokenOverridesOnlyTheAttributesItSets() {
        let tokens = [Token(kind: .heading, range: 0..<7), Token(kind: .punctuation, range: 0..<1)]
        let result = theme.attributedRow("# Title", tokens: tokens, font: font)
        let markerColor = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let markerFont = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let titleColor = result.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
        XCTAssertEqual(markerColor, theme.style(for: .punctuation).color)
        XCTAssertEqual(titleColor, theme.style(for: .heading).color)
        XCTAssertNotEqual(markerColor, titleColor)
        XCTAssertTrue(markerFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testStrikethroughIsADecorationNotAColour() {
        let result = theme.attributedRow("ab", tokens: [Token(kind: .strikethrough, range: 0..<2)], font: font)
        let style = result.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int
        let color = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(style, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(color, NSColor.textColor)
    }
}
