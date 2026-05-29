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

    /// Returns `text` as an attributed string with XML tokens coloured.
    static func attributedRow(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.textColor]
        )
        let source = text as NSString
        var index = 0
        while index < source.length {
            if source.character(at: index) == lessThan {
                index = colorMarkup(source, from: index, into: result)
            } else {
                index += 1  // Text content keeps the default colour.
            }
        }
        return result
    }

    /// Colours one markup construct beginning at `start` (`<`); returns the
    /// index just past it. Always advances by at least one.
    private static func colorMarkup(
        _ source: NSString,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        let secondChar = start + 1 < length ? source.character(at: start + 1) : 0

        if secondChar == bang {
            let thirdChar = start + 2 < length ? source.character(at: start + 2) : 0
            let fourthChar = start + 3 < length ? source.character(at: start + 3) : 0
            if thirdChar == dash && fourthChar == dash {
                let end = indexAfter(source, of: "-->", from: start + 4) ?? length
                apply(commentColor, start..<end, result)
                return end
            }
            let end = indexAfter(source, of: ">", from: start + 2) ?? length
            apply(declarationColor, start..<end, result)
            return end
        }

        if secondChar == question {
            let end = indexAfter(source, of: "?>", from: start + 2) ?? length
            apply(declarationColor, start..<end, result)
            return end
        }

        return colorTag(source, from: start, into: result)
    }

    /// Colours an element tag and its attributes; returns the index past it.
    private static func colorTag(
        _ source: NSString,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        var index = start

        apply(punctuationColor, index..<(index + 1), result)  // '<'
        index += 1
        if index < length && source.character(at: index) == slash {
            apply(punctuationColor, index..<(index + 1), result)
            index += 1
        }

        let nameStart = index
        while index < length && isNameCharacter(source.character(at: index)) {
            index += 1
        }
        apply(tagColor, nameStart..<index, result)

        var tagClosed = false
        while index < length && !tagClosed {
            let character = source.character(at: index)
            if character == greaterThan {
                apply(punctuationColor, index..<(index + 1), result)
                index += 1
                tagClosed = true
            } else if character == slash || character == equals {
                apply(punctuationColor, index..<(index + 1), result)
                index += 1
            } else if isWhitespace(character) {
                index += 1
            } else if character == quote || character == apostrophe {
                index = colorString(source, from: index, quote: character, into: result)
            } else {
                index = colorAttributeName(source, from: index, into: result)
            }
        }
        return max(index, start + 1)
    }

    /// Colours a quoted attribute value; returns the index past the close quote.
    private static func colorString(
        _ source: NSString,
        from start: Int,
        quote: unichar,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        var index = start + 1
        while index < length && source.character(at: index) != quote {
            index += 1
        }
        if index < length {
            index += 1  // Include the closing quote.
        }
        apply(attributeValueColor, start..<index, result)
        return index
    }

    /// Colours an attribute name; returns the index past it (always advances).
    private static func colorAttributeName(
        _ source: NSString,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        var index = start
        while index < length {
            let character = source.character(at: index)
            let isDelimiter = isWhitespace(character)
                || character == equals
                || character == greaterThan
                || character == slash
                || character == quote
                || character == apostrophe
            if isDelimiter {
                break
            }
            index += 1
        }
        if index > start {
            apply(attributeNameColor, start..<index, result)
        } else {
            index = start + 1  // Safety: never stall the caller's loop.
        }
        return index
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

    /// The index just past the first occurrence of `literal` at or after `from`.
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

    private static func isNameCharacter(_ character: unichar) -> Bool {
        return (character >= 65 && character <= 90)      // A-Z
            || (character >= 97 && character <= 122)     // a-z
            || (character >= 48 && character <= 57)      // 0-9
            || character == 45 || character == 46        // - .
            || character == 95 || character == 58        // _ :
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        return character == 32 || character == 9 || character == 10 || character == 13
    }
}
