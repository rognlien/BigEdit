import AppKit

/// A small, stateless YAML syntax highlighter. Per-row tokenization with no
/// carried context, which fits YAML reasonably well since most of its syntax
/// is line-oriented.
///
/// Recognises document separators, list markers, bare and quoted keys, single
/// and double quoted strings, numbers, the common literals (`true` / `false`
/// / `null` / `yes` / `no` / `on` / `off` / `~`), anchors and aliases
/// (`&name` / `*name`), tags (`!tag` / `!!tag`), block-scalar indicators
/// (`|` / `>`), and `#` comments.
enum YAMLHighlighter {

    private static let keyColor = NSColor.systemBlue
    private static let stringColor = NSColor.systemRed
    private static let numberColor = NSColor.systemPurple
    private static let literalColor = NSColor.systemTeal
    private static let commentColor = NSColor.systemGreen
    private static let anchorColor = NSColor.systemOrange
    private static let punctuationColor = NSColor.secondaryLabelColor

    private static let hash = unichar(UInt8(ascii: "#"))
    private static let colon = unichar(UInt8(ascii: ":"))
    private static let doubleQuote = unichar(UInt8(ascii: "\""))
    private static let singleQuote = unichar(UInt8(ascii: "'"))
    private static let backslash = unichar(UInt8(ascii: "\\"))
    private static let dash = unichar(UInt8(ascii: "-"))
    private static let dot = unichar(UInt8(ascii: "."))
    private static let space = unichar(UInt8(ascii: " "))
    private static let tab = unichar(UInt8(ascii: "\t"))
    private static let ampersand = unichar(UInt8(ascii: "&"))
    private static let asterisk = unichar(UInt8(ascii: "*"))
    private static let bang = unichar(UInt8(ascii: "!"))
    private static let pipe = unichar(UInt8(ascii: "|"))
    private static let greaterThan = unichar(UInt8(ascii: ">"))
    private static let tilde = unichar(UInt8(ascii: "~"))

    static func attributedRow(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.textColor]
        )
        let source = text as NSString
        let length = source.length

        // Document separator (`---` or `...`) takes the whole row.
        if isDocumentSeparator(source) {
            apply(punctuationColor, 0..<length, result)
            return result
        }

        // Skip indent; recognise a leading list marker.
        var index = leadingWhitespace(source)
        if index < length && source.character(at: index) == dash {
            let isMarker = index + 1 == length
                || source.character(at: index + 1) == space
                || source.character(at: index + 1) == tab
            if isMarker {
                apply(punctuationColor, index..<(index + 1), result)
                index += 1
                while index < length && (source.character(at: index) == space
                                         || source.character(at: index) == tab) {
                    index += 1
                }
            }
        }

        // Token scan from `index` to end-of-row.
        while index < length {
            let character = source.character(at: index)

            if character == hash && (index == 0 || isWhitespace(source.character(at: index - 1))) {
                apply(commentColor, index..<length, result)
                return result
            }
            if character == doubleQuote {
                index = colorQuotedString(source, from: index, quote: doubleQuote, escaping: true, into: result)
                continue
            }
            if character == singleQuote {
                index = colorQuotedString(source, from: index, quote: singleQuote, escaping: false, into: result)
                continue
            }
            if character == colon && isAtKeyTerminator(source, at: index) {
                colorKey(source, before: index, into: result)
                apply(punctuationColor, index..<(index + 1), result)
                index += 1
                continue
            }
            if character == ampersand || character == asterisk || character == bang {
                index = colorAnchorOrTag(source, from: index, into: result)
                continue
            }
            if character == pipe || character == greaterThan {
                apply(punctuationColor, index..<(index + 1), result)
                index += 1
                continue
            }
            if isLowercaseLetter(character) || character == tilde {
                if let end = matchLiteral(source, from: index) {
                    apply(literalColor, index..<end, result)
                    index = end
                    continue
                }
            }
            if isDigit(character)
                || (character == dash && index + 1 < length && isDigit(source.character(at: index + 1))) {
                index = colorNumber(source, from: index, into: result)
                continue
            }
            index += 1
        }
        return result
    }

    // MARK: - Line shape

    private static func isDocumentSeparator(_ source: NSString) -> Bool {
        let length = source.length
        var result = false
        if length >= 3 {
            let c0 = source.character(at: 0)
            let c1 = source.character(at: 1)
            let c2 = source.character(at: 2)
            let isDashes = c0 == dash && c1 == dash && c2 == dash
            let isDots = c0 == dot && c1 == dot && c2 == dot
            if isDashes || isDots {
                var trailingOk = true
                var index = 3
                while index < length {
                    if !isWhitespace(source.character(at: index)) {
                        trailingOk = false
                        break
                    }
                    index += 1
                }
                result = trailingOk
            }
        }
        return result
    }

    private static func leadingWhitespace(_ source: NSString) -> Int {
        var index = 0
        while index < source.length && isWhitespace(source.character(at: index)) {
            index += 1
        }
        return index
    }

    private static func isAtKeyTerminator(_ source: NSString, at index: Int) -> Bool {
        let length = source.length
        if index + 1 == length {
            return true
        }
        let next = source.character(at: index + 1)
        return isWhitespace(next)
    }

    // MARK: - Tokens

    /// Walks back from `before` (the index of `:`) to find where the key begins
    /// and colours it. Quoted keys are recoloured by walking back to the
    /// matching opening quote.
    private static func colorKey(
        _ source: NSString,
        before: Int,
        into result: NSMutableAttributedString
    ) {
        if before == 0 {
            return
        }
        let prev = source.character(at: before - 1)
        if prev == doubleQuote || prev == singleQuote {
            var openIndex = before - 2
            while openIndex >= 0 {
                if source.character(at: openIndex) == prev {
                    break
                }
                openIndex -= 1
            }
            if openIndex >= 0 {
                apply(keyColor, openIndex..<before, result)
                return
            }
        }
        var keyStart = before
        while keyStart > 0 {
            let candidate = source.character(at: keyStart - 1)
            if isWhitespace(candidate) {
                break
            }
            keyStart -= 1
        }
        if keyStart < before {
            apply(keyColor, keyStart..<before, result)
        }
    }

    private static func colorQuotedString(
        _ source: NSString,
        from start: Int,
        quote: unichar,
        escaping: Bool,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        var index = start + 1
        while index < length {
            let character = source.character(at: index)
            if escaping && character == backslash && index + 1 < length {
                index += 2
                continue
            }
            if character == quote {
                index += 1
                break
            }
            index += 1
        }
        apply(stringColor, start..<index, result)
        return index
    }

    private static func colorAnchorOrTag(
        _ source: NSString,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        var index = start + 1
        while index < length {
            let character = source.character(at: index)
            if isWhitespace(character) || character == colon {
                break
            }
            index += 1
        }
        apply(anchorColor, start..<index, result)
        return max(index, start + 1)
    }

    private static func colorNumber(
        _ source: NSString,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let length = source.length
        var index = start
        if index < length && source.character(at: index) == dash {
            index += 1
        }
        var sawDigit = false
        while index < length {
            let character = source.character(at: index)
            if isDigit(character) {
                sawDigit = true
                index += 1
            } else if character == dot
                || character == 0x65 || character == 0x45        // e, E
                || character == 0x2B || character == 0x2D {      // + -
                index += 1
            } else {
                break
            }
        }
        if sawDigit {
            apply(numberColor, start..<index, result)
            return index
        }
        return start + 1
    }

    /// Returns the index just past a recognised literal beginning at `start`,
    /// or `nil` if no literal matches.
    private static func matchLiteral(_ source: NSString, from start: Int) -> Int? {
        let length = source.length
        var result: Int?
        if source.character(at: start) == tilde {
            let after = start + 1
            if after >= length || isLiteralBoundary(source.character(at: after)) {
                result = after
            }
        } else {
            let candidates = ["true", "false", "null", "yes", "no", "on", "off"]
            for candidate in candidates where result == nil {
                let candidateLength = candidate.count
                if start + candidateLength <= length {
                    let range = NSRange(location: start, length: candidateLength)
                    if source.substring(with: range) == candidate {
                        let after = start + candidateLength
                        if after >= length || isLiteralBoundary(source.character(at: after)) {
                            result = after
                        }
                    }
                }
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func isLiteralBoundary(_ character: unichar) -> Bool {
        return isWhitespace(character)
            || character == colon
            || character == 0x2C   // ,
            || character == 0x5D   // ]
            || character == 0x7D   // }
            || character == hash
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

    private static func isDigit(_ character: unichar) -> Bool {
        return character >= 0x30 && character <= 0x39
    }

    private static func isLowercaseLetter(_ character: unichar) -> Bool {
        return character >= 0x61 && character <= 0x7A
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        return character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }
}
