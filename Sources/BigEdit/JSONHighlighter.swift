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
    private static let backslash = unichar(UInt8(ascii: "\\"))
    private static let minus = unichar(UInt8(ascii: "-"))
    private static let slash = unichar(UInt8(ascii: "/"))
    private static let star = unichar(UInt8(ascii: "*"))

    /// Stateful entry: when `startState` is `.blockComment` the row begins inside
    /// a `/* */` comment. Returns the row's colouring and the state at its end.
    static func attributedRow(_ text: String, font: NSFont,
                              startState: HighlightState) -> (NSAttributedString, HighlightState) {
        if startState == .blockComment {
            let source = text as NSString
            let result = NSMutableAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
            if let closeEnd = indexAfter(source, of: "*/", from: 0) {
                apply(commentColor, 0..<closeEnd, result)
                let rest = source.substring(from: closeEnd)
                let restAttr = attributedRow(rest, font: font)
                result.replaceCharacters(
                    in: NSRange(location: closeEnd, length: source.length - closeEnd),
                    with: restAttr)
                return (result, endState(rest, start: .normal))
            }
            apply(commentColor, 0..<source.length, result)
            return (result, .blockComment)
        }
        return (attributedRow(text, font: font), endState(text, start: .normal))
    }

    /// Computes the comment state at the end of `text`, given the state at its
    /// start. Mirrors the comment/string handling in `attributedRow`.
    static func endState(_ text: String, start: HighlightState) -> HighlightState {
        let source = text as NSString
        let length = source.length
        var index = 0
        if start == .blockComment {
            guard let closeEnd = indexAfter(source, of: "*/", from: 0) else { return .blockComment }
            index = closeEnd
        }
        while index < length {
            let character = source.character(at: index)
            if character == quote {
                index += 1
                while index < length {
                    let inner = source.character(at: index)
                    if inner == backslash && index + 1 < length { index += 2; continue }
                    if inner == quote { index += 1; break }
                    index += 1
                }
            } else if character == slash && index + 1 < length {
                let next = source.character(at: index + 1)
                if next == slash { return .normal }            // // comment to end of row
                if next == star {
                    guard let closeEnd = indexAfter(source, of: "*/", from: index + 2) else {
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
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.textColor]
        )
        let source = text as NSString
        var index = 0
        while index < source.length {
            let character = source.character(at: index)
            if character == quote {
                index = colorString(source, from: index, into: result)
            } else if character == openBrace || character == closeBrace
                || character == openBracket || character == closeBracket
                || character == comma || character == colon {
                apply(punctuationColor, index..<(index + 1), result)
                index += 1
            } else if character == slash {
                index = colorComment(source, from: index, into: result)
            } else if character == minus || isDigit(character) {
                index = colorNumber(source, from: index, into: result)
            } else if isLowercaseLetter(character) {
                index = colorLiteralKeyword(source, from: index, into: result)
            } else {
                index += 1
            }
        }
        return result
    }

    /// Colours a `"..."` string. The string is coloured as a *key* when it is
    /// immediately followed (after whitespace) by `:`, otherwise as a value.
    private static func colorString(
        _ source: NSString,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        var index = start + 1
        while index < length {
            let character = source.character(at: index)
            if character == backslash && index + 1 < length {
                index += 2
                continue
            }
            if character == quote {
                index += 1
                break
            }
            index += 1
        }
        let stringEnd = index

        var lookahead = stringEnd
        while lookahead < length && isWhitespace(source.character(at: lookahead)) {
            lookahead += 1
        }
        let isKey = lookahead < length && source.character(at: lookahead) == colon
        apply(isKey ? keyColor : stringColor, start..<stringEnd, result)
        return stringEnd
    }

    /// Colours a `//` or `/* */` comment; a lone `/` is left as plain text.
    private static func colorComment(
        _ source: NSString,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        if start + 1 < length {
            let next = source.character(at: start + 1)
            if next == slash {
                apply(commentColor, start..<length, result)
                return length
            }
            if next == star {
                let end = indexAfter(source, of: "*/", from: start + 2) ?? length
                apply(commentColor, start..<end, result)
                return end
            }
        }
        return start + 1
    }

    /// Colours a numeric literal — a permissive sweep that accepts digits,
    /// `.`, `e`/`E`, and signs. Visually right for valid JSON, slightly loose
    /// on malformed input (acceptable for a highlighter).
    private static func colorNumber(
        _ source: NSString,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        var index = start
        if index < length && source.character(at: index) == minus {
            index += 1
        }
        while index < length {
            let character = source.character(at: index)
            let isExponent = character == 0x65 || character == 0x45    // e, E
            let isSign = character == 0x2B || character == 0x2D        // + -
            if isDigit(character) || character == 0x2E || isExponent || isSign {
                index += 1
            } else {
                break
            }
        }
        if index > start {
            apply(numberColor, start..<index, result)
            return index
        }
        return start + 1
    }

    /// Colours `true` / `false` / `null` when the run is not part of a longer
    /// identifier (so `truer` would not be coloured).
    private static func colorLiteralKeyword(
        _ source: NSString,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        for candidate in ["true", "false", "null"] {
            let candidateLength = candidate.count
            if start + candidateLength <= length {
                let range = NSRange(location: start, length: candidateLength)
                if source.substring(with: range) == candidate {
                    let afterIndex = start + candidateLength
                    if afterIndex >= length || !isIdentifierChar(source.character(at: afterIndex)) {
                        apply(literalColor, start..<afterIndex, result)
                        return afterIndex
                    }
                }
            }
        }
        return start + 1
    }

    // MARK: - Helpers

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

    private static func indexAfter(_ source: NSString, of literal: String, from: Int) -> Int? {
        var result: Int?
        if from <= source.length {
            let searchRange = NSRange(location: from, length: source.length - from)
            let found = source.range(of: literal, options: [], range: searchRange)
            if found.location != NSNotFound {
                result = found.location + found.length
            }
        }
        return result
    }

    private static func isDigit(_ character: unichar) -> Bool {
        return character >= 0x30 && character <= 0x39
    }

    private static func isLowercaseLetter(_ character: unichar) -> Bool {
        return character >= 0x61 && character <= 0x7A
    }

    private static func isIdentifierChar(_ character: unichar) -> Bool {
        return (character >= 0x30 && character <= 0x39)
            || (character >= 0x41 && character <= 0x5A)
            || (character >= 0x61 && character <= 0x7A)
            || character == 0x5F
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        return character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }
}
