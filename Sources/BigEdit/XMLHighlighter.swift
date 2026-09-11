import Foundation

/// The syntax-highlighting mode for a document.
enum SyntaxMode {
    case plain
    case xml
    case json
    case markdown
    case yaml
}

/// A small XML syntax highlighter. It tokenizes one row of text at a time,
/// which keeps it viewport-cheap; the only thing carried between rows is
/// whether a `<!-- -->` comment is still open, so a comment broken across
/// several lines is coloured on every one of them.
enum XMLHighlighter {

    private static let lessThan = unichar(UInt8(ascii: "<"))
    private static let greaterThan = unichar(UInt8(ascii: ">"))
    private static let slash = unichar(UInt8(ascii: "/"))
    private static let bang = unichar(UInt8(ascii: "!"))
    private static let question = unichar(UInt8(ascii: "?"))
    private static let dash = unichar(UInt8(ascii: "-"))
    private static let equals = unichar(UInt8(ascii: "="))
    private static let quote = unichar(UInt8(ascii: "\""))
    private static let apostrophe = unichar(UInt8(ascii: "'"))

    /// Stateful entry: when `startState` is `.blockComment` the row begins inside
    /// an `<!-- -->` comment. Returns the row's tokens and the state at its end.
    static func tokens(_ text: String, startState: HighlightState) -> ([Token], HighlightState) {
        if startState == .blockComment {
            let scanner = RowScanner(text)
            var tokens: [Token] = []
            if let closeEnd = scanner.indexAfter("-->", from: 0) {
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

    /// Computes the comment state at the end of `text`. XML comments can't nest
    /// and `<!--` can't appear in attribute values, so a plain scan suffices.
    static func endState(_ text: String, start: HighlightState) -> HighlightState {
        let scanner = RowScanner(text)
        var index = 0
        if start == .blockComment {
            guard let closeEnd = scanner.indexAfter("-->", from: 0) else { return .blockComment }
            index = closeEnd
        }
        while let open = scanner.indexAfter("<!--", from: index) {
            guard let closeEnd = scanner.indexAfter("-->", from: open) else { return .blockComment }
            index = closeEnd
        }
        return .normal
    }

    /// The XML tokens of a row that starts outside any comment.
    static func tokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let scanner = RowScanner(text)
        var index = 0
        while index < scanner.length {
            if scanner.character(at: index) == lessThan {
                index = scanMarkup(scanner, from: index, into: &tokens)
            } else {
                index += 1  // Text content keeps the default colour.
            }
        }
        return tokens
    }

    /// Tokenizes one markup construct beginning at `start` (`<`); returns the
    /// index just past it. Always advances by at least one.
    private static func scanMarkup(
        _ scanner: RowScanner,
        from start: Int,
        into tokens: inout [Token]
    ) -> Int {
        let length = scanner.length
        let secondChar = scanner.character(at: start + 1)

        if secondChar == bang {
            if scanner.character(at: start + 2) == dash && scanner.character(at: start + 3) == dash {
                let end = scanner.indexAfter("-->", from: start + 4) ?? length
                tokens.add(.comment, start..<end)
                return end
            }
            let end = scanner.indexAfter(">", from: start + 2) ?? length
            tokens.add(.declaration, start..<end)
            return end
        }

        if secondChar == question {
            let end = scanner.indexAfter("?>", from: start + 2) ?? length
            tokens.add(.declaration, start..<end)
            return end
        }

        return scanTag(scanner, from: start, into: &tokens)
    }

    /// Tokenizes an element tag and its attributes; returns the index past it.
    private static func scanTag(
        _ scanner: RowScanner,
        from start: Int,
        into tokens: inout [Token]
    ) -> Int {
        let length = scanner.length
        var index = start

        tokens.add(.punctuation, index..<(index + 1))  // '<'
        index += 1
        if scanner.has(slash, at: index) {
            tokens.add(.punctuation, index..<(index + 1))
            index += 1
        }

        let nameStart = index
        index = scanner.endOfRun(from: index, while: isNameCharacter)
        tokens.add(.tag, nameStart..<index)

        var tagClosed = false
        while index < length && !tagClosed {
            let character = scanner.character(at: index)
            if character == greaterThan {
                tokens.add(.punctuation, index..<(index + 1))
                index += 1
                tagClosed = true
            } else if character == slash || character == equals {
                tokens.add(.punctuation, index..<(index + 1))
                index += 1
            } else if RowScanner.isWhitespace(character) {
                index += 1
            } else if character == quote || character == apostrophe {
                index = scanString(scanner, from: index, quote: character, into: &tokens)
            } else {
                index = scanAttributeName(scanner, from: index, into: &tokens)
            }
        }
        return max(index, start + 1)
    }

    /// Tokenizes a quoted attribute value; returns the index past the close quote.
    private static func scanString(
        _ scanner: RowScanner,
        from start: Int,
        quote: unichar,
        into tokens: inout [Token]
    ) -> Int {
        let end = scanner.endOfQuotedString(from: start, quote: quote, escaping: false)
        tokens.add(.attributeValue, start..<end)
        return end
    }

    /// Tokenizes an attribute name; returns the index past it (always advances).
    private static func scanAttributeName(
        _ scanner: RowScanner,
        from start: Int,
        into tokens: inout [Token]
    ) -> Int {
        var index = scanner.endOfRun(from: start) { !isAttributeNameDelimiter($0) }
        if index > start {
            tokens.add(.attributeName, start..<index)
        } else {
            index = start + 1  // Safety: never stall the caller's loop.
        }
        return index
    }

    // MARK: - Helpers

    private static func isAttributeNameDelimiter(_ character: unichar) -> Bool {
        return RowScanner.isWhitespace(character)
            || character == equals
            || character == greaterThan
            || character == slash
            || character == quote
            || character == apostrophe
    }

    private static func isNameCharacter(_ character: unichar) -> Bool {
        return RowScanner.isUppercaseLetter(character)
            || RowScanner.isLowercaseLetter(character)
            || RowScanner.isDigit(character)
            || character == 45 || character == 46        // - .
            || character == 95 || character == 58        // _ :
    }
}
