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

    private static let space = RowScanner.space
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

    /// Stateful entry: when `startState` is `.fencedCode` the row is inside a
    /// ``` / ~~~ code block. Returns the colouring and the state at the end.
    static func attributedRow(_ text: String, font: NSFont,
                              startState: HighlightState) -> (NSAttributedString, HighlightState) {
        if startState == .fencedCode {
            let scanner = RowScanner(text)
            let result = NSMutableAttributedString.plainRow(text, font: font)
            if isFenceLine(scanner) {
                result.setColor(punctuationColor, in: 0..<scanner.length)   // closing fence
                return (result, .normal)
            }
            result.setColor(codeColor, in: 0..<scanner.length)
            return (result, .fencedCode)
        }
        return (attributedRow(text, font: font), endState(text, start: .normal))
    }

    /// Computes the fenced-code state at the end of `text` (line-based).
    static func endState(_ text: String, start: HighlightState) -> HighlightState {
        let fence = isFenceLine(RowScanner(text))
        if start == .fencedCode {
            return fence ? .normal : .fencedCode
        }
        return fence ? .fencedCode : .normal
    }

    /// True if the line is a code-fence marker: up to 3 leading spaces then at
    /// least three backticks or tildes.
    private static func isFenceLine(_ scanner: RowScanner) -> Bool {
        let indent = scanner.leadingSpaceCount
        var result = false
        if indent <= 3 && indent + 3 <= scanner.length {
            let marker = scanner.character(at: indent)
            if marker == backtick || marker == tilde {
                let markerEnd = scanner.endOfRun(from: indent) { $0 == marker }
                result = markerEnd - indent >= 3
            }
        }
        return result
    }

    static func attributedRow(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString.plainRow(text, font: font)
        let scanner = RowScanner(text)

        // Whole-line constructs first. Each returns true if it claimed the row.
        if colorHeading(scanner, font: font, into: result) { return result }
        if colorHorizontalRule(scanner, into: result) { return result }
        if colorFence(scanner, into: result) { return result }

        // Line prefixes that don't preempt inline scanning.
        colorBlockquote(scanner, into: result)
        colorListMarker(scanner, into: result)

        // Inline tokens.
        colorInline(scanner, font: font, into: result)
        return result
    }

    // MARK: - Block-level

    private static func colorHeading(
        _ scanner: RowScanner,
        font: NSFont,
        into result: NSMutableAttributedString
    ) -> Bool {
        let length = scanner.length
        let indent = scanner.leadingSpaceCount
        if indent > 3 || indent >= length {
            return false
        }
        let hashEnd = scanner.endOfRun(from: indent) { $0 == hash }
        let hashCount = hashEnd - indent
        if hashCount < 1 || hashCount > 6 {
            return false
        }
        if hashEnd < length && scanner.character(at: hashEnd) != space {
            return false
        }
        result.setColor(headingColor, in: indent..<length)
        result.setFont(boldFont(from: font), in: indent..<length)
        result.setColor(punctuationColor, in: indent..<hashEnd)
        return true
    }

    private static func colorHorizontalRule(
        _ scanner: RowScanner,
        into result: NSMutableAttributedString
    ) -> Bool {
        let length = scanner.length
        let indent = scanner.leadingSpaceCount
        if indent > 3 || indent >= length {
            return false
        }
        let marker = scanner.character(at: indent)
        if marker != dash && marker != star && marker != underscore {
            return false
        }
        var count = 0
        var index = indent
        while index < length {
            let character = scanner.character(at: index)
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
        result.setColor(punctuationColor, in: 0..<length)
        return true
    }

    private static func colorFence(
        _ scanner: RowScanner,
        into result: NSMutableAttributedString
    ) -> Bool {
        let isFence = isFenceLine(scanner)
        if isFence {
            result.setColor(punctuationColor, in: 0..<scanner.length)
        }
        return isFence
    }

    private static func colorBlockquote(
        _ scanner: RowScanner,
        into result: NSMutableAttributedString
    ) {
        let length = scanner.length
        let indent = scanner.leadingSpaceCount
        if indent > 3 || indent >= length {
            return
        }
        if scanner.character(at: indent) != greaterThan {
            return
        }
        result.setColor(mutedColor, in: indent..<length)
    }

    private static func colorListMarker(
        _ scanner: RowScanner,
        into result: NSMutableAttributedString
    ) {
        let indent = scanner.leadingSpaceCount
        if indent >= scanner.length {
            return
        }
        let firstChar = scanner.character(at: indent)
        // Bullet markers — `-`, `*`, `+` followed by space.
        if firstChar == dash || firstChar == star || firstChar == plus {
            if scanner.has(space, at: indent + 1) {
                result.setColor(punctuationColor, in: indent..<(indent + 1))
            }
            return
        }
        // Ordered list — digits followed by `.` or `)` then space.
        if RowScanner.isDigit(firstChar) {
            let endIndex = scanner.endOfRun(from: indent, while: RowScanner.isDigit)
            let terminator = scanner.character(at: endIndex)
            if terminator == dot || terminator == closeParen {
                if scanner.has(space, at: endIndex + 1) {
                    result.setColor(punctuationColor, in: indent..<(endIndex + 1))
                }
            }
        }
    }

    // MARK: - Inline

    private static func colorInline(
        _ scanner: RowScanner,
        font: NSFont,
        into result: NSMutableAttributedString
    ) {
        let length = scanner.length
        var index = 0
        while index < length {
            let character = scanner.character(at: index)
            if character == backtick {
                index = colorInlineCode(scanner, from: index, into: result)
            } else if character == star || character == underscore {
                index = colorEmphasis(scanner, from: index, marker: character, font: font, into: result)
            } else if character == openBracket {
                index = colorLink(scanner, from: index, into: result)
            } else if character == tilde {
                index = colorStrikethrough(scanner, from: index, into: result)
            } else {
                index += 1
            }
        }
    }

    private static func colorInlineCode(
        _ scanner: RowScanner,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let closeIndex = scanner.endOfRun(from: start + 1) { $0 != backtick }
        if closeIndex < scanner.length {
            result.setColor(codeColor, in: start..<(closeIndex + 1))
            return closeIndex + 1
        }
        return start + 1
    }

    /// Two markers in a row are treated as **bold**; a single marker as
    /// *italic*. Bold uses the font's bold variant; italic uses a colour.
    private static func colorEmphasis(
        _ scanner: RowScanner,
        from start: Int,
        marker: unichar,
        font: NSFont,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = scanner.length
        let isBold = scanner.has(marker, at: start + 1)
        let openLength = isBold ? 2 : 1
        var index = start + openLength

        while index < length {
            if scanner.character(at: index) == marker {
                if isBold {
                    if scanner.has(marker, at: index + 1) {
                        let end = index + 2
                        result.setFont(boldFont(from: font), in: start..<end)
                        result.setColor(punctuationColor, in: start..<(start + 2))
                        result.setColor(punctuationColor, in: index..<end)
                        return end
                    }
                } else {
                    let end = index + 1
                    result.setColor(italicColor, in: start..<end)
                    result.setColor(punctuationColor, in: start..<(start + 1))
                    result.setColor(punctuationColor, in: index..<end)
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
        _ scanner: RowScanner,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = scanner.length
        let bracketEnd = scanner.endOfRun(from: start + 1) { $0 != closeBracket }
        if bracketEnd >= length || !scanner.has(openParen, at: bracketEnd + 1) {
            return start + 1
        }
        let parenEnd = scanner.endOfRun(from: bracketEnd + 2) { $0 != closeParen }
        if parenEnd >= length {
            return start + 1
        }
        result.setColor(linkTextColor, in: (start + 1)..<bracketEnd)
        result.setColor(urlColor, in: (bracketEnd + 2)..<parenEnd)
        result.setColor(punctuationColor, in: start..<(start + 1))
        result.setColor(punctuationColor, in: bracketEnd..<(bracketEnd + 2))
        result.setColor(punctuationColor, in: parenEnd..<(parenEnd + 1))
        return parenEnd + 1
    }

    private static func colorStrikethrough(
        _ scanner: RowScanner,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = scanner.length
        if !scanner.has(tilde, at: start + 1) {
            return start + 1
        }
        var index = start + 2
        while index + 1 < length {
            if scanner.character(at: index) == tilde && scanner.character(at: index + 1) == tilde {
                let end = index + 2
                result.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: NSRange(location: start + 2, length: index - (start + 2))
                )
                result.setColor(punctuationColor, in: start..<(start + 2))
                result.setColor(punctuationColor, in: index..<end)
                return end
            }
            index += 1
        }
        return start + 2
    }

    // MARK: - Helpers

    private static func boldFont(from font: NSFont) -> NSFont {
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
}
