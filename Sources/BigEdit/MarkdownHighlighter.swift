import AppKit

/// A small, stateless Markdown syntax highlighter. Per-row tokenization with
/// no carried context — so a fenced code block colours its `\`\`\`` opener but
/// not the lines in between (those would need state).
///
/// Recognises headings, horizontal rules, fence markers, blockquote and list
/// prefixes, and the inline tokens: inline code, bold, italic, links, and
/// strikethrough. Bold uses the font's bold variant; italic uses a colour.
enum MarkdownHighlighter {

    private static let headingColor = NSColor.systemBlue
    private static let codeColor = NSColor.systemBrown
    private static let linkTextColor = NSColor.systemTeal
    private static let urlColor = NSColor.systemPurple
    private static let italicColor = NSColor.systemOrange
    private static let punctuationColor = NSColor.secondaryLabelColor
    private static let mutedColor = NSColor.secondaryLabelColor

    private static let space = unichar(UInt8(ascii: " "))
    private static let hash = unichar(UInt8(ascii: "#"))
    private static let star = unichar(UInt8(ascii: "*"))
    private static let underscore = unichar(UInt8(ascii: "_"))
    private static let backtick = unichar(UInt8(ascii: "`"))
    private static let tilde = unichar(UInt8(ascii: "~"))
    private static let openBracket = unichar(UInt8(ascii: "["))
    private static let closeBracket = unichar(UInt8(ascii: "]"))
    private static let openParen = unichar(UInt8(ascii: "("))
    private static let closeParen = unichar(UInt8(ascii: ")"))
    private static let greaterThan = unichar(UInt8(ascii: ">"))
    private static let dash = unichar(UInt8(ascii: "-"))
    private static let plus = unichar(UInt8(ascii: "+"))
    private static let dot = unichar(UInt8(ascii: "."))

    static func attributedRow(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.textColor]
        )
        let source = text as NSString

        // Whole-line constructs first. Each returns true if it claimed the row.
        if colorHeading(source, font: font, into: result) { return result }
        if colorHorizontalRule(source, into: result) { return result }
        if colorFence(source, into: result) { return result }

        // Line prefixes that don't preempt inline scanning.
        colorBlockquote(source, into: result)
        colorListMarker(source, into: result)

        // Inline tokens.
        colorInline(source, font: font, into: result)
        return result
    }

    // MARK: - Block-level

    private static func colorHeading(
        _ source: NSString,
        font: NSFont,
        into result: NSMutableAttributedString
    ) -> Bool {
        let length = source.length
        let indent = leadingSpaceCount(source)
        if indent > 3 || indent >= length {
            return false
        }
        var hashEnd = indent
        while hashEnd < length && source.character(at: hashEnd) == hash {
            hashEnd += 1
        }
        let hashCount = hashEnd - indent
        if hashCount < 1 || hashCount > 6 {
            return false
        }
        if hashEnd < length && source.character(at: hashEnd) != space {
            return false
        }
        apply(headingColor, indent..<length, result)
        apply(font: boldFont(from: font), indent..<length, result)
        apply(punctuationColor, indent..<hashEnd, result)
        return true
    }

    private static func colorHorizontalRule(
        _ source: NSString,
        into result: NSMutableAttributedString
    ) -> Bool {
        let length = source.length
        let indent = leadingSpaceCount(source)
        if indent > 3 || indent >= length {
            return false
        }
        let marker = source.character(at: indent)
        if marker != dash && marker != star && marker != underscore {
            return false
        }
        var count = 0
        var index = indent
        while index < length {
            let character = source.character(at: index)
            if character == marker {
                count += 1
            } else if character != space {
                return false
            }
            index += 1
        }
        if count < 3 {
            return false
        }
        apply(punctuationColor, 0..<length, result)
        return true
    }

    private static func colorFence(
        _ source: NSString,
        into result: NSMutableAttributedString
    ) -> Bool {
        let length = source.length
        let indent = leadingSpaceCount(source)
        if indent > 3 || indent + 3 > length {
            return false
        }
        let marker = source.character(at: indent)
        if marker != backtick && marker != tilde {
            return false
        }
        var index = indent
        while index < length && source.character(at: index) == marker {
            index += 1
        }
        if index - indent < 3 {
            return false
        }
        apply(punctuationColor, 0..<length, result)
        return true
    }

    private static func colorBlockquote(
        _ source: NSString,
        into result: NSMutableAttributedString
    ) {
        let length = source.length
        let indent = leadingSpaceCount(source)
        if indent > 3 || indent >= length {
            return
        }
        if source.character(at: indent) != greaterThan {
            return
        }
        apply(mutedColor, indent..<length, result)
    }

    private static func colorListMarker(
        _ source: NSString,
        into result: NSMutableAttributedString
    ) {
        let length = source.length
        let indent = leadingSpaceCount(source)
        if indent >= length {
            return
        }
        let firstChar = source.character(at: indent)
        // Bullet markers — `-`, `*`, `+` followed by space.
        if firstChar == dash || firstChar == star || firstChar == plus {
            if indent + 1 < length && source.character(at: indent + 1) == space {
                apply(punctuationColor, indent..<(indent + 1), result)
            }
            return
        }
        // Ordered list — digits followed by `.` or `)` then space.
        if firstChar >= 0x30 && firstChar <= 0x39 {
            var endIndex = indent
            while endIndex < length {
                let character = source.character(at: endIndex)
                if character >= 0x30 && character <= 0x39 {
                    endIndex += 1
                } else {
                    break
                }
            }
            let terminator: unichar? = endIndex < length ? source.character(at: endIndex) : nil
            if terminator == dot || terminator == closeParen {
                if endIndex + 1 < length && source.character(at: endIndex + 1) == space {
                    apply(punctuationColor, indent..<(endIndex + 1), result)
                }
            }
        }
    }

    // MARK: - Inline

    private static func colorInline(
        _ source: NSString,
        font: NSFont,
        into result: NSMutableAttributedString
    ) {
        let length = source.length
        var index = 0
        while index < length {
            let character = source.character(at: index)
            if character == backtick {
                index = colorInlineCode(source, from: index, into: result)
            } else if character == star || character == underscore {
                index = colorEmphasis(source, from: index, marker: character, font: font, into: result)
            } else if character == openBracket {
                index = colorLink(source, from: index, into: result)
            } else if character == tilde {
                index = colorStrikethrough(source, from: index, into: result)
            } else {
                index += 1
            }
        }
    }

    private static func colorInlineCode(
        _ source: NSString,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        var index = start + 1
        while index < length && source.character(at: index) != backtick {
            index += 1
        }
        if index < length {
            apply(codeColor, start..<(index + 1), result)
            return index + 1
        }
        return start + 1
    }

    /// Two markers in a row are treated as **bold**; a single marker as
    /// *italic*. Bold uses the font's bold variant; italic uses a colour.
    private static func colorEmphasis(
        _ source: NSString,
        from start: Int,
        marker: unichar,
        font: NSFont,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        let isBold = start + 1 < length && source.character(at: start + 1) == marker
        let openLength = isBold ? 2 : 1
        var index = start + openLength

        while index < length {
            if source.character(at: index) == marker {
                if isBold {
                    if index + 1 < length && source.character(at: index + 1) == marker {
                        let end = index + 2
                        apply(font: boldFont(from: font), start..<end, result)
                        apply(punctuationColor, start..<(start + 2), result)
                        apply(punctuationColor, index..<end, result)
                        return end
                    }
                } else {
                    let end = index + 1
                    apply(italicColor, start..<end, result)
                    apply(punctuationColor, start..<(start + 1), result)
                    apply(punctuationColor, index..<end, result)
                    return end
                }
            }
            index += 1
        }
        // No matching close on this row — advance past the open marker so the
        // outer loop makes progress.
        return start + openLength
    }

    private static func colorLink(
        _ source: NSString,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        var bracketEnd = start + 1
        while bracketEnd < length && source.character(at: bracketEnd) != closeBracket {
            bracketEnd += 1
        }
        if bracketEnd >= length
            || bracketEnd + 1 >= length
            || source.character(at: bracketEnd + 1) != openParen {
            return start + 1
        }
        var parenEnd = bracketEnd + 2
        while parenEnd < length && source.character(at: parenEnd) != closeParen {
            parenEnd += 1
        }
        if parenEnd >= length {
            return start + 1
        }
        apply(linkTextColor, (start + 1)..<bracketEnd, result)
        apply(urlColor, (bracketEnd + 2)..<parenEnd, result)
        apply(punctuationColor, start..<(start + 1), result)
        apply(punctuationColor, bracketEnd..<(bracketEnd + 2), result)
        apply(punctuationColor, parenEnd..<(parenEnd + 1), result)
        return parenEnd + 1
    }

    private static func colorStrikethrough(
        _ source: NSString,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        if start + 1 >= length || source.character(at: start + 1) != tilde {
            return start + 1
        }
        var index = start + 2
        while index + 1 < length {
            if source.character(at: index) == tilde && source.character(at: index + 1) == tilde {
                let end = index + 2
                result.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: NSRange(location: start + 2, length: index - (start + 2))
                )
                apply(punctuationColor, start..<(start + 2), result)
                apply(punctuationColor, index..<end, result)
                return end
            }
            index += 1
        }
        return start + 2
    }

    // MARK: - Helpers

    private static func leadingSpaceCount(_ source: NSString) -> Int {
        var index = 0
        while index < source.length && source.character(at: index) == space {
            index += 1
        }
        return index
    }

    private static func boldFont(from font: NSFont) -> NSFont {
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func apply(
        _ color: NSColor,
        _ range: Range<Int>,
        _ result: NSMutableAttributedString
    ) {
        if !range.isEmpty {
            result.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: range.lowerBound, length: range.count)
            )
        }
    }

    private static func apply(
        font: NSFont,
        _ range: Range<Int>,
        _ result: NSMutableAttributedString
    ) {
        if !range.isEmpty {
            result.addAttribute(
                .font,
                value: font,
                range: NSRange(location: range.lowerBound, length: range.count)
            )
        }
    }
}
