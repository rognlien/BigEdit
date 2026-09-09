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
    private static let dash = unichar(UInt8(ascii: "-"))
    private static let plus = unichar(UInt8(ascii: "+"))
    private static let dot = unichar(UInt8(ascii: "."))
    private static let space = RowScanner.space
    private static let tab = RowScanner.tab
    private static let ampersand = unichar(UInt8(ascii: "&"))
    private static let asterisk = unichar(UInt8(ascii: "*"))
    private static let bang = unichar(UInt8(ascii: "!"))
    private static let pipe = unichar(UInt8(ascii: "|"))
    private static let greaterThan = unichar(UInt8(ascii: ">"))
    private static let tilde = unichar(UInt8(ascii: "~"))

    /// Word literals, longest first so `null` is matched before `no`.
    private static let literals = ["true", "false", "null", "yes", "no", "on", "off"]

    /// Stateful entry: when `startState` is `.blockScalar` the row may be a
    /// continuation line of a `|` / `>` block scalar (coloured as a string).
    static func attributedRow(_ text: String, font: NSFont,
                              startState: HighlightState) -> (NSAttributedString, HighlightState) {
        let scanner = RowScanner(text)
        if case .blockScalar(let parentIndent) = startState,
           continuesBlockScalar(scanner, parentIndent: parentIndent) {
            let result = NSMutableAttributedString.plainRow(text, font: font)
            result.setColor(stringColor, in: 0..<scanner.length)
            return (result, .blockScalar(indent: parentIndent))
        }
        return (attributedRow(text, font: font), endState(text, start: startState))
    }

    /// Computes the block-scalar state at the end of `text`. A `key: |` (or `>`)
    /// opens a scalar whose continuation lines are those indented past the key.
    static func endState(_ text: String, start: HighlightState) -> HighlightState {
        let scanner = RowScanner(text)
        if case .blockScalar(let parentIndent) = start,
           continuesBlockScalar(scanner, parentIndent: parentIndent) {
            return .blockScalar(indent: parentIndent)
        }
        return opensBlockScalar(scanner) ? .blockScalar(indent: scanner.leadingSpaceCount) : .normal
    }

    /// A blank row, or one indented past the key that opened the scalar, is
    /// still part of the scalar.
    private static func continuesBlockScalar(_ scanner: RowScanner, parentIndent: Int) -> Bool {
        return isBlank(scanner) || scanner.leadingSpaceCount > parentIndent
    }

    /// A row of nothing but spaces and tabs.
    private static func isBlank(_ scanner: RowScanner) -> Bool {
        return scanner.endOfRun(from: 0) { $0 == space || $0 == tab } == scanner.length
    }

    /// True when the line's value is a `|` or `>` block-scalar indicator
    /// (optionally with chomping/indentation indicators or a trailing comment).
    private static func opensBlockScalar(_ scanner: RowScanner) -> Bool {
        let length = scanner.length
        // Find the value start: after the last ": " or a trailing ":".
        var valueStart = -1
        var i = scanner.leadingSpaceCount
        var inSingle = false
        var inDouble = false
        while i < length {
            let c = scanner.character(at: i)
            if c == doubleQuote && !inSingle { inDouble.toggle() }
            else if c == singleQuote && !inDouble { inSingle.toggle() }
            else if c == colon && !inSingle && !inDouble {
                if i + 1 >= length { return false }          // "key:" with nothing after
                if scanner.character(at: i + 1) == space { valueStart = i + 2 }
            }
            i += 1
        }
        guard valueStart >= 0 else { return false }
        var j = scanner.endOfRun(from: valueStart) { $0 == space }
        guard j < length else { return false }
        let indicator = scanner.character(at: j)
        guard indicator == pipe || indicator == greaterThan else { return false }
        // Remainder must be only chomping/indent indicators and optional comment.
        j += 1
        while j < length {
            let c = scanner.character(at: j)
            if c == space || c == hash { break }                 // trailing comment/space ok
            let isChomp = c == plus || c == dash
            let isIndentIndicator = c >= 0x31 && c <= 0x39        // 1–9
            if !isChomp && !isIndentIndicator { return false }
            j += 1
        }
        return true
    }

    static func attributedRow(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString.plainRow(text, font: font)
        let scanner = RowScanner(text)
        let length = scanner.length

        // Document separator (`---` or `...`) takes the whole row.
        if isDocumentSeparator(scanner) {
            result.setColor(punctuationColor, in: 0..<length)
            return result
        }

        // Skip indent; recognise a leading list marker.
        var index = scanner.skipWhitespace(from: 0)
        if scanner.character(at: index) == dash {
            let isMarker = index + 1 == length
                || scanner.has(space, at: index + 1)
                || scanner.has(tab, at: index + 1)
            if isMarker {
                result.setColor(punctuationColor, in: index..<(index + 1))
                index = scanner.endOfRun(from: index + 1) { $0 == space || $0 == tab }
            }
        }

        // Token scan from `index` to end-of-row.
        while index < length {
            let character = scanner.character(at: index)

            if character == hash && (index == 0 || RowScanner.isWhitespace(scanner.character(at: index - 1))) {
                result.setColor(commentColor, in: index..<length)
                return result
            }
            if character == doubleQuote {
                index = colorQuotedString(scanner, from: index, quote: doubleQuote, escaping: true, into: result)
                continue
            }
            if character == singleQuote {
                index = colorQuotedString(scanner, from: index, quote: singleQuote, escaping: false, into: result)
                continue
            }
            if character == colon && isAtKeyTerminator(scanner, at: index) {
                colorKey(scanner, before: index, into: result)
                result.setColor(punctuationColor, in: index..<(index + 1))
                index += 1
                continue
            }
            if character == ampersand || character == asterisk || character == bang {
                index = colorAnchorOrTag(scanner, from: index, into: result)
                continue
            }
            if character == pipe || character == greaterThan {
                result.setColor(punctuationColor, in: index..<(index + 1))
                index += 1
                continue
            }
            if RowScanner.isLowercaseLetter(character) || character == tilde {
                if let end = matchLiteral(scanner, from: index) {
                    result.setColor(literalColor, in: index..<end)
                    index = end
                    continue
                }
            }
            if RowScanner.isDigit(character)
                || (character == dash && RowScanner.isDigit(scanner.character(at: index + 1))) {
                index = colorNumber(scanner, from: index, into: result)
                continue
            }
            index += 1
        }
        return result
    }

    // MARK: - Line shape

    private static func isDocumentSeparator(_ scanner: RowScanner) -> Bool {
        var result = false
        if scanner.matches("---", at: 0) || scanner.matches("...", at: 0) {
            result = scanner.isBlank(from: 3)
        }
        return result
    }

    private static func isAtKeyTerminator(_ scanner: RowScanner, at index: Int) -> Bool {
        return index + 1 == scanner.length
            || RowScanner.isWhitespace(scanner.character(at: index + 1))
    }

    // MARK: - Tokens

    /// Walks back from `before` (the index of `:`) to find where the key begins
    /// and colours it. Quoted keys are recoloured by walking back to the
    /// matching opening quote.
    private static func colorKey(
        _ scanner: RowScanner,
        before: Int,
        into result: NSMutableAttributedString
    ) {
        if before == 0 {
            return
        }
        let prev = scanner.character(at: before - 1)
        if prev == doubleQuote || prev == singleQuote {
            var openIndex = before - 2
            while openIndex >= 0 {
                if scanner.character(at: openIndex) == prev {
                    break
                }
                openIndex -= 1
            }
            if openIndex >= 0 {
                result.setColor(keyColor, in: openIndex..<before)
                return
            }
        }
        var keyStart = before
        while keyStart > 0 {
            let candidate = scanner.character(at: keyStart - 1)
            if RowScanner.isWhitespace(candidate) {
                break
            }
            keyStart -= 1
        }
        if keyStart < before {
            result.setColor(keyColor, in: keyStart..<before)
        }
    }

    private static func colorQuotedString(
        _ scanner: RowScanner,
        from start: Int,
        quote: unichar,
        escaping: Bool,
        into result: NSMutableAttributedString
    ) -> Int {
        let end = scanner.endOfQuotedString(from: start, quote: quote, escaping: escaping)
        result.setColor(stringColor, in: start..<end)
        return end
    }

    private static func colorAnchorOrTag(
        _ scanner: RowScanner,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let end = scanner.endOfRun(from: start + 1) { !RowScanner.isWhitespace($0) && $0 != colon }
        result.setColor(anchorColor, in: start..<end)
        return end
    }

    /// Colours a number starting at `start`. Callers only get here when the
    /// run begins with a digit or a `-` followed by one, so the sweep always
    /// covers at least one digit.
    private static func colorNumber(
        _ scanner: RowScanner,
        from start: Int,
        into result: NSMutableAttributedString
    ) -> Int {
        let end = scanner.endOfNumber(from: start)
        result.setColor(numberColor, in: start..<end)
        return end
    }

    /// Returns the index just past a recognised literal beginning at `start`,
    /// or `nil` if no literal matches.
    private static func matchLiteral(_ scanner: RowScanner, from start: Int) -> Int? {
        var result: Int?
        if scanner.character(at: start) == tilde {
            let after = start + 1
            if after >= scanner.length || isLiteralBoundary(scanner.character(at: after)) {
                result = after
            }
        } else {
            result = scanner.endOfLiteral(in: literals, at: start, isBoundary: isLiteralBoundary)
        }
        return result
    }

    // MARK: - Helpers

    private static func isLiteralBoundary(_ character: unichar) -> Bool {
        return RowScanner.isWhitespace(character)
            || character == colon
            || character == 0x2C   // ,
            || character == 0x5D   // ]
            || character == 0x7D   // }
            || character == hash
    }
}
