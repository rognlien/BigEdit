import AppKit

/// The syntax-highlighting mode for a document.
enum SyntaxMode {
    case plain
    case xml
    case json
    case markdown
    case yaml
}

/// A small, stateless XML syntax highlighter. It colours one row of text at a
/// time, with no carried context, which keeps it viewport-cheap.
///
/// The trade-off of being stateless: a construct that spans rows — a comment
/// broken across several lines — is only coloured on the row where it begins.
/// That is acceptable for a viewer and avoids any per-row state in the index.
enum XMLHighlighter {

    private static let tagColor = NSColor.systemBlue
    private static let attributeNameColor = NSColor.systemPurple
    private static let attributeValueColor = NSColor.systemRed
    private static let commentColor = NSColor.systemGreen
    private static let declarationColor = NSColor.systemTeal
    private static let punctuationColor = NSColor.secondaryLabelColor

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
    /// an `<!-- -->` comment. Returns the colouring and the state at the end.
    static func attributedRow(_ text: String, font: NSFont,
                              startState: HighlightState) -> (NSAttributedString, HighlightState) {
        if startState == .blockComment {
            let scanner = RowScanner(text)
            let result = NSMutableAttributedString.plainRow(text, font: font)
            if let closeEnd = scanner.indexAfter("-->", from: 0) {
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

    /// Returns `text` as an attributed string with XML tokens coloured.
    static func attributedRow(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString.plainRow(text, font: font)
        let scanner = RowScanner(text)
        var index = 0
        while index < scanner.length {
            if scanner.character(at: index) == lessThan {
                index = colorMarkup(scanner, from: index, into: result)
            } else {
                index += 1  // Text content keeps the default colour.
            }
        }
        return result
    }

    /// Colours one markup construct beginning at `start` (`<`); returns the
    /// index just past it. Always advances by at least one.
    private static func colorMarkup(
        _ scanner: RowScanner,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = scanner.length
        let secondChar = scanner.character(at: start + 1)

        if secondChar == bang {
            if scanner.character(at: start + 2) == dash && scanner.character(at: start + 3) == dash {
                let end = scanner.indexAfter("-->", from: start + 4) ?? length
                result.setColor(commentColor, in: start..<end)
                return end
            }
            let end = scanner.indexAfter(">", from: start + 2) ?? length
            result.setColor(declarationColor, in: start..<end)
            return end
        }

        if secondChar == question {
            let end = scanner.indexAfter("?>", from: start + 2) ?? length
            result.setColor(declarationColor, in: start..<end)
            return end
        }

        return colorTag(scanner, from: start, into: result)
    }

    /// Colours an element tag and its attributes; returns the index past it.
    private static func colorTag(
        _ scanner: RowScanner,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = scanner.length
        var index = start

        result.setColor(punctuationColor, in: index..<(index + 1))  // '<'
        index += 1
        if scanner.has(slash, at: index) {
            result.setColor(punctuationColor, in: index..<(index + 1))
            index += 1
        }

        let nameStart = index
        index = scanner.endOfRun(from: index, while: isNameCharacter)
        result.setColor(tagColor, in: nameStart..<index)

        var tagClosed = false
        while index < length && !tagClosed {
            let character = scanner.character(at: index)
            if character == greaterThan {
                result.setColor(punctuationColor, in: index..<(index + 1))
                index += 1
                tagClosed = true
            } else if character == slash || character == equals {
                result.setColor(punctuationColor, in: index..<(index + 1))
                index += 1
            } else if RowScanner.isWhitespace(character) {
                index += 1
            } else if character == quote || character == apostrophe {
                index = colorString(scanner, from: index, quote: character, into: result)
            } else {
                index = colorAttributeName(scanner, from: index, into: result)
            }
        }
        return max(index, start + 1)
    }

    /// Colours a quoted attribute value; returns the index past the close quote.
    private static func colorString(
        _ scanner: RowScanner,
        from start: Int,
        quote: unichar,
        into result: NSMutableAttributedString
    ) -> Int {
        let end = scanner.endOfQuotedString(from: start, quote: quote, escaping: false)
        result.setColor(attributeValueColor, in: start..<end)
        return end
    }

    /// Colours an attribute name; returns the index past it (always advances).
    private static func colorAttributeName(
        _ scanner: RowScanner,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        var index = scanner.endOfRun(from: start) { !isAttributeNameDelimiter($0) }
        if index > start {
            result.setColor(attributeNameColor, in: start..<index)
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
