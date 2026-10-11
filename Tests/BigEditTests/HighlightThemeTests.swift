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

    func testEveryColourIsReadableInLightAndDark() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            let background = resolved(.textBackgroundColor, in: appearance)
            for (kind, style) in theme.styles {
                if let color = style.color {
                    let contrast = contrastRatio(resolved(color, in: appearance), background)
                    XCTAssertGreaterThanOrEqual(contrast, 4.5, "\(kind) in \(name.rawValue)")
                }
            }
        }
    }

    func testColoursDifferBetweenLightAndDark() {
        let light = resolved(SyntaxColor.string, in: NSAppearance(named: .aqua)!)
        let dark = resolved(SyntaxColor.string, in: NSAppearance(named: .darkAqua)!)
        XCTAssertNotEqual(light, dark)
    }

    private func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    /// The WCAG contrast ratio between two opaque sRGB colours.
    private func contrastRatio(_ first: NSColor, _ second: NSColor) -> Double {
        let luminances = [first, second].map(relativeLuminance).sorted(by: >)
        return (luminances[0] + 0.05) / (luminances[1] + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> Double {
        let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { value in
            let channel = Double(value)
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
