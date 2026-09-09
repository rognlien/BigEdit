import Foundation

/// Index-based scanning helpers over one row of text, shared by the syntax
/// highlighters. Positions are UTF-16 offsets into `source`, the same units
/// `NSAttributedString` ranges use. The scanner holds no cursor: each helper
/// takes a start index and returns where it stopped, so a highlighter keeps
/// its own control flow and decides for itself how to avoid stalling on an
/// empty match.
struct RowScanner {

    let source: NSString
    let length: Int

    init(_ text: String) {
        self.init(text as NSString)
    }

    init(_ source: NSString) {
        self.source = source
        self.length = source.length
    }

    // MARK: - Peeking

    /// The character at `index`, or 0 when `index` lies outside the row.
    func character(at index: Int) -> unichar {
        var result: unichar = 0
        if index >= 0 && index < length {
            result = source.character(at: index)
        }
        return result
    }

    /// True when `index` lies inside the row and holds `character`.
    func has(_ character: unichar, at index: Int) -> Bool {
        return index >= 0 && index < length && source.character(at: index) == character
    }

    /// True when `literal` occurs at exactly `index`.
    func matches(_ literal: String, at index: Int) -> Bool {
        let literalLength = (literal as NSString).length
        var result = false
        if index >= 0 && index + literalLength <= length {
            let range = NSRange(location: index, length: literalLength)
            result = source.substring(with: range) == literal
        }
        return result
    }

    /// The index just past the first occurrence of `literal` at or after
    /// `from`, or `nil` when the rest of the row does not contain it.
    func indexAfter(_ literal: String, from: Int) -> Int? {
        var result: Int?
        if from >= 0 && from <= length {
            let searchRange = NSRange(location: from, length: length - from)
            let found = source.range(of: literal, options: [], range: searchRange)
            if found.location != NSNotFound {
                result = found.location + found.length
            }
        }
        return result
    }

    // MARK: - Runs

    /// The index of the first character at or after `start` that fails
    /// `predicate`, or `length` when the run reaches the end of the row.
    func endOfRun(from start: Int, while predicate: (unichar) -> Bool) -> Int {
        var index = start
        while index < length && predicate(source.character(at: index)) {
            index += 1
        }
        return index
    }

    /// The index of the first non-whitespace character at or after `start`.
    func skipWhitespace(from start: Int) -> Int {
        return endOfRun(from: start, while: RowScanner.isWhitespace)
    }

    /// The number of leading space characters. Tabs do not count.
    var leadingSpaceCount: Int {
        return endOfRun(from: 0) { $0 == RowScanner.space }
    }

    /// True when every character at or after `start` is whitespace.
    func isBlank(from start: Int = 0) -> Bool {
        return skipWhitespace(from: start) == length
    }

    // MARK: - Tokens

    /// Scans a quoted string whose opening quote sits at `start`. Returns the
    /// index just past the closing quote, or `length` when the row ends first.
    /// With `escaping`, a backslash skips the character after it.
    func endOfQuotedString(from start: Int, quote: unichar, escaping: Bool) -> Int {
        var index = start + 1
        var closed = false
        while index < length && !closed {
            let character = source.character(at: index)
            if escaping && character == RowScanner.backslash && index + 1 < length {
                index += 2
            } else if character == quote {
                index += 1
                closed = true
            } else {
                index += 1
            }
        }
        return index
    }

    /// Scans a permissive numeric literal from `start`: digits, `.`, `e` / `E`
    /// and sign characters, in any order. Right for well-formed input and
    /// merely loose on malformed input, which is acceptable for a highlighter.
    func endOfNumber(from start: Int) -> Int {
        return endOfRun(from: start, while: RowScanner.isNumberCharacter)
    }

    /// The index just past whichever of `candidates` occurs at `start` and is
    /// followed by the end of the row or a character passing `isBoundary`.
    /// Candidates are tried in order, so list a word before its prefixes.
    func endOfLiteral(in candidates: [String], at start: Int,
                      isBoundary: (unichar) -> Bool) -> Int? {
        var result: Int?
        for candidate in candidates where result == nil {
            let end = start + (candidate as NSString).length
            if matches(candidate, at: start) && (end >= length || isBoundary(source.character(at: end))) {
                result = end
            }
        }
        return result
    }

    // MARK: - Character classes

    static let space = unichar(UInt8(ascii: " "))
    static let tab = unichar(UInt8(ascii: "\t"))
    static let backslash = unichar(UInt8(ascii: "\\"))

    static func isWhitespace(_ character: unichar) -> Bool {
        return character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }

    static func isDigit(_ character: unichar) -> Bool {
        return character >= 0x30 && character <= 0x39
    }

    static func isLowercaseLetter(_ character: unichar) -> Bool {
        return character >= 0x61 && character <= 0x7A
    }

    static func isUppercaseLetter(_ character: unichar) -> Bool {
        return character >= 0x41 && character <= 0x5A
    }

    /// ASCII letters, digits and underscore.
    static func isIdentifierCharacter(_ character: unichar) -> Bool {
        return isDigit(character)
            || isUppercaseLetter(character)
            || isLowercaseLetter(character)
            || character == 0x5F
    }

    private static func isNumberCharacter(_ character: unichar) -> Bool {
        let isExponent = character == 0x65 || character == 0x45    // e, E
        let isSign = character == 0x2B || character == 0x2D        // + -
        return isDigit(character) || character == 0x2E || isExponent || isSign
    }
}
