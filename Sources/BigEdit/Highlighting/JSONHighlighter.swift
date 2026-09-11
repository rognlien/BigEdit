import Foundation

/// A small JSON syntax highlighter. Like the XML one it tokenizes one row at
/// a time, carrying only whether a `/* */` comment is still open; a string
/// broken across rows is coloured on the row where it begins.
///
/// Recognises strings (keys and values are told apart), numbers, the literals
/// `true` / `false` / `null`, structural punctuation, and `//` or `/* */`
/// comments (a JSONC convenience).
enum JSONHighlighter {

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
    /// a `/* */` comment. Returns the row's tokens and the state at its end.
    static func tokens(_ text: String, startState: HighlightState) -> ([Token], HighlightState) {
        if startState == .blockComment {
            let scanner = RowScanner(text)
            var tokens: [Token] = []
            if let closeEnd = scanner.indexAfter("*/", from: 0) {
                tokens.add(.comment, 0..<closeEnd)
                let rest = scanner.source.substring(from: closeEnd)
                tokens += self.tokens(rest).map { $0.shifted(by: closeEnd) }
                return (tokens, endState(rest, start: .normal))
            }
            tokens.add(.comment, 0..<scanner.length)
            return (tokens, .blockComment)
        }
        return (tokens(text), endState(text, start: .normal))
    }

    /// Computes the comment state at the end of `text`, given the state at its
    /// start. Mirrors the comment/string handling in `tokens`.
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

    /// The JSON tokens of a row that starts outside any comment.
    static func tokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let scanner = RowScanner(text)
        var index = 0
        while index < scanner.length {
            let character = scanner.character(at: index)
            if character == quote {
                index = scanString(scanner, from: index, into: &tokens)
            } else if isPunctuation(character) {
                tokens.add(.punctuation, index..<(index + 1))
                index += 1
            } else if character == slash {
                index = scanComment(scanner, from: index, into: &tokens)
            } else if character == minus || RowScanner.isDigit(character) {
                index = scanNumber(scanner, from: index, into: &tokens)
            } else if RowScanner.isLowercaseLetter(character) {
                index = scanLiteralKeyword(scanner, from: index, into: &tokens)
            } else {
                index += 1
            }
        }
        return tokens
    }

    /// Tokenizes a `"..."` string. The string is a *key* when it is
    /// immediately followed (after whitespace) by `:`, otherwise a value.
    private static func scanString(
        _ scanner: RowScanner,
        from start: Int,
        into tokens: inout [Token]
    ) -> Int {
        let stringEnd = scanner.endOfQuotedString(from: start, quote: quote, escaping: true)
        let lookahead = scanner.skipWhitespace(from: stringEnd)
        let isKey = scanner.has(colon, at: lookahead)
        tokens.add(isKey ? .key : .string, start..<stringEnd)
        return stringEnd
    }

    /// Tokenizes a `//` or `/* */` comment; a lone `/` is left as plain text.
    private static func scanComment(
        _ scanner: RowScanner,
        from start: Int,
        into tokens: inout [Token]
    ) -> Int {
        let length = scanner.length
        if start + 1 < length {
            let next = scanner.character(at: start + 1)
            if next == slash {
                tokens.add(.comment, start..<length)
                return length
            }
            if next == star {
                let end = scanner.indexAfter("*/", from: start + 2) ?? length
                tokens.add(.comment, start..<end)
                return end
            }
        }
        return start + 1
    }

    /// Tokenizes a numeric literal — a permissive sweep that accepts digits,
    /// `.`, `e`/`E`, and signs. Visually right for valid JSON, slightly loose
    /// on malformed input (acceptable for a highlighter).
    private static func scanNumber(
        _ scanner: RowScanner,
        from start: Int,
        into tokens: inout [Token]
    ) -> Int {
        let end = scanner.endOfNumber(from: start)
        if end > start {
            tokens.add(.number, start..<end)
            return end
        }
        return start + 1
    }

    /// Tokenizes `true` / `false` / `null` when the run is not part of a longer
    /// identifier (so `truer` would not be coloured).
    private static func scanLiteralKeyword(
        _ scanner: RowScanner,
        from start: Int,
        into tokens: inout [Token]
    ) -> Int {
        let boundary: (unichar) -> Bool = { !RowScanner.isIdentifierCharacter($0) }
        if let end = scanner.endOfLiteral(in: literals, at: start, isBoundary: boundary) {
            tokens.add(.literal, start..<end)
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
