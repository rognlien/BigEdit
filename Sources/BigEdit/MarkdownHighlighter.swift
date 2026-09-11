import Foundation

/// A small Markdown syntax highlighter. It tokenizes one row at a time,
/// carrying only whether a fenced code block is open so the lines inside a
/// fence are coloured as code.
///
/// Recognises headings, horizontal rules, fence markers, blockquote and list
/// prefixes, and the inline tokens: inline code, bold, italic, links, and
/// strikethrough.
enum MarkdownHighlighter {

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
    /// ``` / ~~~ code block. Returns the row's tokens and the state at its end.
    static func tokens(_ text: String, startState: HighlightState) -> ([Token], HighlightState) {
        if startState == .fencedCode {
            let scanner = RowScanner(text)
            var tokens: [Token] = []
            if isFenceLine(scanner) {
                tokens.add(.punctuation, 0..<scanner.length)   // closing fence
                return (tokens, .normal)
            }
            tokens.add(.code, 0..<scanner.length)
            return (tokens, .fencedCode)
        }
        return (tokens(text), endState(text, start: .normal))
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

    /// The Markdown tokens of a row outside any fenced code block.
    static func tokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let scanner = RowScanner(text)

        // Whole-line constructs first. Each returns true if it claimed the row.
        if scanHeading(scanner, into: &tokens) { return tokens }
        if scanHorizontalRule(scanner, into: &tokens) { return tokens }
        if scanFence(scanner, into: &tokens) { return tokens }

        // Line prefixes that don't preempt inline scanning.
        scanBlockquote(scanner, into: &tokens)
        scanListMarker(scanner, into: &tokens)

        // Inline tokens.
        scanInline(scanner, into: &tokens)
        return tokens
    }

    // MARK: - Block-level

    private static func scanHeading(
        _ scanner: RowScanner,
        into tokens: inout [Token]
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
        tokens.add(.heading, indent..<length)
        tokens.add(.punctuation, indent..<hashEnd)
        return true
    }

    private static func scanHorizontalRule(
        _ scanner: RowScanner,
        into tokens: inout [Token]
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
        tokens.add(.punctuation, 0..<length)
        return true
    }

    private static func scanFence(
        _ scanner: RowScanner,
        into tokens: inout [Token]
    ) -> Bool {
        let isFence = isFenceLine(scanner)
        if isFence {
            tokens.add(.punctuation, 0..<scanner.length)
        }
        return isFence
    }

    private static func scanBlockquote(
        _ scanner: RowScanner,
        into tokens: inout [Token]
    ) {
        let length = scanner.length
        let indent = scanner.leadingSpaceCount
        if indent > 3 || indent >= length {
            return
        }
        if scanner.character(at: indent) != greaterThan {
            return
        }
        tokens.add(.blockquote, indent..<length)
    }

    private static func scanListMarker(
        _ scanner: RowScanner,
        into tokens: inout [Token]
    ) {
        let indent = scanner.leadingSpaceCount
        if indent >= scanner.length {
            return
        }
        let firstChar = scanner.character(at: indent)
        // Bullet markers — `-`, `*`, `+` followed by space.
        if firstChar == dash || firstChar == star || firstChar == plus {
            if scanner.has(space, at: indent + 1) {
                tokens.add(.punctuation, indent..<(indent + 1))
            }
            return
        }
        // Ordered list — digits followed by `.` or `)` then space.
        if RowScanner.isDigit(firstChar) {
            let endIndex = scanner.endOfRun(from: indent, while: RowScanner.isDigit)
            let terminator = scanner.character(at: endIndex)
            if terminator == dot || terminator == closeParen {
                if scanner.has(space, at: endIndex + 1) {
                    tokens.add(.punctuation, indent..<(endIndex + 1))
                }
            }
        }
    }

    // MARK: - Inline

    private static func scanInline(
        _ scanner: RowScanner,
        into tokens: inout [Token]
    ) {
        let length = scanner.length
        var index = 0
        while index < length {
            let character = scanner.character(at: index)
            if character == backtick {
                index = scanInlineCode(scanner, from: index, into: &tokens)
            } else if character == star || character == underscore {
                index = scanEmphasis(scanner, from: index, marker: character, into: &tokens)
            } else if character == openBracket {
                index = scanLink(scanner, from: index, into: &tokens)
            } else if character == tilde {
                index = scanStrikethrough(scanner, from: index, into: &tokens)
            } else {
                index += 1
            }
        }
    }

    private static func scanInlineCode(
        _ scanner: RowScanner,
        from start: Int,
        into tokens: inout [Token]
    ) -> Int {
        let closeIndex = scanner.endOfRun(from: start + 1) { $0 != backtick }
        if closeIndex < scanner.length {
            tokens.add(.code, start..<(closeIndex + 1))
            return closeIndex + 1
        }
        return start + 1
    }

    /// Two markers in a row are treated as **strong**; a single marker as
    /// *emphasis*.
    private static func scanEmphasis(
        _ scanner: RowScanner,
        from start: Int,
        marker: unichar,
        into tokens: inout [Token]
    ) -> Int {
        let length = scanner.length
        let isStrong = scanner.has(marker, at: start + 1)
        let openLength = isStrong ? 2 : 1
        var index = start + openLength

        while index < length {
            if scanner.character(at: index) == marker {
                if isStrong {
                    if scanner.has(marker, at: index + 1) {
                        let end = index + 2
                        tokens.add(.strong, start..<end)
                        tokens.add(.punctuation, start..<(start + 2))
                        tokens.add(.punctuation, index..<end)
                        return end
                    }
                } else {
                    let end = index + 1
                    tokens.add(.emphasis, start..<end)
                    tokens.add(.punctuation, start..<(start + 1))
                    tokens.add(.punctuation, index..<end)
                    return end
                }
            }
            index += 1
        }
        // No matching close on this row — advance past the open marker so the
        // outer loop makes progress.
        return start + openLength
    }

    private static func scanLink(
        _ scanner: RowScanner,
        from start: Int,
        into tokens: inout [Token]
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
        tokens.add(.linkText, (start + 1)..<bracketEnd)
        tokens.add(.url, (bracketEnd + 2)..<parenEnd)
        tokens.add(.punctuation, start..<(start + 1))
        tokens.add(.punctuation, bracketEnd..<(bracketEnd + 2))
        tokens.add(.punctuation, parenEnd..<(parenEnd + 1))
        return parenEnd + 1
    }

    private static func scanStrikethrough(
        _ scanner: RowScanner,
        from start: Int,
        into tokens: inout [Token]
    ) -> Int {
        let length = scanner.length
        if !scanner.has(tilde, at: start + 1) {
            return start + 1
        }
        var index = start + 2
        while index + 1 < length {
            if scanner.character(at: index) == tilde && scanner.character(at: index + 1) == tilde {
                let end = index + 2
                tokens.add(.strikethrough, (start + 2)..<index)
                tokens.add(.punctuation, start..<(start + 2))
                tokens.add(.punctuation, index..<end)
                return end
            }
            index += 1
        }
        return start + 2
    }
}
