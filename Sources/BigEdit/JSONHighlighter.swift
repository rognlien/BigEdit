import AppKit

/// A small, stateless JSON syntax highlighter. Like the XML one it colours
/// one row at a time with no carried context; a string or block comment that
/// spans multiple rows is only coloured on the row where it begins.
///
/// Recognises strings (keys and values are coloured differently), numbers,
/// the literals `true` / `false` / `null`, structural punctuation, and `//`
/// or `/* */` comments (a JSONC convenience).
enum JSONHighlighter {

    private static let stringColor = NSColor.systemRed
    private static let keyColor = NSColor.systemBlue
    private static let numberColor = NSColor.systemPurple
    private static let literalColor = NSColor.systemTeal
    private static let commentColor = NSColor.systemGreen
    private static let punctuationColor = NSColor.secondaryLabelColor

    private static let openBrace = unichar(UInt8(ascii: "{"))
    private static let closeBrace = unichar(UInt8(ascii: "}"))
    private static let openBracket = unichar(UInt8(ascii: "["))
    private static let closeBracket = unichar(UInt8(ascii: "]"))
    private static let comma = unichar(UInt8(ascii: ","))
    private static let colon = unichar(UInt8(ascii: ":"))
    private static let quote = unichar(UInt8(ascii: "\""))
    private static let minus = unichar(UInt8(ascii: "-"))
    private static let slash = unichar(UInt8(ascii: "/"))
    private static let star = unichar(UInt8(ascii: "*"))

    private static let literals = ["true", "false", "null"]

    /// Stateful entry: when `startState` is `.blockComment` the row begins inside
    /// a `/* */` comment. Returns the row's colouring and the state at its end.
    static func attributedRow(_ text: String, font: NSFont,
                              startState: HighlightState) -> (NSAttributedString, HighlightState) {
        if startState == .blockComment {
            let scanner = RowScanner(text)
            let result = NSMutableAttributedString.plainRow(text, font: font)
            if let closeEnd = scanner.indexAfter("*/", from: 0) {
                result.setColor(commentColor, in: 0..<closeEnd)
                let rest = scanner.source.substring(from: closeEnd)
                let restAttr = attributedRow(rest, font: font)
                result.replaceCharacters(
                    in: NSRange(location: closeEnd, length: scanner.length - closeEnd),
                    with: restAttr)
                return (result, endState(rest, start: .normal))
            }
            result.setColor(commentColor, in: 0..<scanner.length)
            return (result, .blockComment)
        }
        return (attributedRow(text, font: font), endState(text, start: .normal))
    }

    /// Computes the comment state at the end of `text`, given the state at its
    /// start. Mirrors the comment/string handling in `attributedRow`.
    static func endState(_ text: String, start: HighlightState) -> HighlightState {
        let scanner = RowScanner(text)
        let length = scanner.length
        var index = 0
        if start == .blockComment {
            guard let closeEnd = scanner.indexAfter("*/", from: 0) else { return .blockComment }
            index = closeEnd
        }
        while index < length {
            let character = scanner.character(at: index)
            if character == quote {
                index = scanner.endOfQuotedString(from: index, quote: quote, escaping: true)
            } else if character == slash && index + 1 < length {
                let next = scanner.character(at: index + 1)
                if next == slash { return .normal }            // // comment to end of row
                if next == star {
                    guard let closeEnd = scanner.indexAfter("*/", from: index + 2) else {
                        return .blockComment
                    }
                    index = closeEnd
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return .normal
    }

    static func attributedRow(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString.plainRow(text, font: font)
        let scanner = RowScanner(text)
        var index = 0
        while index < scanner.length {
            let character = scanner.character(at: index)
            if character == quote {
                index = colorString(scanner, from: index, into: result)
            } else if isPunctuation(character) {
                result.setColor(punctuationColor, in: index..<(index + 1))
                index += 1
            } else if character == slash {
                index = colorComment(scanner, from: index, into: result)
            } else if character == minus || RowScanner.isDigit(character) {
                index = colorNumber(scanner, from: index, into: result)
            } else if RowScanner.isLowercaseLetter(character) {
                index = colorLiteralKeyword(scanner, from: index, into: result)
            } else {
                index += 1
            }
        }
        return result
    }

    /// Colours a `"..."` string. The string is coloured as a *key* when it is
    /// immediately followed (after whitespace) by `:`, otherwise as a value.
    private static func colorString(
        _ scanner: RowScanner,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let stringEnd = scanner.endOfQuotedString(from: start, quote: quote, escaping: true)
        let lookahead = scanner.skipWhitespace(from: stringEnd)
        let isKey = scanner.has(colon, at: lookahead)
        result.setColor(isKey ? keyColor : stringColor, in: start..<stringEnd)
        return stringEnd
    }

    /// Colours a `//` or `/* */` comment; a lone `/` is left as plain text.
    private static func colorComment(
        _ scanner: RowScanner,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = scanner.length
        if start + 1 < length {
            let next = scanner.character(at: start + 1)
            if next == slash {
                result.setColor(commentColor, in: start..<length)
                return length
            }
            if next == star {
                let end = scanner.indexAfter("*/", from: start + 2) ?? length
                result.setColor(commentColor, in: start..<end)
                return end
            }
        }
        return start + 1
    }

    /// Colours a numeric literal — a permissive sweep that accepts digits,
    /// `.`, `e`/`E`, and signs. Visually right for valid JSON, slightly loose
    /// on malformed input (acceptable for a highlighter).
    private static func colorNumber(
        _ scanner: RowScanner,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let end = scanner.endOfNumber(from: start)
        if end > start {
            result.setColor(numberColor, in: start..<end)
            return end
        }
        return start + 1
    }

    /// Colours `true` / `false` / `null` when the run is not part of a longer
    /// identifier (so `truer` would not be coloured).
    private static func colorLiteralKeyword(
        _ scanner: RowScanner,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let boundary: (unichar) -> Bool = { !RowScanner.isIdentifierCharacter($0) }
        if let end = scanner.endOfLiteral(in: literals, at: start, isBoundary: boundary) {
            result.setColor(literalColor, in: start..<end)
            return end
        }
        return start + 1
    }

    // MARK: - Helpers

    private static func isPunctuation(_ character: unichar) -> Bool {
        return character == openBrace || character == closeBrace
            || character == openBracket || character == closeBracket
            || character == comma || character == colon
    }
}
